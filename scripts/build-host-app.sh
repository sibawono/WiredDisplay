#!/bin/bash
# Builds WiredDisplayHost.app (menu-bar app, no Dock icon) into build/.
#
# Signed with the first "Apple Development" identity in the keychain so the
# app keeps a stable designated requirement (team + bundle ID): Screen
# Recording and Accessibility grants then survive rebuilds (RISKS R-15).
# Override with SIGN_IDENTITY="<sha1 or name>" or SIGN_IDENTITY=- (ad hoc).
#
# Not sandboxed (usbmuxd socket + private CGVirtualDisplay); not notarized.
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${CONFIG:-release}"
swift build -c "$CONFIG" --product WiredDisplayHost
BIN="$(swift build -c "$CONFIG" --show-bin-path)/WiredDisplayHost"

# Assemble and sign OUTSIDE the project: ~/Documents is synced by iCloud Drive
# here, which tags files with com.apple.fileprovider attributes that codesign
# rejects and creates "… 2.app" conflict copies.
STAGE="$(mktemp -d "${TMPDIR:-/tmp}/wd-host-stage.XXXXXX")"
trap 'rm -rf "$STAGE"' EXIT
APP="$STAGE/WiredDisplayHost.app"
mkdir -p "$APP/Contents/MacOS"
cp "$BIN" "$APP/Contents/MacOS/WiredDisplayHost"
# No debug map in shipped binaries: it holds absolute build paths (the
# builder's home folder). Symbol names stay; only the debug entries go.
strip -S "$APP/Contents/MacOS/WiredDisplayHost"
mkdir -p "$APP/Contents/Resources"
cp macOSHost/Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns" # scripts/make-icons.sh

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>dev.wireddisplay.host</string>
  <key>CFBundleName</key><string>WiredDisplayHost</string>
  <key>CFBundleDisplayName</key><string>WiredDisplay</string>
  <key>CFBundleExecutable</key><string>WiredDisplayHost</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.5.6</string>
  <key>CFBundleVersion</key><string>17</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSMicrophoneUsageDescription</key>
  <string>WiredDisplay records the "iPad Speaker" loopback device to send Mac audio to your iPad. It does not record your Mac's own microphone.</string>
</dict>
</plist>
PLIST

# Hardened runtime blocks audio input unless the app declares it (D-017).
cat > "$STAGE/entitlements.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>com.apple.security.device.audio-input</key><true/>
</dict>
</plist>
PLIST

IDENTITY="${SIGN_IDENTITY:-$(security find-identity -v -p codesigning | awk '/Apple Development/ {print $2; exit}')}"
IDENTITY="${IDENTITY:--}"
# Extended attributes (provenance, Finder info) make codesign refuse the bundle.
xattr -cr "$APP"
codesign --force --options runtime --timestamp=none --entitlements "$STAGE/entitlements.plist" --sign "$IDENTITY" "$APP"
codesign --verify --strict "$APP"
echo "built $APP (signed with ${IDENTITY:0:8}…)"
codesign -dr - "$APP" 2>&1 | sed -n 's/^designated => /designated requirement: /p'

# Install outside TCC-protected folders (BUG-023): creating a VideoToolbox
# encoder walks the folders around the app bundle, and inside ~/Documents that
# blocks on a "access your Documents folder" prompt, hanging the host.
INSTALL_DIR="${INSTALL_DIR:-$HOME/Applications}"
mkdir -p "$INSTALL_DIR"
if pgrep -x WiredDisplayHost >/dev/null; then echo "note: WiredDisplayHost is running; quit it before launching the new build"; fi
rm -rf "$INSTALL_DIR/WiredDisplayHost.app"
ditto "$APP" "$INSTALL_DIR/WiredDisplayHost.app"
echo "installed $INSTALL_DIR/WiredDisplayHost.app — run it with: open \"$INSTALL_DIR/WiredDisplayHost.app\""
