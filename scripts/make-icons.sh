#!/bin/bash
# Regenerates the app icons from scripts/make-icons.swift (shares the menu bar
# glyph with the host) and installs them:
#   iPadOSClient/WiredDisplayClient/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png
#   macOSHost/Resources/AppIcon.icns
set -euo pipefail
cd "$(dirname "$0")/.."
WORK="$(mktemp -d "${TMPDIR:-/tmp}/wd-icons.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
cp scripts/make-icons.swift "$WORK/main.swift"
swiftc -O -o "$WORK/make-icons" "$WORK/main.swift" macOSHost/Host/MenuBarIcon.swift
"$WORK/make-icons" "$WORK/out"
SET=iPadOSClient/WiredDisplayClient/Assets.xcassets/AppIcon.appiconset
mkdir -p "$SET" macOSHost/Resources
cp "$WORK/out/AppIcon-iPad-1024.png" "$SET/AppIcon-1024.png"
# The same artwork as an image for the iPad app's splash/status screen.
ART=iPadOSClient/WiredDisplayClient/Assets.xcassets/AppIconArt.imageset
mkdir -p "$ART"
cp "$WORK/out/AppIcon-iPad-1024.png" "$ART/AppIconArt.png"
cat > "$ART/Contents.json" <<'JSON'
{
  "images" : [ { "filename" : "AppIconArt.png", "idiom" : "universal" } ],
  "info" : { "author" : "xcode", "version" : 1 }
}
JSON
iconutil -c icns "$WORK/out/AppIcon.iconset" -o macOSHost/Resources/AppIcon.icns
mkdir -p "${PREVIEW_DIR:-$WORK/out}"
cp "$WORK/out/MenuBar-preview.png" "$WORK/out/AppIcon.iconset/icon_512x512@2x.png" "${PREVIEW_DIR:-$WORK/out}/" 2>/dev/null || true
echo "icons installed (previews in ${PREVIEW_DIR:-$WORK/out})"
