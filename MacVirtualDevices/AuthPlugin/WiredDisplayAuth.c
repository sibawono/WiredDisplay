// WiredDisplayAuth.c — macOS AuthorizationPlugin for Lock Screen unlock via iPad Touch ID / Face ID.
//
// Runs as `WiredDisplayAuth:unlock,privileged` in `system.login.screensaver` (k-of-n: 1)
// alongside `use-login-window-ui` so normal Mac password / Touch ID always stays active.
//
// Security model (Root-to-Secure-Enclave):
// 1. Loads the console user's root-owned ECDSA P-256 public key from
//    `/Library/Application Support/WiredDisplay/pam_keys/<username>.pub`.
// 2. Generates a fresh 32-byte nonce via SecRandomCopyBytes().
// 3. Connects to WiredDisplayHost's local Unix socket (`pam.sock`), verifying peer UID == user UID,
//    and sends a `service = "lockscreen"` challenge.
// 4. Waits until the user taps "Unlock Mac" on the iPad and passes Touch ID / Face ID,
//    or until MechanismDeactivate fires (user unlocked via Mac password).
// 5. Verifies the ECDSA P-256 signature over
//      "WiredDisplay PAM v1\0lockscreen\0<username>\0<nonce(32)>"
//    via Security.framework and calls SetResult(kAuthorizationResultAllow).

#include <CoreFoundation/CoreFoundation.h>
#include <Security/AuthorizationPlugin.h>
#include <Security/AuthorizationTags.h>
#include <Security/Security.h>
#include <errno.h>
#include <fcntl.h>
#include <grp.h>
#include <poll.h>
#include <pthread.h>
#include <pwd.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/un.h>
#include <unistd.h>

#define WD_KEY_DIR "/Library/Application Support/WiredDisplay/pam_keys"
#define WD_NONCE_LEN 32
#define WD_PUBKEY_LEN 65
#define WD_MAX_SIG_LEN 128

typedef struct {
    const AuthorizationCallbacks *callbacks;
} WDPlugin;

typedef struct {
    WDPlugin *plugin;
    AuthorizationEngineRef engine;
    int is_admin;
    _Atomic int deactivating;
    /// 0 = open, 1 = deactivated, 2 = result sent: exactly one of Deactivate and SetResult wins.
    _Atomic int finished;
    _Atomic int bridge_fd;
    _Atomic int refcount;
} WDMechanism;

static void mech_release(WDMechanism *m) {
    if (atomic_fetch_sub(&m->refcount, 1) == 1) {
        free(m);
    }
}

static int is_safe_username(const char *user) {
    if (!user || user[0] == '\0') return 0;
    for (const unsigned char *p = (const unsigned char *)user; *p; p++) {
        if ((*p >= 'a' && *p <= 'z') || (*p >= 'A' && *p <= 'Z') ||
            (*p >= '0' && *p <= '9') || *p == '_' || *p == '-' || *p == '.') {
            continue;
        }
        return 0;
    }
    if (strcmp(user, ".") == 0 || strcmp(user, "..") == 0) return 0;
    return 1;
}

static int b64_val(unsigned char c) {
    if (c >= 'A' && c <= 'Z') return c - 'A';
    if (c >= 'a' && c <= 'z') return c - 'a' + 26;
    if (c >= '0' && c <= '9') return c - '0' + 52;
    if (c == '+') return 62;
    if (c == '/') return 63;
    return -1;
}

static int decode_base64(const char *src, uint8_t *dst, size_t max_out, size_t *out_len) {
    uint32_t acc = 0;
    int bits = 0;
    size_t written = 0;
    for (const unsigned char *p = (const unsigned char *)src; *p; p++) {
        if (*p == ' ' || *p == '\t' || *p == '\r' || *p == '\n') continue;
        if (*p == '=') break;
        int v = b64_val(*p);
        if (v < 0) return -1;
        acc = (acc << 6) | (uint32_t)v;
        bits += 6;
        if (bits >= 8) {
            bits -= 8;
            if (written >= max_out) return -1;
            dst[written++] = (uint8_t)((acc >> bits) & 0xFF);
        }
    }
    *out_len = written;
    return 0;
}

