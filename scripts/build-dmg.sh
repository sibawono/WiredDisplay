#!/bin/bash
# Builds dist/WiredDisplay-<version>.dmg: the host app, an Applications
# shortcut, the audio driver with an install/uninstall script, and a README.
#
# Signing: ad-hoc (-) by default for public release DMGs (AGENTS.md). The DMG is
# NOT notarized: on another Mac, Gatekeeper asks the user to approve the app
# once (System Settings > Privacy & Security > Open Anyway).
# This script never uses sudo; the driver installer asks for the password
# when the user runs it.
set -euo pipefail
cd "$(dirname "$0")/.."
export SIGN_IDENTITY="${SIGN_IDENTITY:--}"

VERSION="$(sed -n 's/.*<key>CFBundleShortVersionString<\/key><string>\(.*\)<\/string>.*/\1/p' scripts/build-host-app.sh)"
STAGE="$(mktemp -d "${TMPDIR:-/tmp}/wd-dmg.XXXXXX")"
trap 'rm -rf "$STAGE"' EXIT
ROOT="$STAGE/WiredDisplay"
mkdir -p "$ROOT/Audio Driver" dist

# Host app, built and signed by the regular script into the staging folder.
INSTALL_DIR="$ROOT" ./scripts/build-host-app.sh >/dev/null
ln -s /Applications "$ROOT/Applications"

# Audio driver (HAL plug-in) built and signed by its own script.
OUT="$STAGE/driver" ./scripts/build-audio-driver.sh >/dev/null
ditto "$STAGE/driver/WiredDisplayAudio.driver" "$ROOT/Audio Driver/WiredDisplayAudio.driver"

cat > "$ROOT/Audio Driver/Install Audio Driver.command" <<'EOF'
#!/bin/bash
# Installs the WiredDisplay audio devices ("iPad Speaker", "iPad Microphone").
# Asks for your admin password; restarts Core Audio (sound stops for a second).
set -e
DIR="$(cd "$(dirname "$0")" && pwd)"
echo "Installing WiredDisplayAudio.driver into /Library/Audio/Plug-Ins/HAL …"
sudo ditto "$DIR/WiredDisplayAudio.driver" /Library/Audio/Plug-Ins/HAL/WiredDisplayAudio.driver
sudo killall coreaudiod
echo "Done. \"iPad Speaker\" and \"iPad Microphone\" are now in Sound settings."
EOF
cat > "$ROOT/Audio Driver/Uninstall Audio Driver.command" <<'EOF'
#!/bin/bash
# Removes the WiredDisplay audio devices. Asks for your admin password.
set -e
sudo rm -rf /Library/Audio/Plug-Ins/HAL/WiredDisplayAudio.driver
sudo killall coreaudiod
echo "WiredDisplay audio driver removed."
EOF
chmod +x "$ROOT/Audio Driver/"*.command

cat > "$ROOT/README.txt" <<EOF
WiredDisplay $VERSION — use an iPad as a wired USB-C display for this Mac

1. Drag WiredDisplayHost to Applications (or ~/Applications) and open it.
   It lives in the menu bar (screen + USB icon); there is no Dock icon.
   It adds itself to Login Items (menu: "Open at Login" to turn off).
2. Grant Screen Recording (required), and Accessibility if you want touch
   input from the iPad. Microphone access is only for sending Mac audio
   to the iPad speaker.
3. Connect the iPad with a USB-C cable and open the WiredDisplay app on it.
   USB only: there is no Wi-Fi fallback.
4. Optional audio: run "Audio Driver/Install Audio Driver.command"
   (asks for your password), then pick "iPad Speaker" / "iPad Microphone".

Options (Terminal): open WiredDisplayHost.app --args --allow-input
  --codec h264|hevc   --bitrate-mbps 5…150   --fps 24…120
  --chroma 420|444|hybrid   --depth 8|10   --color srgb|p3

Not notarized: on first launch, approve it in System Settings >
Privacy & Security > "Open Anyway".
EOF

# Volume icon.
cp macOSHost/Resources/AppIcon.icns "$ROOT/.VolumeIcon.icns"

DMG="dist/WiredDisplay-$VERSION.dmg"
rm -f "$DMG"
xattr -cr "$ROOT"
RW="$STAGE/rw.dmg"
hdiutil create -quiet -volname "WiredDisplay $VERSION" -srcfolder "$ROOT" -fs HFS+ -format UDRW -ov "$RW"
# Mark the volume as having a custom icon.
MOUNT="$STAGE/mnt"
diskutil image attach --nobrowse --mountPoint "$MOUNT" "$RW" >/dev/null
SetFile -a C "$MOUNT" 2>/dev/null || true
diskutil eject "$MOUNT" >/dev/null
hdiutil convert -quiet "$RW" -format UDZO -imagekey zlib-level=9 -o "$DMG"

IDENTITY="${SIGN_IDENTITY:-$(security find-identity -v -p codesigning | awk '/Apple Development/ {print $2; exit}')}"
[ -n "$IDENTITY" ] && codesign --force --timestamp=none --sign "$IDENTITY" "$DMG"
hdiutil verify -quiet "$DMG"
echo "built $DMG ($(du -h "$DMG" | cut -f1))"
