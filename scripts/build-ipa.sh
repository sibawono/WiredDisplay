#!/bin/bash
# Builds dist/WiredDisplay-<version>.ipa: the iPad client, Release, UNSIGNED,
# for sideloading with AltStore / SideStore (they re-sign it with the
# installer's own Apple ID, so no team or provisioning profile is needed here).
#
# usage: scripts/build-ipa.sh
set -euo pipefail
cd "$(dirname "$0")/.."

PROJECT=iPadOSClient/WiredDisplayClient/WiredDisplayClient.xcodeproj
SCHEME=WiredDisplayClient
VERSION="$(sed -n 's/.*MARKETING_VERSION = \(.*\);/\1/p' "$PROJECT/project.pbxproj" | head -1)"
# Build outside ~/Documents (iCloud Drive attributes break bundles, see build-host-app.sh).
STAGE="$(mktemp -d "${TMPDIR:-/tmp}/wd-ipa.XXXXXX")"
trap 'rm -rf "$STAGE"' EXIT

xcodebuild -project "$PROJECT" -scheme "$SCHEME" -configuration Release \
  -destination "generic/platform=iOS" -derivedDataPath "$STAGE/dd" \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" \
  WD_BUNDLE_PREFIX=dev.wireddisplay build 2>&1 \
  | grep -E "error:|BUILD (SUCCEEDED|FAILED)" | grep -v appintents

APP="$STAGE/dd/Build/Products/Release-iphoneos/$SCHEME.app"
mkdir -p "$STAGE/pkg/Payload" dist
ditto "$APP" "$STAGE/pkg/Payload/$SCHEME.app"
xattr -cr "$STAGE/pkg"
IPA="dist/WiredDisplay-$VERSION.ipa"
rm -f "$IPA"
(cd "$STAGE/pkg" && zip -qry -X "$OLDPWD/$IPA" Payload)
echo "built $IPA ($(du -h "$IPA" | cut -f1)), bundle ID $(plutil -extract CFBundleIdentifier raw "$APP/Info.plist")"
