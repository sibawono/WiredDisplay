#!/bin/bash
# Builds dist/WiredDisplay-<version>.dmg: the host app, an Applications
# shortcut, "Install Extras" / "Uninstall Extras" (audio driver and iPad
# Touch ID / Face ID unlock, prebuilt in .extras), and a README.
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
mkdir -p "$ROOT/.extras" dist

# Host app, built and signed by the regular script into the staging folder.
INSTALL_DIR="$ROOT" ./scripts/build-host-app.sh >/dev/null
ln -s /Applications "$ROOT/Applications"

# Extras, all prebuilt so the user's Mac needs no developer tools, in a hidden
# .extras folder behind one installer and one uninstaller:
# - the audio driver (HAL plug-in), built and signed by its own script;
# - the iPad Touch ID / Face ID modules and their install/uninstall scripts.
OUT="$STAGE/driver" ./scripts/build-audio-driver.sh >/dev/null
ditto "$STAGE/driver/WiredDisplayAudio.driver" "$ROOT/.extras/WiredDisplayAudio.driver"
OUT="$ROOT/.extras" ./scripts/build-pam-modules.sh >/dev/null 2>&1
cp scripts/install-pam.sh scripts/uninstall-pam.sh "$ROOT/.extras/"

cat > "$ROOT/Install Extras.command" <<'EOF'
#!/bin/bash
# WiredDisplay extras: the audio devices and iPad Touch ID / Face ID unlock.
# Asks which ones to install, then for your Mac password once.
set -e
X="$(cd "$(dirname "$0")" && pwd)/.extras"
ask() { local a; read -r -p "$1 " a; a="${a:-$2}"; [[ "$a" =~ ^[YyJj] ]]; }
echo "WiredDisplay extras"
echo
echo "1. Audio: adds \"iPad Speaker\" and \"iPad Microphone\" to Sound settings."
AUDIO=0; ask "   Install the audio devices? [Y/n]" y && AUDIO=1
echo
echo "2. Touch ID / Face ID: the iPad answers sudo, the Lock Screen and admin"
echo "   dialogs. Your Mac password keeps working."
TOUCH=0; ask "   Install Touch ID / Face ID unlock? [y/N]" n && TOUCH=1
KEY="$HOME/Library/Caches/dev.wireddisplay.host/last_biometric_key.b64"
if [[ $TOUCH -eq 1 && ! -f "$KEY" ]]; then
    echo
    echo "   First link the iPad: connect it over USB-C with WiredDisplay running,"
    echo "   then on the iPad open Controls > More > Enroll Touch ID / Face ID Key."
    echo "   Run this installer again afterwards. Skipping Touch ID / Face ID for now."
    TOUCH=0
fi
if [[ $AUDIO -eq 0 && $TOUCH -eq 0 ]]; then echo; echo "Nothing to install."; exit 0; fi
echo
echo "macOS asks for your Mac password once."
sudo -v
if [[ $AUDIO -eq 1 ]]; then
    sudo ditto "$X/WiredDisplayAudio.driver" /Library/Audio/Plug-Ins/HAL/WiredDisplayAudio.driver
    sudo killall coreaudiod || true
    echo "Audio installed: \"iPad Speaker\" and \"iPad Microphone\" are in Sound settings."
fi
if [[ $TOUCH -eq 1 ]]; then
    sudo bash "$X/install-pam.sh" --prebuilt "$X"
fi
echo
echo "Done. You can close this window."
EOF
cat > "$ROOT/Uninstall Extras.command" <<'EOF'
#!/bin/bash
# Removes the WiredDisplay extras that are installed: the audio devices and
# iPad Touch ID / Face ID unlock (restoring the original macOS rules).
set -e
X="$(cd "$(dirname "$0")" && pwd)/.extras"
AUDIO=0; [[ -d /Library/Audio/Plug-Ins/HAL/WiredDisplayAudio.driver ]] && AUDIO=1
TOUCH=0
[[ -e /usr/local/lib/pam/pam_wireddisplay.so || -d /Library/Security/SecurityAgentPlugins/WiredDisplayAuth.bundle ]] && TOUCH=1
if [[ $AUDIO -eq 0 && $TOUCH -eq 0 ]]; then echo "No WiredDisplay extras are installed."; exit 0; fi
echo "This removes:"
[[ $AUDIO -eq 1 ]] && echo "  - the audio devices (iPad Speaker, iPad Microphone)"
[[ $TOUCH -eq 1 ]] && echo "  - Touch ID / Face ID unlock (sudo, Lock Screen, admin dialogs)"
read -r -p "Continue? [y/N] " a
[[ "$a" =~ ^[YyJj] ]] || { echo "Nothing removed."; exit 0; }
sudo -v
if [[ $AUDIO -eq 1 ]]; then
    sudo rm -rf /Library/Audio/Plug-Ins/HAL/WiredDisplayAudio.driver
    sudo killall coreaudiod || true
    echo "Audio devices removed."