static int load_enrolled_pubkey(const char *username, uint8_t out_key[WD_PUBKEY_LEN]) {
    if (!is_safe_username(username)) return -1;
    char path[512];
    int n = snprintf(path, sizeof(path), "%s/%s.pub", WD_KEY_DIR, username);
    if (n <= 0 || (size_t)n >= sizeof(path)) return -1;

    struct stat st;
    if (lstat(path, &st) != 0) return -1;
    if (!S_ISREG(st.st_mode) || st.st_uid != 0 || (st.st_mode & 0022) != 0) return -1;
    if (st.st_size <= 0 || st.st_size > 512) return -1;

    int fd = open(path, O_RDONLY | O_NOFOLLOW);
    if (fd < 0) return -1;
    char buf[513];
    ssize_t r = read(fd, buf, sizeof(buf) - 1);
    close(fd);
    if (r <= 0) return -1;
    buf[r] = '\0';

    size_t decoded_len = 0;
    if (decode_base64(buf, out_key, WD_PUBKEY_LEN, &decoded_len) != 0) return -1;
    if (decoded_len != WD_PUBKEY_LEN || out_key[0] != 0x04) return -1;
    return 0;
}

static int write_all_interruptible(int fd, const uint8_t *buf, size_t len, _Atomic int *deactivating) {
    size_t sent = 0;
    while (sent < len && !atomic_load(deactivating)) {
        ssize_t n = write(fd, buf + sent, len - sent);
        if (n < 0 && errno == EINTR) continue;
        if (n < 0 && (errno == EAGAIN || errno == EWOULDBLOCK)) {
            struct pollfd pfd = {fd, POLLOUT, 0};
            poll(&pfd, 1, 200);
            continue;
        }
        if (n <= 0) return -1;
        sent += (size_t)n;
    }
    return sent == len ? 0 : -1;
}

static int read_all_interruptible(int fd, uint8_t *buf, size_t len, _Atomic int *deactivating) {
    size_t got = 0;
    while (got < len && !atomic_load(deactivating)) {
        struct pollfd pfd = {fd, POLLIN, 0};
        int pr = poll(&pfd, 1, 250);
        if (pr == 0) continue;
        if (pr < 0) {
            if (errno == EINTR) continue;
            return -1;
        }
        ssize_t n = read(fd, buf + got, len - got);
        if (n < 0 && (errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK)) continue;
        if (n <= 0) return -1;
        got += (size_t)n;
    }
    return got == len ? 0 : -1;
}

static int connect_bridge(const char *home_dir, uid_t expected_uid) {
    char sock_path[256];
    int n = snprintf(sock_path, sizeof(sock_path), "%s/Library/Caches/dev.wireddisplay.host/pam.sock", home_dir);
    if (n <= 0 || (size_t)n >= sizeof(sock_path)) return -1;

    int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0) return -1;
    int on = 1;
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, sizeof(on));

    struct sockaddr_un addr;
    memset(&addr, 0, sizeof(addr));
    addr.sun_family = AF_UNIX;
    if (strlen(sock_path) >= sizeof(addr.sun_path)) {
        close(fd);
        return -1;
    }
    strlcpy(addr.sun_path, sock_path, sizeof(addr.sun_path));

    int flags = fcntl(fd, F_GETFL, 0);
    if (flags >= 0) fcntl(fd, F_SETFL, flags | O_NONBLOCK);
    int rc = connect(fd, (struct sockaddr *)&addr, sizeof(addr));
    if (rc != 0 && errno == EINPROGRESS) {
        struct pollfd pfd = {fd, POLLOUT, 0};
        if (poll(&pfd, 1, 250) <= 0) {
            close(fd);
            return -1;
        }
        int so_err = 0;
        socklen_t so_len = sizeof(so_err);
        if (getsockopt(fd, SOL_SOCKET, SO_ERROR, &so_err, &so_len) != 0 || so_err != 0) {
            close(fd);
            return -1;
        }
    } else if (rc != 0) {
        close(fd);
        return -1;
    }

    uid_t peer_uid = (uid_t)-1;
    gid_t peer_gid = (gid_t)-1;
    if (getpeereid(fd, &peer_uid, &peer_gid) != 0 || peer_uid != expected_uid) {
        close(fd);
        return -1;
    }
    return fd;
}

