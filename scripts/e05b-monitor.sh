#!/bin/bash
# E-05b monitor (Mac side). Every ~2 s: list usbmuxd devices, run a 4 MiB echo
# (Wired Only), and record whether Sidecar is connected. All lines timestamped.
#
# End of test: ONLY the explicit marker the iPad app writes when the user taps
# "Selesai" (Documents/e05b-finished, fetched over the cable). Refused echoes
# alone never end the test: they also happen whenever Sidecar takes over the
# iPad screen (review finding 1).
#
# Negative control: while the iPad is NOT attached over USB but usbmuxd lists it
# as a Network-type device, run one echo that deliberately bypasses Wired Only
# (once per unplug episode). Success shows the Wi-Fi path exists and that the
# Wired Only filter is what keeps normal traffic on the cable (finding 9).
#
# Recovery: on ANY exit (normal end, timeout, Ctrl-C, kill, hang-up) make sure
# Sidecar is connected, retrying for up to 90 s. Sidecar is the user's only
# screen for this Mac (finding 2). Uses Sidecar Travel's own helper script.
#
# usage: UDID=<iPad UDID> BUNDLE=<probe bundle ID> IPAD="<iPad name>" \
#          e05b-monitor.sh <seconds> <bin dir> <log path (must not exist)>
set -u
SECONDS_MAX="${1:-900}"; BIN="$2"; LOG="$3"
: "${UDID:?set UDID to the iPad's UDID}" "${BUNDLE:?set BUNDLE to the TransportProbe bundle ID}" "${IPAD:?set IPAD to the iPad name Sidecar shows}"
SERIAL_PREFIX="${UDID%%-*}"         # usbmuxd serials start with the UDID's first group
CTL="/Applications/Sidecar Travel.app/Contents/Resources/ctl.js"

if [ -e "$LOG" ]; then echo "refusing to overwrite existing log $LOG" >&2; exit 64; fi
TMP=$(mktemp -d) || exit 1

say() { echo "$(date +%H:%M:%S) $*" >> "$LOG"; }
sidecar_connected() {
  osascript -l JavaScript "$CTL" list 2>/dev/null | grep -q "connected=\[.*\"$IPAD\""
}
restore_sidecar() {
  local deadline=$(( $(date +%s) + 90 ))
  while ! sidecar_connected; do
    if [ "$(date +%s)" -ge "$deadline" ]; then say "WARNING sidecar still not connected after 90 s"; return 1; fi
    say "RECOVERY sidecar not connected -> $(osascript -l JavaScript "$CTL" connect "$IPAD" 2>&1)"
    sleep 8
  done
  say "sidecar connected"
}
on_exit() {
  trap - EXIT INT TERM HUP
  restore_sidecar
  say "# E-05b monitor end"
  rm -rf "$TMP"
}
trap on_exit EXIT
trap 'say "monitor interrupted"; exit 130' INT TERM HUP

marker_present() {
  rm -f "$TMP/marker"
  xcrun devicectl device copy from --device "$UDID" --domain-type appDataContainer \
    --domain-identifier "$BUNDLE" --source Documents/e05b-finished --destination "$TMP/marker" \
    >/dev/null 2>&1 && [ -s "$TMP/marker" ]
}

echo "# E-05b monitor start $(date -u +%Y-%m-%dT%H:%M:%SZ) (local times below)" > "$LOG"
END=$(( $(date +%s) + SECONDS_MAX ))
refused_streak=0
control_done=0
while [ "$(date +%s)" -lt "$END" ]; do
  devices=$("$BIN/wd-usbmux-probe" list 2>&1 | grep -E "id=" | tr -s ' ' | paste -sd ';' -)
  result=$("$BIN/wd-usbmux-probe" echo --megabytes 4 --chunk-kb 64 2>&1)
  code=$?
  summary=$(echo "$result" | grep -E "^RESULT|^error" | head -1 | cut -c1-90)
  rtt=$(echo "$result" | grep -E "round trip" | sed -E 's/.*p50 ([0-9.]+).*/p50=\1ms/')
  if sidecar_connected; then sc=on; else sc=OFF; fi
  say "exit=$code sidecar=$sc ${summary:-?} $rtt | usbmuxd: ${devices:-none}"

  usb_ipad=0; net_ipad=0
  echo "$devices" | grep -q "serial=$SERIAL_PREFIX[^;]*type=usb" && usb_ipad=1
  echo "$devices" | grep -q "serial=$SERIAL_PREFIX[^;]*type=network" && net_ipad=1

  if [ "$usb_ipad" -eq 1 ]; then control_done=0; fi
  if [ "$usb_ipad" -eq 0 ] && [ "$net_ipad" -eq 1 ] && [ "$control_done" -eq 0 ]; then
    control=$("$BIN/wd-usbmux-probe" echo --megabytes 1 --chunk-kb 64 --negative-control-network "$SERIAL_PREFIX" 2>&1)
    ccode=$?
    say "NEGATIVE-CONTROL exit=$ccode $(echo "$control" | grep -E "^RESULT|^error" | head -1 | cut -c1-110) $(echo "$control" | grep -E "round trip" | sed -E 's/.*p50 ([0-9.]+).*/p50=\1ms/')"
    control_done=1
  fi

  if [ "$code" -eq 3 ]; then refused_streak=$((refused_streak + 1)); else refused_streak=0; fi
  if [ "$refused_streak" -ge 3 ] && [ "$usb_ipad" -eq 1 ]; then
    if marker_present; then
      say "END explicit: iPad marker found ($(head -1 "$TMP/marker"))"
      break
    fi
  fi
  sleep 1.5
done
[ "$(date +%s)" -ge "$END" ] && say "timeout after ${SECONDS_MAX}s"
exit 0
