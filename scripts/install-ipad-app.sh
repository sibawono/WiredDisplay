#!/bin/bash
# Builds, signs (free Personal Team works; profile lasts 7 days) and installs
# the iPad client on the cabled iPad. Does not launch it.
#
# usage: scripts/install-ipad-app.sh [client|probe]
# env:   TEAM_ID (default: the team of the first "Apple Development"
#        certificate in the keychain), DEVICE (UDID; default: the first iPad
#        connected over USB), BUNDLE_PREFIX (must be unique to your team)
set -euo pipefail
cd "$(dirname "$0")/.."

APP="${1:-client}"
if [ -z "${TEAM_ID:-}" ]; then
  TEAM_ID="$(security find-certificate -c "Apple Development" -p 2>/dev/null \
    | openssl x509 -noout -subject 2>/dev/null | sed -n 's/.*OU *= *\([A-Z0-9]\{10\}\).*/\1/p')"
fi
[ -n "$TEAM_ID" ] || { echo "set TEAM_ID (no Apple Development certificate found)" >&2; exit 64; }
if [ -z "${DEVICE:-}" ]; then
  JSON="$(mktemp)"
  xcrun devicectl list devices --json-output "$JSON" >/dev/null 2>&1 || true
  DEVICE="$(plutil -convert json -o - "$JSON" 2>/dev/null | python3 -c '
import json, sys
for d in json.load(sys.stdin).get("result", {}).get("devices", []):
    hw = d.get("hardwareProperties", {})
    if hw.get("deviceType") == "iPad" and d.get("connectionProperties", {}).get("transportType") == "wired":
        print(hw.get("udid", "")); break' 2>/dev/null || true)"
  rm -f "$JSON"
fi
[ -n "$DEVICE" ] || { echo "set DEVICE=<UDID> (no iPad found on USB)" >&2; exit 64; }
BUNDLE_PREFIX="${BUNDLE_PREFIX:-dev.wireddisplay.u$(echo "$TEAM_ID" | tr 'A-Z' 'a-z')}"
DERIVED="${TMPDIR:-/tmp}/wd-dd-install"

case "$APP" in
  client) PROJECT=iPadOSClient/WiredDisplayClient/WiredDisplayClient.xcodeproj; SCHEME=WiredDisplayClient ;;
  probe)  PROJECT=iPadOSClient/TransportProbe/WDTransportProbe.xcodeproj;       SCHEME=WDTransportProbe ;;
  *) echo "usage: $0 [client|probe]" >&2; exit 64 ;;
esac

# BUNDLE_ID: use an already-registered App ID instead (free teams may create
# only 10 App IDs per 7 days). Installing under another app's ID replaces it.
EXTRA=()
[ -n "${BUNDLE_ID:-}" ] && EXTRA+=(PRODUCT_BUNDLE_IDENTIFIER="$BUNDLE_ID")

xcodebuild -project "$PROJECT" -scheme "$SCHEME" -configuration Debug -destination "id=$DEVICE" \
  -derivedDataPath "$DERIVED" -allowProvisioningUpdates \
  DEVELOPMENT_TEAM="$TEAM_ID" WD_BUNDLE_PREFIX="$BUNDLE_PREFIX" ${EXTRA[@]+"${EXTRA[@]}"} build 2>&1 \
  | grep -E "error:|BUILD (SUCCEEDED|FAILED)" | grep -v appintents
xcrun devicectl device install app --device "$DEVICE" "$DERIVED/Build/Products/Debug-iphoneos/$SCHEME.app" 2>&1 \
  | grep -E "bundleID|rror"
echo "installed $SCHEME as ${BUNDLE_ID:-$BUNDLE_PREFIX.$([ "$APP" = client ] && echo client || echo transportprobe)}"
