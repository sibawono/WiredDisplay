#!/usr/bin/env bash
# Builds the iPad Touch ID / Face ID modules, ad-hoc signed, into $OUT (default: build/pam):
#   pam_wireddisplay.so        (sudo, via /etc/pam.d/sudo_local)
#   WiredDisplayAuth.bundle    (Lock Screen and admin dialogs, via authorizationdb)
# Needs clang (Xcode Command Line Tools). Used by build-dmg.sh and install-pam.sh.
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${OUT:-${REPO_ROOT}/build/pam}"
mkdir -p "${OUT}"
clang -shared -fPIC -O2 -Wall -Wextra -arch arm64 \
    -framework Security -framework CoreFoundation -lpam \
    "${REPO_ROOT}/MacVirtualDevices/PamModule/pam_wireddisplay.c" -o "${OUT}/pam_wireddisplay.so"
codesign --force --sign - "${OUT}/pam_wireddisplay.so"
BUNDLE="${OUT}/WiredDisplayAuth.bundle"
rm -rf "${BUNDLE}"
mkdir -p "${BUNDLE}/Contents/MacOS"
cp "${REPO_ROOT}/MacVirtualDevices/AuthPlugin/Info.plist" "${BUNDLE}/Contents/Info.plist"
clang -bundle -fPIC -O2 -Wall -Wextra -arch arm64 \
    -framework Security -framework CoreFoundation \
    "${REPO_ROOT}/MacVirtualDevices/AuthPlugin/WiredDisplayAuth.c" -o "${BUNDLE}/Contents/MacOS/WiredDisplayAuth"
codesign --force --sign - "${BUNDLE}"
echo "built ${OUT}/pam_wireddisplay.so and ${BUNDLE}"