fi
if [[ $TOUCH -eq 1 ]]; then
    sudo bash "$X/uninstall-pam.sh"
fi
echo
echo "Done. The WiredDisplay app itself stays; drag it to the Bin to remove it."
EOF
chmod +x "$ROOT/Install Extras.command" "$ROOT/Uninstall Extras.command"

cat > "$ROOT/README.txt" <<EOF
WiredDisplay $VERSION - use an iPad or Android device as a display for this Mac

1. Drag WiredDisplayHost to Applications (or ~/Applications) and open it.
   It lives in the menu bar (screen + USB icon); there is no Dock icon.
   It adds itself to Login Items (menu: "Open at Login" to turn off).
2. Grant Screen Recording (required), and Accessibility if you want touch,
   stylus, or keyboard input from your iPad or Android device.
3. Connect over USB-C or encrypted local Wi-Fi:
   - iPad: plug in USB-C or select Auto / Wi-Fi in General > Connection.
   - Android (USB-C AOA, no USB Debugging): plug in USB-C, open General >
     Android USB-C Devices in the Mac menu bar, and click "Connect".
   - Android (Wi-Fi): select Auto or Wi-Fi in General > Connection on the
     same local Wi-Fi network, then confirm the 6-digit pairing code.
4. Optional: open "Install Extras.command". It asks whether to add the
   audio devices ("iPad Speaker" / "iPad Microphone") and iPad Touch ID /
   Face ID unlock, then asks for your password once. For Touch ID / Face ID,
   first tap Controls > More > Enroll on the iPad. "Uninstall Extras.command"
   removes both.

Not notarized: on first launch, approve it in System Settings >
Privacy & Security > "Open Anyway".
EOF

cat > "$ROOT/PANDUAN-INSTALASI.txt" <<EOF
Panduan Instalasi WiredDisplay $VERSION (Mac + Android / iPad)
==============================================================

1. Instalasi di Mac (WiredDisplay-$VERSION.dmg)
----------------------------------------------
1. Tarik WiredDisplayHost.app ke folder Applications (atau ~/Applications).
2. (Opsional) Jalankan "Install Extras.command". Ia bertanya apakah mau memasang
   perangkat audio (iPad Speaker / iPad Microphone) dan buka Mac dengan Touch ID /
   Face ID di iPad, lalu meminta password Mac sekali. Untuk Touch ID / Face ID,
   ketuk dulu Controls > More > Enroll di iPad. "Uninstall Extras.command"
   melepas keduanya.
3. Buka WiredDisplayHost.app.
   Jika macOS menolak karena ad-hoc signed, klik Done lalu buka:
   System Settings > Privacy & Security > klik "Open Anyway".
4. Aktifkan izin macOS yang diminta:
   - Screen Recording (wajib agar layar Mac terkirim).
   - Accessibility (wajib untuk input sentuh, stylus, dan keyboard).
   Setelah memberi izin, tutup lalu buka ulang WiredDisplayHost.

2. Instalasi di Android (WiredDisplay-$VERSION-android.apk)
----------------------------------------------------------
1. Kirim file WiredDisplay-$VERSION-android.apk ke tablet/HP Android (Android 8.0+).
2. Tap file APK di File Manager. Izinkan "Install unknown apps" bila diminta.
3. Buka WiredDisplay di Android lalu tap "Start Connecting".

3. Cara Menghubungkan
---------------------
A. Lewat Kabel USB-C (Plug-and-Play AOA, tanpa USB Debugging):
   1. Colokkan kabel USB-C data antara Mac dan Android.
   2. Di menu bar Mac, buka WiredDisplay > General, pilih USB-C atau Auto.
   3. Pada kartu "Android USB-C Devices", klik "Connect" di samping perangkat Anda.
   4. Setujui dialog izin USB Accessory di Android (tap OK).
   5. Pada koneksi pertama, cocokkan kode pairing 6 digit lalu tap Pair.

B. Lewat Wi-Fi Lokal Terenkripsi:
   1. Pastikan Mac dan Android berada di jaringan Wi-Fi yang sama.
   2. Di menu bar Mac, buka WiredDisplay > General, pilih Auto atau Wi-Fi.
   3. Pastikan aplikasi WiredDisplay di Android sedang terbuka di layar depan.
   4. Cocokkan kode pairing 6 digit di kedua layar lalu tap Pair.

4. Tips
-------
- Ketuk tombol bulat Controls di Android untuk mengatur Display Space,
  Quality, Brightness, Volume Mac, Speaker/Mic, Quick Actions, dan Soft Keyboard.
- Secara default input dimatikan demi keamanan; aktifkan "Allow Input from iPad"
  di tab Input pada menu bar Mac untuk menggunakan sentuhan/stylus/keyboard.
- Jika Wi-Fi tidak tersambung, matikan VPN / AP Isolation atau gunakan kabel USB-C.
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