static int verify_p256_signature(const uint8_t pubkey_bytes[WD_PUBKEY_LEN],
                                 const uint8_t *msg, size_t msg_len,
                                 const uint8_t *sig, size_t sig_len) {
    CFDataRef keyData = CFDataCreate(kCFAllocatorDefault, pubkey_bytes, WD_PUBKEY_LEN);
    if (!keyData) return 0;

    int keySize = 256;
    CFNumberRef sizeNum = CFNumberCreate(kCFAllocatorDefault, kCFNumberIntType, &keySize);
    const void *keys[] = {kSecAttrKeyType, kSecAttrKeyClass, kSecAttrKeySizeInBits};
    const void *vals[] = {kSecAttrKeyTypeECSECPrimeRandom, kSecAttrKeyClassPublic, sizeNum};
    CFDictionaryRef attrs = CFDictionaryCreate(kCFAllocatorDefault, keys, vals, 3,
                                               &kCFTypeDictionaryKeyCallBacks,
                                               &kCFTypeDictionaryValueCallBacks);
    CFRelease(sizeNum);
    if (!attrs) {
        CFRelease(keyData);
        return 0;
    }

    SecKeyRef pubKey = SecKeyCreateWithData(keyData, attrs, NULL);
    CFRelease(attrs);
    CFRelease(keyData);
    if (!pubKey) return 0;

    CFDataRef msgData = CFDataCreate(kCFAllocatorDefault, msg, (CFIndex)msg_len);
    CFDataRef sigData = CFDataCreate(kCFAllocatorDefault, sig, (CFIndex)sig_len);
    Boolean ok = false;
    if (msgData && sigData) {
        ok = SecKeyVerifySignature(pubKey, kSecKeyAlgorithmECDSASignatureMessageX962SHA256,
                                   msgData, sigData, NULL);
    }
    if (msgData) CFRelease(msgData);
    if (sigData) CFRelease(sigData);
    CFRelease(pubKey);
    return ok ? 1 : 0;
}

static int resolve_console_user(WDMechanism *m, char out_user[65], uid_t *out_uid, gid_t *out_gid, char out_home[256]) {
    // 1. Try authorization context username first.
    const AuthorizationValue *val = NULL;
    AuthorizationContextFlags ctxFlags = 0;
    if (m->plugin->callbacks->GetContextValue(m->engine, kAuthorizationEnvironmentUsername, &ctxFlags, &val) == errAuthorizationSuccess &&
        val && val->data && val->length > 0 && val->length < 65) {
        memcpy(out_user, val->data, val->length);
        out_user[val->length] = '\0';
        // Strip trailing NULs if present.
        struct passwd *pw = getpwnam(out_user);
        if (pw && pw->pw_dir) {
            *out_uid = pw->pw_uid;
            *out_gid = pw->pw_gid;
            strlcpy(out_home, pw->pw_dir, 256);
            return 0;
        }
    }
    // 2. Fallback to console owner (/dev/console).
    struct stat cst;
    if (stat("/dev/console", &cst) == 0 && cst.st_uid != 0) {
        struct passwd *pw = getpwuid(cst.st_uid);
        if (pw && pw->pw_name && pw->pw_dir) {
            strlcpy(out_user, pw->pw_name, 65);
            *out_uid = pw->pw_uid;
            *out_gid = pw->pw_gid;
            strlcpy(out_home, pw->pw_dir, 256);
            return 0;
        }
    }
    return -1;
}

static int is_user_in_admin_group(const char *username, gid_t primary_gid) {
    struct group *gr = getgrnam("admin");
    if (!gr) return 0;
    gid_t admin_gid = gr->gr_gid;
    if (primary_gid == admin_gid) return 1;
    int groups[64];
    int ngroups = 64;
    if (getgrouplist(username, (int)primary_gid, groups, &ngroups) == 0) {
        for (int i = 0; i < ngroups; i++) {
            if ((gid_t)groups[i] == admin_gid) return 1;
        }
    }
    return 0;
}

// Admin approvals are for the person at the Mac: a requesting app can pre-fill another
// username in the context, so it must be the console user (audit SEC-04).
static int is_console_user(uid_t uid) {
    struct stat cst;
    return stat("/dev/console", &cst) == 0 && cst.st_uid != 0 && cst.st_uid == uid;
}

