#!/usr/bin/env bash
set -euo pipefail

# Cleanly removes pam_wireddisplay.so from /etc/pam.d/sudo_local and /etc/pam.d/screensaver,
# unregisters WiredDisplayAuth.bundle from authorizationdb (system.login.screensaver),
# and deletes installed files under /Library/Application Support/WiredDisplay.

if [[ "${EUID}" -ne 0 ]]; then
    echo "error: run with sudo (sudo scripts/uninstall-pam.sh)" >&2
    exit 1
fi

INSTALL_DIR="/Library/Application Support/WiredDisplay"
PAM_SO="/usr/local/lib/pam/pam_wireddisplay.so"
OLD_PAM_SO="${INSTALL_DIR}/pam_wireddisplay.so"

remove_pam_entry() {
    local file="$1"
    [[ -f "${file}" ]] || return 0
    if grep -Fq "pam_wireddisplay.so" "${file}"; then
        local tmp="${file}.wd.tmp"
        grep -Fv "pam_wireddisplay.so" "${file}" > "${tmp}" || true
        mv "${tmp}" "${file}"
        chown root:wheel "${file}"
        chmod 644 "${file}"
        echo "Removed WiredDisplay entry from ${file}"
    fi
}

remove_pam_entry "/etc/pam.d/sudo_local"
remove_pam_entry "/etc/pam.d/screensaver"

AUTH_BUNDLE_DIR="/Library/Security/SecurityAgentPlugins/WiredDisplayAuth.bundle"
AUTH_RULE_NAME="dev.wireddisplay.auth.unlock"
ADMIN_RULE_NAME="dev.wireddisplay.auth.admin"
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

PB=/usr/libexec/PlistBuddy
# Prints the index of NAME in the plist's :rule array; fails if absent.
rule_index() {
    local file="$1" name="$2" i=0 value
    while value=$("${PB}" -c "Print :rule:${i}" "${file}" 2>/dev/null); do
        [[ "${value}" == "${name}" ]] && { echo "${i}"; return 0; }
        i=$((i + 1))
    done
    return 1
}

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT
if security authorizationdb read system.login.screensaver > "${TMP_DIR}/ss.plist" 2>/dev/null; then
    if rule_index "${TMP_DIR}/ss.plist" "${AUTH_RULE_NAME}" >/dev/null; then
        cp "${TMP_DIR}/ss.plist" "${TMP_DIR}/ss_clean.plist"
        while IDX=$(rule_index "${TMP_DIR}/ss_clean.plist" "${AUTH_RULE_NAME}"); do
            "${PB}" -c "Delete :rule:${IDX}" "${TMP_DIR}/ss_clean.plist"
        done
        security authorizationdb write system.login.screensaver < "${TMP_DIR}/ss_clean.plist" 2>/dev/null
        echo "Removed ${AUTH_RULE_NAME} from system.login.screensaver"
    fi
fi
security authorizationdb remove "${AUTH_RULE_NAME}" 2>/dev/null || true

for right in "${ADMIN_RIGHTS[@]}"; do
    ORIG_SUBRULE="dev.wireddisplay.auth.orig.${right}"
    RESTORE_PLIST="${TMP_DIR}/${right}.restore.plist"
    if security authorizationdb read "${ORIG_SUBRULE}" > "${RESTORE_PLIST}" 2>/dev/null; then
        security authorizationdb write "${right}" < "${RESTORE_PLIST}" 2>/dev/null
        security authorizationdb remove "${ORIG_SUBRULE}" 2>/dev/null || true
        echo "Restored ${right}"
    elif [[ -f "${AUTHDB_BACKUP_DIR}/${right}.plist" ]]; then
        security authorizationdb write "${right}" < "${AUTHDB_BACKUP_DIR}/${right}.plist" 2>/dev/null
        echo "Restored ${right} from backup"
    fi
done
security authorizationdb remove "${ADMIN_RULE_NAME}" 2>/dev/null || true
rm -rf "${AUTH_BUNDLE_DIR}"

rm -f "${PAM_SO}" "${OLD_PAM_SO}"
rm -rf "${INSTALL_DIR}/pam_keys"
echo "Removed ${PAM_SO}, ${AUTH_BUNDLE_DIR}, and enrolled PAM keys."
