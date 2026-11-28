#!/usr/bin/env bash
set -euo pipefail

# Builds and installs:
# 1. pam_wireddisplay.so (/usr/local/lib/pam/pam_wireddisplay.so) for sudo via /etc/pam.d/sudo_local.
# 2. WiredDisplayAuth.bundle (/Library/Security/SecurityAgentPlugins/WiredDisplayAuth.bundle)
#    registered in authorizationdb (system.login.screensaver, k-of-n: 1) for Lock Screen unlock.
# Run with: sudo scripts/install-pam.sh [--sudo-only]

if [[ "${EUID}" -ne 0 ]]; then
    echo "error: run with sudo (e.g. sudo scripts/install-pam.sh [--with-screensaver])" >&2
    exit 1
fi

WITH_SCREENSAVER=1
for arg in "$@"; do
    case "$arg" in
        --with-screensaver) WITH_SCREENSAVER=1 ;;
        --sudo-only) WITH_SCREENSAVER=0 ;;
        *) echo "unknown option: $arg" >&2; exit 1 ;;
    esac
done

TARGET_USER="${SUDO_USER:-$(stat -f%Su /dev/console)}"
if [[ -z "${TARGET_USER}" || "${TARGET_USER}" == "root" ]]; then
    echo "error: could not determine target macOS user" >&2
    exit 1
fi
TARGET_HOME=$(dscl . -read "/Users/${TARGET_USER}" NFSHomeDirectory | awk '{print $2}')

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="${REPO_ROOT}/MacVirtualDevices/PamModule/pam_wireddisplay.c"
AUTH_SRC="${REPO_ROOT}/MacVirtualDevices/AuthPlugin/WiredDisplayAuth.c"
AUTH_PLIST="${REPO_ROOT}/MacVirtualDevices/AuthPlugin/Info.plist"
INSTALL_DIR="/Library/Application Support/WiredDisplay"
KEY_DIR="${INSTALL_DIR}/pam_keys"
PAM_DIR="/usr/local/lib/pam"
# OpenPAM splits /etc/pam.d/* lines on whitespace, so the .so path must not contain spaces.
PAM_SO="${PAM_DIR}/pam_wireddisplay.so"
OLD_PAM_SO="${INSTALL_DIR}/pam_wireddisplay.so"
AUTH_BUNDLE_DIR="/Library/Security/SecurityAgentPlugins/WiredDisplayAuth.bundle"
AUTH_RULE_NAME="dev.wireddisplay.auth.unlock"
ADMIN_RULE_NAME="dev.wireddisplay.auth.admin"
SCREENSAVER_BACKUP="${INSTALL_DIR}/screensaver_backup.plist"
AUTHDB_BACKUP_DIR="${INSTALL_DIR}/authdb_backups"
ADMIN_RIGHTS=(
    "system.preferences"
    "system.preferences.security"
    "system.preferences.network"
    "system.install.software"
    "system.privilege.admin"
    "authenticate-admin"
    "authenticate-admin-nonshared"
)
KEY_FILE="${KEY_DIR}/${TARGET_USER}.pub"
CACHED_KEY="${TARGET_HOME}/Library/Caches/dev.wireddisplay.host/last_biometric_key.b64"

if [[ ! -f "${CACHED_KEY}" ]]; then
    echo "error: no enrolled iPad biometric key found at ${CACHED_KEY}" >&2
    echo "1. Connect your iPad to WiredDisplay over USB-C." >&2
    echo "2. On the iPad, open Controls > More > Enroll Face ID / Touch ID Key." >&2
    echo "3. Re-run this script." >&2
    exit 1
fi

mkdir -p "${KEY_DIR}" "${PAM_DIR}"
chown root:wheel "${INSTALL_DIR}" "${KEY_DIR}" "${PAM_DIR}"
chmod 755 "${INSTALL_DIR}" "${KEY_DIR}" "${PAM_DIR}"
rm -f "${OLD_PAM_SO}"

TMP_SO="$(mktemp -d)/pam_wireddisplay.so"
trap 'rm -rf "$(dirname "${TMP_SO}")"' EXIT

echo "Building pam_wireddisplay.so..."
clang -shared -fPIC -O2 -Wall -Wextra -arch arm64 \
    -framework Security -framework CoreFoundation -lpam \
    "${SRC}" -o "${TMP_SO}"
codesign --force --sign - "${TMP_SO}"

install -o root -g wheel -m 755 "${TMP_SO}" "${PAM_SO}"
install -o root -g wheel -m 644 "${CACHED_KEY}" "${KEY_FILE}"

FP=$(base64 -d < "${KEY_FILE}" | shasum -a 256 | cut -c1-8)
echo "Installed ${PAM_SO}"
echo "Enrolled biometric public key for ${TARGET_USER} (fingerprint: ${FP})"

