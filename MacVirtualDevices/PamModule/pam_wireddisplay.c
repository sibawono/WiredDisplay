// pam_wireddisplay.c — macOS PAM module for WiredDisplay iPad Touch ID / Face ID authentication.
//
// Security model (Root-to-Secure-Enclave):
// 1. Loads the user's enrolled 65-byte ECDSA P-256 public key from a root-owned, non-user-writable
//    file at `/Library/Application Support/WiredDisplay/pam_keys/<username>.pub` (base64 X9.63).
// 2. Generates a fresh 32-byte cryptographic nonce via SecRandomCopyBytes().
// 3. Relays the challenge through WiredDisplayHost's local Unix socket to the USB-C connected iPad.
// 4. Verifies the returned ECDSA P-256 signature over
//      "WiredDisplay PAM v1\0" || service || "\0" || username || "\0" || nonce(32)
//    directly using Security.framework.
// 5. Fails safe: if no key is enrolled, WiredDisplayHost is not running, no iPad is connected,
//    or the user cancels/times out, returns PAM_IGNORE so macOS falls back to password auth.

#define PAM_SM_AUTH
#include <CoreFoundation/CoreFoundation.h>
#include <Security/Security.h>
#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <pwd.h>
#include <security/pam_appl.h>
#include <security/pam_modules.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/time.h>
#include <sys/un.h>
#include <unistd.h>

#define WD_KEY_DIR "/Library/Application Support/WiredDisplay/pam_keys"
#define WD_NONCE_LEN 32
#define WD_PUBKEY_LEN 65
#define WD_MAX_SIG_LEN 128

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
    // Must be a regular file owned by root and not writable by group or others.
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

static int write_all(int fd, const uint8_t *buf, size_t len) {
    size_t sent = 0;
    while (sent < len) {
        ssize_t n = write(fd, buf + sent, len - sent);
        if (n < 0 && errno == EINTR) continue;
        if (n <= 0) return -1;
        sent += (size_t)n;
    }
    return 0;
}

static int read_all(int fd, uint8_t *buf, size_t len) {
    size_t got = 0;
    while (got < len) {
        ssize_t n = read(fd, buf + got, len - got);
        if (n < 0 && errno == EINTR) continue;
        if (n <= 0) return -1;
        got += (size_t)n;
    }
    return 0;
}

static int connect_bridge(const char *home_dir, uid_t expected_uid, int timeout_sec) {
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

    // Fast non-blocking connect (<= 200 ms) so missing/idle host never slows down sudo.
    int flags = fcntl(fd, F_GETFL, 0);
    if (flags >= 0) fcntl(fd, F_SETFL, flags | O_NONBLOCK);
    int rc = connect(fd, (struct sockaddr *)&addr, sizeof(addr));
    if (rc != 0 && errno == EINPROGRESS) {
        struct pollfd pfd = {fd, POLLOUT, 0};
        if (poll(&pfd, 1, 200) <= 0) {
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
    if (flags >= 0) fcntl(fd, F_SETFL, flags);

    // Verify the bridge peer belongs to the authenticating user.
    uid_t peer_uid = (uid_t)-1;
    gid_t peer_gid = (gid_t)-1;
    if (getpeereid(fd, &peer_uid, &peer_gid) != 0 || peer_uid != expected_uid) {
        close(fd);
        return -1;
    }

    struct timeval tv;
    tv.tv_sec = timeout_sec;
    tv.tv_usec = 0;
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));
    tv.tv_sec = 2;
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, sizeof(tv));
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