static void *unlock_worker(void *arg) {
    WDMechanism *m = (WDMechanism *)arg;
    char username[65] = {0};
    char home_dir[256] = {0};
    uid_t uid = 0;
    gid_t gid = 0;
    uint8_t pubkey[WD_PUBKEY_LEN];

    if (resolve_console_user(m, username, &uid, &gid, home_dir) != 0 ||
        (m->is_admin && !is_console_user(uid)) ||
        (m->is_admin && !is_user_in_admin_group(username, gid)) ||
        load_enrolled_pubkey(username, pubkey) != 0) {
        // Not enrolled (or not admin for admin mechanism): stay passive until deactivated.
        while (!atomic_load(&m->deactivating)) usleep(250000);
        mech_release(m);
        return NULL;
    }

    const char *service = m->is_admin ? "admin" : "lockscreen";
    size_t svc_len = strlen(service);
    size_t usr_len = strlen(username);
    char reason[128];
    snprintf(reason, sizeof(reason), m->is_admin ? "Authorize Admin Action (%s)" : "Unlock Mac (%s)", username);
    size_t rsn_len = strlen(reason);

    while (!atomic_load(&m->deactivating)) {
        int fd = connect_bridge(home_dir, uid);
        if (fd < 0) {
            usleep(500000);
            continue;
        }
        atomic_store(&m->bridge_fd, fd);

        uint8_t nonce[WD_NONCE_LEN];
        if (SecRandomCopyBytes(kSecRandomDefault, WD_NONCE_LEN, nonce) != errSecSuccess) {
            atomic_store(&m->bridge_fd, -1);
            close(fd);
            usleep(500000);
            continue;
        }

        uint8_t req[1 + 2 + 64 + 2 + 64 + 2 + 128 + 1 + WD_NONCE_LEN];
        size_t off = 0;
        req[off++] = 1;
        req[off++] = (uint8_t)(svc_len >> 8); req[off++] = (uint8_t)(svc_len & 0xFF);
        memcpy(req + off, service, svc_len); off += svc_len;
        req[off++] = (uint8_t)(usr_len >> 8); req[off++] = (uint8_t)(usr_len & 0xFF);
        memcpy(req + off, username, usr_len); off += usr_len;
        req[off++] = (uint8_t)(rsn_len >> 8); req[off++] = (uint8_t)(rsn_len & 0xFF);
        memcpy(req + off, reason, rsn_len); off += rsn_len;
        req[off++] = WD_NONCE_LEN;
        memcpy(req + off, nonce, WD_NONCE_LEN); off += WD_NONCE_LEN;

        if (write_all_interruptible(fd, req, off, &m->deactivating) != 0) {
            atomic_store(&m->bridge_fd, -1);
            close(fd);
            usleep(500000);
            continue;
        }

        uint8_t hdr[3];
        if (read_all_interruptible(fd, hdr, 3, &m->deactivating) != 0) {
            atomic_store(&m->bridge_fd, -1);
            close(fd);
            usleep(500000);
            continue;
        }

        uint8_t status = hdr[0];
        uint16_t sig_len = ((uint16_t)hdr[1] << 8) | (uint16_t)hdr[2];
        uint8_t sig[WD_MAX_SIG_LEN];
        int got_sig = 0;
        if (status == 0 && sig_len > 0 && sig_len <= WD_MAX_SIG_LEN) {
            if (read_all_interruptible(fd, sig, sig_len, &m->deactivating) == 0) {
                got_sig = 1;
            }
        }
        atomic_store(&m->bridge_fd, -1);
        close(fd);

        if (atomic_load(&m->deactivating)) break;

        if (got_sig) {
            static const char domain[] = "WiredDisplay PAM v1";
            uint8_t msg[sizeof(domain) + 64 + 1 + 64 + 1 + WD_NONCE_LEN];
            size_t moff = 0;
            memcpy(msg + moff, domain, sizeof(domain)); moff += sizeof(domain);
            memcpy(msg + moff, service, svc_len); moff += svc_len;
            msg[moff++] = 0;
            memcpy(msg + moff, username, usr_len); moff += usr_len;
            msg[moff++] = 0;
            memcpy(msg + moff, nonce, WD_NONCE_LEN); moff += WD_NONCE_LEN;

            int open_state = 0;
            if (verify_p256_signature(pubkey, msg, moff, sig, sig_len) &&
                atomic_compare_exchange_strong(&m->finished, &open_state, 2)) {
                if (m->is_admin) {
                    AuthorizationValue userVal = { usr_len + 1, username };
                    m->plugin->callbacks->SetContextValue(m->engine, kAuthorizationEnvironmentUsername,
                                                          kAuthorizationContextFlagExtractable, &userVal);
                }
                m->plugin->callbacks->SetResult(m->engine, kAuthorizationResultAllow);
                mech_release(m);
                return NULL;
            }
        }
        // Cancelled or failed: wait briefly and re-arm with a fresh nonce so the user can retry.
        usleep(500000);
    }

    mech_release(m);
    return NULL;
}