PAM_LINE="auth       sufficient     ${PAM_SO}"

ensure_pam_entry() {
    local file="$1"
    if [[ ! -f "${file}" ]]; then
        printf "# WiredDisplay iPad Touch ID / Face ID authentication\n%s\n" "${PAM_LINE}" > "${file}"
        chown root:wheel "${file}"
        chmod 644 "${file}"
        echo "Created ${file}"
        return
    fi
    # Clean up any legacy path containing spaces before inserting the valid path.
    if grep -Fq "${OLD_PAM_SO}" "${file}"; then
        local cleaned="${file}.wd.clean"
        grep -Fv "${OLD_PAM_SO}" "${file}" > "${cleaned}" || true
        mv "${cleaned}" "${file}"
    fi
    if grep -Fq "${PAM_SO}" "${file}"; then
        echo "${file} already configured"
        return
    fi
    # Insert right after leading comments so it runs before pam_opendirectory.
    local tmp="${file}.wd.tmp"
    awk -v line="${PAM_LINE}" '
        !inserted && $0 !~ /^#/ && $0 !~ /^[[:space:]]*$/ { print line; inserted=1 }
        { print }
        END { if (!inserted) print line }
    ' "${file}" > "${tmp}"
    mv "${tmp}" "${file}"
    chown root:wheel "${file}"
    chmod 644 "${file}"
    echo "Updated ${file}"
}

ensure_pam_entry "/etc/pam.d/sudo_local"

# Remove legacy /etc/pam.d/screensaver entry if present (Lock Screen now uses WiredDisplayAuth.bundle).
if [[ -f "/etc/pam.d/screensaver" ]] && grep -Fq "pam_wireddisplay.so" "/etc/pam.d/screensaver"; then
    CLEAN_SS="/etc/pam.d/screensaver.wd.clean"
    grep -Fv "pam_wireddisplay.so" "/etc/pam.d/screensaver" > "${CLEAN_SS}" || true
    mv "${CLEAN_SS}" "/etc/pam.d/screensaver"
    chown root:wheel "/etc/pam.d/screensaver"
    chmod 644 "/etc/pam.d/screensaver"
    echo "Cleaned legacy WiredDisplay entry from /etc/pam.d/screensaver"
fi

if [[ "${WITH_SCREENSAVER}" -eq 1 ]]; then
    echo "Building WiredDisplayAuth.bundle for macOS Lock Screen..."
    TMP_BUILD_DIR="$(dirname "${TMP_SO}")"
    TMP_BUNDLE="${TMP_BUILD_DIR}/WiredDisplayAuth.bundle"
    mkdir -p "${TMP_BUNDLE}/Contents/MacOS"
    cp "${AUTH_PLIST}" "${TMP_BUNDLE}/Contents/Info.plist"
    clang -bundle -fPIC -O2 -Wall -Wextra -arch arm64 \
        -framework Security -framework CoreFoundation \
        "${AUTH_SRC}" -o "${TMP_BUNDLE}/Contents/MacOS/WiredDisplayAuth"
    codesign --force --sign - "${TMP_BUNDLE}"

    mkdir -p "/Library/Security/SecurityAgentPlugins"
    rm -rf "${AUTH_BUNDLE_DIR}"
    cp -R "${TMP_BUNDLE}" "${AUTH_BUNDLE_DIR}"
    chown -R root:wheel "${AUTH_BUNDLE_DIR}"
    chmod 755 "${AUTH_BUNDLE_DIR}" "${AUTH_BUNDLE_DIR}/Contents" "${AUTH_BUNDLE_DIR}/Contents/MacOS" "${AUTH_BUNDLE_DIR}/Contents/MacOS/WiredDisplayAuth"
    chmod 644 "${AUTH_BUNDLE_DIR}/Contents/Info.plist"
    echo "Installed ${AUTH_BUNDLE_DIR}"

    if [[ ! -f "${SCREENSAVER_BACKUP}" ]]; then
        security authorizationdb read system.login.screensaver > "${SCREENSAVER_BACKUP}" 2>/dev/null
        chown root:wheel "${SCREENSAVER_BACKUP}"
        chmod 644 "${SCREENSAVER_BACKUP}"
        echo "Backed up system.login.screensaver to ${SCREENSAVER_BACKUP}"
    fi

    RULE_PLIST="${TMP_BUILD_DIR}/auth_rule.plist"
    cat > "${RULE_PLIST}" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>class</key>
    <string>evaluate-mechanisms</string>
    <key>comment</key>
    <string>WiredDisplay iPad Touch ID / Face ID Lock Screen unlock</string>
    <key>mechanisms</key>
    <array>
        <string>WiredDisplayAuth:unlock,privileged</string>
    </array>
    <key>tries</key>
    <integer>10000</integer>