PAM_EXTERN int pam_sm_authenticate(pam_handle_t *pamh, int flags, int argc, const char **argv) {
    (void)flags; (void)argc; (void)argv;

    const char *username = NULL;
    if (pam_get_user(pamh, &username, NULL) != PAM_SUCCESS || !username) {
        return PAM_IGNORE;
    }

    uint8_t pubkey[WD_PUBKEY_LEN];
    if (load_enrolled_pubkey(username, pubkey) != 0) {
        return PAM_IGNORE;
    }

    struct passwd *pw = getpwnam(username);
    if (!pw || !pw->pw_dir) {
        return PAM_IGNORE;
    }

    const char *service = NULL;
    if (pam_get_item(pamh, PAM_SERVICE, (const void **)&service) != PAM_SUCCESS || !service) {
        service = "macos";
    }

    int is_screensaver = (strcmp(service, "screensaver") == 0);
    int fd = connect_bridge(pw->pw_dir, pw->pw_uid, is_screensaver ? 11 : 16);
    if (fd < 0) {
        return PAM_IGNORE;
    }

    uint8_t nonce[WD_NONCE_LEN];
    if (SecRandomCopyBytes(kSecRandomDefault, WD_NONCE_LEN, nonce) != errSecSuccess) {
        close(fd);
        return PAM_IGNORE;
    }

    char reason[128];
    if (is_screensaver) {
        snprintf(reason, sizeof(reason), "Unlock Mac (%s)", username);
    } else {
        snprintf(reason, sizeof(reason), "Approve %s for %s on Mac", service, username);
    }

    size_t svc_len = strlen(service);
    size_t usr_len = strlen(username);
    size_t rsn_len = strlen(reason);
    if (svc_len > 64) svc_len = 64;
    if (usr_len > 64) usr_len = 64;
    if (rsn_len > 128) rsn_len = 128;

    uint8_t req[1 + 2 + 64 + 2 + 64 + 2 + 128 + 1 + WD_NONCE_LEN];
    size_t off = 0;
    req[off++] = 1; // version
    req[off++] = (uint8_t)(svc_len >> 8); req[off++] = (uint8_t)(svc_len & 0xFF);
    memcpy(req + off, service, svc_len); off += svc_len;
    req[off++] = (uint8_t)(usr_len >> 8); req[off++] = (uint8_t)(usr_len & 0xFF);
    memcpy(req + off, username, usr_len); off += usr_len;
    req[off++] = (uint8_t)(rsn_len >> 8); req[off++] = (uint8_t)(rsn_len & 0xFF);
    memcpy(req + off, reason, rsn_len); off += rsn_len;
    req[off++] = WD_NONCE_LEN;
    memcpy(req + off, nonce, WD_NONCE_LEN); off += WD_NONCE_LEN;

    if (write_all(fd, req, off) != 0) {
        close(fd);
        return PAM_IGNORE;
    }

    uint8_t hdr[3];
    if (read_all(fd, hdr, 3) != 0) {
        close(fd);
        return PAM_IGNORE;
    }
    uint8_t status = hdr[0];
    uint16_t sig_len = ((uint16_t)hdr[1] << 8) | (uint16_t)hdr[2];
    if (status != 0 || sig_len == 0 || sig_len > WD_MAX_SIG_LEN) {
        close(fd);
        return PAM_IGNORE;
    }

    uint8_t sig[WD_MAX_SIG_LEN];
    if (read_all(fd, sig, sig_len) != 0) {
        close(fd);
        return PAM_IGNORE;
    }
    close(fd);

    // Reconstruct canonical message: "WiredDisplay PAM v1\0" || service || "\0" || username || "\0" || nonce(32)
    static const char domain[] = "WiredDisplay PAM v1";
    uint8_t msg[sizeof(domain) + 64 + 1 + 64 + 1 + WD_NONCE_LEN];
    size_t moff = 0;
    memcpy(msg + moff, domain, sizeof(domain)); moff += sizeof(domain); // includes trailing NUL
    memcpy(msg + moff, service, svc_len); moff += svc_len;
    msg[moff++] = 0;
    memcpy(msg + moff, username, usr_len); moff += usr_len;
    msg[moff++] = 0;
    memcpy(msg + moff, nonce, WD_NONCE_LEN); moff += WD_NONCE_LEN;

    if (verify_p256_signature(pubkey, msg, moff, sig, sig_len)) {
        return PAM_SUCCESS;
    }
    return PAM_AUTH_ERR;
}

PAM_EXTERN int pam_sm_setcred(pam_handle_t *pamh, int flags, int argc, const char **argv) {
    (void)pamh; (void)flags; (void)argc; (void)argv;
    return PAM_SUCCESS;
}
