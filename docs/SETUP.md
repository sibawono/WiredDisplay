# Setup and hardware-gate runbook (Phase 0)

All commands run from the project root. Nothing here changes the main display or weakens any system protection.

## Side-effect-free verification

```bash
scripts/verify.sh
```

## E-03 — virtual display (changes the live display set for ~8 s)

Before running: make sure you can reach the Mac another way (Screen Sharing or SSH from another device), because the iPad is currently its only screen.

```bash
"$(swift build --show-bin-path)/wd-vdisplay-probe" create --confirm --seconds 8
```

Pass: prints `RESULT: virtual display registered and removed; existing arrangement untouched`, and the `during` block shows a third display at 2732x2048 with `backingScale=2.0`. Exit 4 or 5 means the arrangement was disturbed; the display is already removed when the process exits.

## E-05 — bytes over the cable

1. Open `iPadOSClient/TransportProbe/WDTransportProbe.xcodeproj` in Xcode, select your Personal Team under Signing, change `WD_BUNDLE_PREFIX` to something unique to you if the identifier is taken, and run on the iPad. (Free team: the install expires after 7 days.)
2. Keep the app in the foreground. It should show `listening on 127.0.0.1:9000`. Note: this pushes Sidecar to the background.
3. On the Mac:

```bash
"$(swift build --show-bin-path)/wd-usbmux-probe" echo --megabytes 64
```

Pass: `RESULT: 64 MiB echoed and verified`, and the iPad shows the remote endpoint and interface for the connection plus a matching byte count. To prove the path is the cable: turn Wi-Fi off on both devices and repeat (must still pass), then unplug the cable mid-run (must fail immediately).

## E-07 — Accessibility

System Settings → Privacy & Security → Accessibility: enable the host binary once Phase 1 provides it. No injection code exists yet.