</dict>
</plist>
EOF
    security authorizationdb write "${AUTH_RULE_NAME}" < "${RULE_PLIST}" 2>/dev/null

    SS_CURRENT="${TMP_BUILD_DIR}/ss_current.plist"
    SS_UPDATED="${TMP_BUILD_DIR}/ss_updated.plist"
    security authorizationdb read system.login.screensaver > "${SS_CURRENT}" 2>/dev/null
    python3 - "${SS_CURRENT}" "${SS_UPDATED}" "${AUTH_RULE_NAME}" <<'PYEOF'
import plistlib, sys
src, dst, rule_name = sys.argv[1], sys.argv[2], sys.argv[3]
with open(src, "rb") as f:
    data = plistlib.load(f)
if data.get("class") != "rule" or not isinstance(data.get("rule"), list):
    sys.stderr.write("error: unexpected system.login.screensaver structure; refusing to modify\n")
    sys.exit(1)
if rule_name not in data["rule"]:
    data["rule"].insert(0, rule_name)
data.setdefault("k-of-n", 1)
with open(dst, "wb") as f:
    plistlib.dump(data, f)
PYEOF
    security authorizationdb write system.login.screensaver < "${SS_UPDATED}" 2>/dev/null
    echo "Registered ${AUTH_RULE_NAME} in system.login.screensaver (parallel k-of-n: 1)"

    ADMIN_RULE_PLIST="${TMP_BUILD_DIR}/admin_rule.plist"
    cat > "${ADMIN_RULE_PLIST}" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>class</key>
    <string>evaluate-mechanisms</string>
    <key>comment</key>
    <string>WiredDisplay iPad Touch ID / Face ID macOS admin dialog auth</string>
    <key>mechanisms</key>
    <array>
        <string>WiredDisplayAuth:admin,privileged</string>
    </array>
    <key>shared</key>
    <true/>
    <key>timeout</key>
    <integer>300</integer>
    <key>tries</key>
    <integer>10000</integer>
</dict>
</plist>
EOF
    security authorizationdb write "${ADMIN_RULE_NAME}" < "${ADMIN_RULE_PLIST}" 2>/dev/null

    mkdir -p "${AUTHDB_BACKUP_DIR}"
    chown root:wheel "${AUTHDB_BACKUP_DIR}"
    chmod 755 "${AUTHDB_BACKUP_DIR}"

    for right in "${ADMIN_RIGHTS[@]}"; do
        CUR_PLIST="${TMP_BUILD_DIR}/${right}.cur.plist"
        if ! security authorizationdb read "${right}" > "${CUR_PLIST}" 2>/dev/null; then
            continue
        fi
        if python3 - "${CUR_PLIST}" "${ADMIN_RULE_NAME}" <<'PYEOF'
import plistlib, sys
with open(sys.argv[1], "rb") as f:
    data = plistlib.load(f)
rules = data.get("rule")
sys.exit(0 if (data.get("class") == "rule" and isinstance(rules, list) and sys.argv[2] in rules) else 1)
PYEOF
        then
            continue
        fi
        BACKUP_FILE="${AUTHDB_BACKUP_DIR}/${right}.plist"
        if [[ ! -f "${BACKUP_FILE}" ]]; then
            cp "${CUR_PLIST}" "${BACKUP_FILE}"
            chown root:wheel "${BACKUP_FILE}"
            chmod 644 "${BACKUP_FILE}"
        fi
        ORIG_SUBRULE="dev.wireddisplay.auth.orig.${right}"
        security authorizationdb write "${ORIG_SUBRULE}" < "${CUR_PLIST}" 2>/dev/null
        WRAPPED_PLIST="${TMP_BUILD_DIR}/${right}.wrapped.plist"
        cat > "${WRAPPED_PLIST}" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>class</key>
    <string>rule</string>
    <key>comment</key>
    <string>WiredDisplay parallel Touch ID / Face ID + macOS password fallback</string>
    <key>k-of-n</key>
    <integer>1</integer>
    <key>rule</key>
    <array>
        <string>${ADMIN_RULE_NAME}</string>
        <string>${ORIG_SUBRULE}</string>
    </array>
</dict>
</plist>
EOF
        security authorizationdb write "${right}" < "${WRAPPED_PLIST}" 2>/dev/null
    done
    echo "Registered ${ADMIN_RULE_NAME} for macOS admin dialogs (parallel k-of-n: 1)"
fi

echo ""
echo "Done!"
echo "  Test sudo:          sudo -k && sudo -v"
if [[ "${WITH_SCREENSAVER}" -eq 1 ]]; then
    echo "  Test Lock Screen:   Control+Command+Q -> press Enter -> Touch ID on iPad"
    echo "  Test Admin Dialog:  Unlock a System Settings lock or install a .pkg -> Touch ID on iPad"
fi
echo "  To remove later:    sudo scripts/uninstall-pam.sh"