static OSStatus PluginDestroy(AuthorizationPluginRef inPlugin) {
    free(inPlugin);
    return errAuthorizationSuccess;
}

static OSStatus MechanismCreate(AuthorizationPluginRef inPlugin,
                                AuthorizationEngineRef inEngine,
                                AuthorizationMechanismId mechanismId,
                                AuthorizationMechanismRef *outMechanism) {
    WDMechanism *m = calloc(1, sizeof(WDMechanism));
    if (!m) return errAuthorizationInternal;
    m->plugin = (WDPlugin *)inPlugin;
    m->engine = inEngine;
    m->is_admin = (mechanismId && strcmp(mechanismId, "admin") == 0) ? 1 : 0;
    atomic_init(&m->deactivating, 0);
    atomic_init(&m->finished, 0);
    atomic_init(&m->bridge_fd, -1);
    atomic_init(&m->refcount, 1);
    *outMechanism = m;
    return errAuthorizationSuccess;
}

static OSStatus MechanismInvoke(AuthorizationMechanismRef inMechanism) {
    WDMechanism *m = (WDMechanism *)inMechanism;
    atomic_fetch_add(&m->refcount, 1);
    pthread_t th;
    pthread_attr_t attr;
    pthread_attr_init(&attr);
    pthread_attr_setdetachstate(&attr, PTHREAD_CREATE_DETACHED);
    if (pthread_create(&th, &attr, unlock_worker, m) != 0) {
        pthread_attr_destroy(&attr);
        mech_release(m);
        return errAuthorizationInternal;
    }
    pthread_attr_destroy(&attr);
    return errAuthorizationSuccess;
}

static OSStatus MechanismDeactivate(AuthorizationMechanismRef inMechanism) {
    WDMechanism *m = (WDMechanism *)inMechanism;
    int open_state = 0;
    atomic_compare_exchange_strong(&m->finished, &open_state, 1);
    atomic_store(&m->deactivating, 1);
    int fd = atomic_exchange(&m->bridge_fd, -1);
    if (fd >= 0) {
        shutdown(fd, SHUT_RDWR);
    }
    return m->plugin->callbacks->DidDeactivate(m->engine);
}

static OSStatus MechanismDestroy(AuthorizationMechanismRef inMechanism) {
    WDMechanism *m = (WDMechanism *)inMechanism;
    int open_state = 0;
    atomic_compare_exchange_strong(&m->finished, &open_state, 1);
    atomic_store(&m->deactivating, 1);
    int fd = atomic_exchange(&m->bridge_fd, -1);
    if (fd >= 0) {
        shutdown(fd, SHUT_RDWR);
    }
    mech_release(m);
    return errAuthorizationSuccess;
}

static AuthorizationPluginInterface gPluginInterface = {
    kAuthorizationPluginInterfaceVersion,
    PluginDestroy,
    MechanismCreate,
    MechanismInvoke,
    MechanismDeactivate,
    MechanismDestroy
};

OSStatus AuthorizationPluginCreate(const AuthorizationCallbacks *callbacks,
                                   AuthorizationPluginRef *outPlugin,
                                   const AuthorizationPluginInterface **outPluginInterface) {
    WDPlugin *plugin = calloc(1, sizeof(WDPlugin));
    if (!plugin) return errAuthorizationInternal;
    plugin->callbacks = callbacks;
    *outPlugin = plugin;
    *outPluginInterface = &gPluginInterface;
    return errAuthorizationSuccess;
}
