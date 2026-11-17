#!/bin/bash
# Builds and signs WiredDisplayAudio.driver (AudioServerPlugIn) outside the
# iCloud-synced project folder, then prints the admin commands to install it.
# This script itself never uses sudo.
set -euo pipefail
cd "$(dirname "$0")/.."

OUT="${OUT:-$HOME/Library/Developer/WiredDisplay}"
DRIVER="$OUT/WiredDisplayAudio.driver"
STAGE="$(mktemp -d "${TMPDIR:-/tmp}/wd-audio-stage.XXXXXX")"
trap 'rm -rf "$STAGE"' EXIT
BUNDLE="$STAGE/WiredDisplayAudio.driver"
mkdir -p "$BUNDLE/Contents/MacOS"

clang -std=c11 -O2 -Wall -Wextra -Werror -Wno-unused-parameter -arch arm64 -mmacosx-version-min=14.0 \
  -bundle -o "$BUNDLE/Contents/MacOS/WiredDisplayAudio" \
  MacVirtualDevices/AudioDriver/WiredDisplayAudio.c \
  -framework CoreAudio -framework CoreFoundation

cat > "$BUNDLE/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>dev.wireddisplay.audio</string>
  <key>CFBundleName</key><string>WiredDisplayAudio</string>
  <key>CFBundleExecutable</key><string>WiredDisplayAudio</string>
  <key>CFBundlePackageType</key><string>BNDL</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>CFPlugInFactories</key>
  <dict>
    <key>6F3B2C1A-9D4E-4B7F-A2C8-5E1D0F9A7B31</key><string>WiredDisplayAudio_Create</string>
  </dict>
  <key>CFPlugInTypes</key>
  <dict>
    <key>443ABAB8-E7B3-491A-B985-BEB9187030DB</key>
    <array><string>6F3B2C1A-9D4E-4B7F-A2C8-5E1D0F9A7B31</string></array>
  </dict>
</dict>
</plist>
PLIST

IDENTITY="${SIGN_IDENTITY:-$(security find-identity -v -p codesigning | awk '/Apple Development/ {print $2; exit}')}"
xattr -cr "$BUNDLE"
codesign --force --timestamp=none --sign "${IDENTITY:--}" "$BUNDLE"
codesign --verify --strict "$BUNDLE"
mkdir -p "$OUT"
rm -rf "$DRIVER"
ditto "$BUNDLE" "$DRIVER"
echo "built $DRIVER"
echo
echo "Install (needs your admin password; run in Terminal):"
echo "  sudo ditto \"$DRIVER\" /Library/Audio/Plug-Ins/HAL/WiredDisplayAudio.driver && sudo killall coreaudiod"
echo "Uninstall:"
echo "  sudo rm -rf /Library/Audio/Plug-Ins/HAL/WiredDisplayAudio.driver && sudo killall coreaudiod"
