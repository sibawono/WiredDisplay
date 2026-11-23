#!/bin/bash
# Reproducible Pass A checks. Side-effect free: never creates a display,
# never installs or launches anything on the iPad.
set -euo pipefail
cd "$(dirname "$0")/.."
DD="${TMPDIR:-/tmp}/wd-verify-dd"

echo "== macOS: build (Swift 6, strict concurrency) and unit tests"
swift build 2>&1 | tail -3
swift test 2>&1 | grep -E "error|failed|Executed [1-9][0-9]* tests" | sort -u

echo "== protocol vectors (Tests/Vectors) match their generator"
if python3 -I -c "import cryptography" 2>/dev/null; then
  python3 -I scripts/gen-protocol-vectors.py --check
else
  echo "skipped: python3 'cryptography' package not installed (pip3 install cryptography)"
fi

echo "== iOS device SDK: shared libraries"
for scheme in WDProtocol WDUsbmux WDGeometry; do
  xcodebuild -scheme "$scheme" -destination 'generic/platform=iOS' -derivedDataPath "$DD-pkg" \
    CODE_SIGNING_ALLOWED=NO build 2>&1 | grep -E "error|warning:|BUILD" | tail -3
done

echo "== iOS device SDK: TransportProbe app (unsigned compile)"
xcodebuild -project iPadOSClient/TransportProbe/WDTransportProbe.xcodeproj -scheme WDTransportProbe \
  -destination 'generic/platform=iOS' -derivedDataPath "$DD-app" CODE_SIGNING_ALLOWED=NO build 2>&1 \
  | grep -E "error|BUILD" | tail -3

BIN="$(swift build --show-bin-path)"
echo "== probes (read-only)"
"$BIN/wd-vdisplay-probe" check
"$BIN/wd-usbmux-probe" list
