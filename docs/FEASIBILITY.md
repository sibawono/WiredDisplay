# WiredDisplay — Phase 0 Feasibility Report

Date: 2026-11-16 · Status: **Phase 0 research complete; wired transport (E-05) verified on hardware; end-to-end pipeline built and unit-tested ahead of the gate by user decision (D-012); hardware gate NOT passed** — display, video and input run in one session, `TEST_SESSION.md`.

Evidence labels used throughout: **HW** = verified on the real Mac mini + iPad, **LOCAL** = verified on the Mac only, **BUILD** = compiles only, **RESEARCH** = read in SDK headers / third-party source, not run, **NOT RUN**.

## 1. Environment (observed, not assumed)

| Item | Value | How obtained |
|---|---|---|
| Host | Mac mini `Mac18,5`, Apple M6, 16 GB | `system_profiler SPHardwareDataType` |
| Host OS | macOS 27.2.1 (26B131), SIP enabled | `sw_vers`, `csrutil status` |
| Toolchain | Xcode 27.2 (27B52), Swift 6.4.2, SDKs macOS/iOS/DriverKit 27.2 | `xcodebuild -version -showsdks` |
| Client | iPad Air 13-inch (M2) `iPad14,10`, paired, transport **wired** | `xcrun devicectl list devices -v` |
| Cable link | usbmuxd reports `ConnectionType=USB`, `ConnectionSpeed=480000000` | `wd-usbmux-probe list` |
| Physical monitors | **None.** Online displays: Sidecar (main, AirPlay virtual) + BetterDisplay virtual `iPadHeadless` mirroring it, both 3180×2384 px @2x | `system_profiler SPDisplaysDataType`, `CGGetOnlineDisplayList` |
| Signing | 2 "Apple Development" identities; all 9 Xcode-managed profiles have a **7-day lifetime, `LocalProvision=true`** → free Personal Team | `security find-identity`, `security cms -D` on profiles |
| Repository | Empty directory at start; no prior code | `ls -la` |

Two consequences drive the rest of this report:

1. **The Mac is already being used headless through the iPad** (Sidecar + BetterDisplay). Any experiment that adds a display or foregrounds another iPad app can take away the user's only view of the Mac. Those experiments are therefore gated on explicit consent (§8).
2. **The signing team is a free Personal Team.** See §7 for what that blocks.

## 2. Virtual display (R-DIS-01, R-DIS-03)

**Finding: feasible only through private API; present on this OS; creation not yet exercised by our code.**

- Public CoreGraphics (`CGDisplayConfiguration.h`) can arrange, mirror and set modes of *existing* displays (`CGConfigureDisplayOrigin` l.52, `CGConfigureDisplayMirrorOfDisplay` l.138) but has no call that creates one. The public alternative is a DriverKit display driver, which needs an Apple-granted entitlement and a paid team. **RESEARCH**
- E-01 **LOCAL**: `grep -rl CGVirtualDisplay` over the macOS 27.2 SDK matches only `CoreGraphics.tbd` — no header. The four classes `CGVirtualDisplay`, `…Descriptor`, `…Settings`, `…Mode` resolve at runtime via `NSClassFromString`.
- E-02 **LOCAL**: `class_copyMethodList` dump of all four classes (selectors + type encodings). Notable ABI facts our shim depends on: `-[CGVirtualDisplayMode initWithWidth:height:refreshRate:]` is `@32@0:8I16I20d24` (32-bit unsigned width/height, not `NSUInteger`); `-[CGVirtualDisplay applySettings:]` returns `BOOL`; `CGVirtualDisplaySettings` has `hiDPI`, `modes`, `rotation`, `refreshDeadline`, `isReference`; a `transferFunction` mode initialiser exists (possible HDR path, unexplored).
- Implementation: `macOSHost/Display/CVirtualDisplay` resolves every class/selector at runtime and compares type encodings against the E-02 table before any call; any mismatch returns an `NSError` and creates nothing. It links no private symbol, so a future OS that removes the classes cannot crash the app at launch. The independent review found that the first version leaked every private object, so releasing a display could never have removed it (BUG-004). That is fixed, and a test that creates no display now checks ownership. **BUILD + LOCAL** (`wd-vdisplay-probe check` and `ShimTests` pass; see `docs/evidence/phase0-probes.txt`).
- E-03 **NOT RUN**: `wd-vdisplay-probe create --confirm` (register a 2732×2048 HiDPI display for 8 s, verify existing displays are untouched, remove it). Not run because it alters the live WindowServer session that is the user's only screen.
- Precedent **RESEARCH**: [OpenDisplay](https://github.com/peetzweg/opendisplay) (GPL-3.0 — used as a reference for behaviour only; no code copied) creates the display the same way, sets `hiDPI=1` with a points-sized mode, and runs a 2 s loop that re-selects the HiDPI mode and detaches mirror sets, which indicates WindowServer does not reliably keep the requested state. Chromium's `ui/display/mac/test/virtual_display_util_mac.mm` notes a non-zero vendor ID is required from macOS 14. BetterDisplay, running on this machine right now, is live proof the mechanism works on macOS 27.2 for *some* caller.
- Distribution: private API ⇒ no Mac App Store; Developer ID + notarization is possible in principle (OpenDisplay ships that way) but needs a paid membership. Any macOS update may break it; the shim is the single place to adapt.
- Main-display assignment (R-DIS-03) uses public `CGConfigureDisplayOrigin` (origin 0,0 = main). **NOT RUN** and deliberately deferred to Phase 2 behind a rollback path.

## 3. Direct USB transport (R-USB-01, R-USB-02)

**Finding: works. Bidirectional bytes between the Mac and a sandboxed, free-team-signed iPad app over the USB-C cable, verified on hardware (E-05).** Two parts of the "is it really the cable" proof still need you: repeating with Wi-Fi off, and unplugging mid-run.

- iPadOS exposes no raw USB API to third-party apps (`ExternalAccessory` is MFi-only). The USB "Ethernet Adapter" interfaces on this Mac (`en4`–`en6`) are `status: inactive`, so there is no general IP link over the cable to rely on. **LOCAL**
- usbmuxd, the daemon Xcode and Finder use, multiplexes TCP connections over the USB cable to a port on the device's loopback. A sandboxed iPad app only has to listen on `127.0.0.1`; the Mac asks `/var/run/usbmuxd` to connect. The socket is `srw-rw-rw-`, so no privilege is needed on the Mac (an App Sandbox Mac app would be denied; the host is not sandboxed anyway). This is not a documented API, but it is the mechanism OpenDisplay, Duet-style tools and peertalk rely on. **RESEARCH + LOCAL**
- E-04 **HW (Mac → device)**: `ListDevices` returns the iPad with `ConnectionType=USB`; `Connect` to port 9000 returns result **3 (connection refused)**, i.e. the request crossed the cable and the iPad's TCP stack answered that nothing listens. This proves reachability, not data transfer.
- E-05 **HW (bidirectional bytes)**, 2026-11-16 07:50 UTC: `TransportProbe` signed with the free Personal Team, installed with `devicectl`, foregrounded; `wd-usbmux-probe echo` sends framed random payloads and checks every echoed byte. All 5 runs passed with 0 mismatches (`evidence/e05-usb-echo.txt`):

  | Frame size | Data | Rate (one-way lower bound) | Round trip p50 / p95 / max |
  |---|---|---|---|
  | 4 KiB | 4 MiB | 29 Mbit/s | 0.54 / 0.80 / 1.81 ms |
  | 64 KiB | 32 MiB | 95 Mbit/s | 1.75 / 2.14 / 2.87 ms |
  | 256 KiB | 256 MiB | 102 Mbit/s | 5.29 / 6.56 / 11.04 ms |
  | 4 MiB | 256 MiB | 119 Mbit/s | 44.6 / 46.5 / 47.3 ms |

  The rate counts each payload byte once, although it crossed the cable twice with only one frame in flight, so it understates one-way capacity. **What this means:** ≥119 Mbit/s one way is several times a typical 60 fps HEVC desktop stream at iPad resolution (an estimate, not yet measured), and the sub-millisecond 4 KiB round trip is a good sign for input latency.
- On the iPad, during the transfer, the probe shows remote endpoint `127.0.0.1:<port>` and path interface `lo0 (loopback)` (`evidence/e05-ipad-midrun.png`): the connection arrives via usbmuxd's device-side relay, not as a network peer.
- Found on hardware: **BUG-011**. Binding "to the loopback interface" (`requiredInterfaceType = .loopback`, introduced as a review fix) reports ready but receives nothing from usbmuxd: 0 accepted, 0 rejected, Mac sees "refused". An explicit `127.0.0.1` bind works. usbmuxd delivers to IPv4 loopback on iPadOS here.
- Observed platform behaviour: when you switched the iPad back to Sidecar, the probe went to the background, stopped its listener, and the in-flight transfer ended with `closedByPeer` on the Mac. **The iPad app must stay in the foreground** (R-06).
- Not yet verified: that the iPad notices a Mac-side disconnect (the final screenshot was taken within the UI's refresh interval); repeating with Wi-Fi off; unplugging mid-run (E-05b, deferred). Until then, "wired only" rests on: usbmuxd reports `ConnectionType=USB`; the peer arrives on `lo0` from `127.0.0.1`; the Mac code refuses `Network`-type devices (unit-tested).
- Wired Only is structural rather than a setting: the iPad listener accepts on the loopback interface only (unreachable from Wi-Fi, no Local Network prompt), and the Mac refuses any usbmuxd device whose `ConnectionType` is not `USB`. Loopback does not exclude *other apps on the iPad*; only authentication does (D-006, BUG-010) (usbmuxd also lists Wi-Fi-synced devices — the iPhone shows up as `Network` here). Unit-tested.
- Open risks: usbmuxd reports a 480 Mbit/s (USB 2) link for this cable/port; measured payload rates are consistent with that ceiling. A USB 3 data cable may raise it (untested). The listener only works while the app is in the foreground (iPadOS suspends it otherwise). Trust pairing ("Trust This Computer") is required and already present.

## 4. Capture, encode, render (R-DIS-02, R-VID-01/02)

- ScreenCaptureKit is in the SDK (`SCStream.h`, macOS 12.3+) and captures any display ID, including virtual ones; it does not create displays. **RESEARCH**
- E-06 **LOCAL**: `VTCompressionSessionCreate` with `RequireHardwareAcceleratedVideoEncoder` succeeds at 2732×2048 for both H.264 and HEVC, and both report `UsingHardwareAcceleratedVideoEncoder = 1`.
- `CGPreflightScreenCaptureAccess()` returned `true` for the probe, but that is the TCC grant of the terminal host that launched it, **not** of a WiredDisplay app. Our own app will need its own Screen Recording grant. An Apple forum thread reports ScreenCaptureKit confusing virtual displays in some configurations; untested here.
- Capture → encode → transport → decode → Metal is **NOT IMPLEMENTED** (hard gate).

## 5. Input round trip (R-INP-01)

- Public path: `CGEventCreateMouseEvent` (`CGEvent.h` l.57) posted at `kCGHIDEventTap`, in global display coordinates; requires Accessibility consent. **RESEARCH**
- E-07 **LOCAL**: `AXIsProcessTrusted()` is `false` for the probe host, so no injection can be tested until the user grants Accessibility to the host binary.
- `Shared/Geometry/CoordinateMapper` (view point ↔ global display point, letterbox-aware, non-zero display origins, touches in the bars rejected) is implemented and unit-tested. **BUILD + unit tests**. No event has been injected. **NOT RUN**
- macOS has no public API for injecting native multitouch; gestures will be translated to pointer/scroll/keyboard events.

## 6. Headless (R-DIS-04)

- Observed **HW**: this Mac is running a logged-in session with zero physical monitors, with a virtual main display. So "no HDMI dummy in a logged-in session" is achievable on this hardware/OS — demonstrated by Sidecar/BetterDisplay, **not yet by our code**.
- Not tested, and expected to be out of reach for a user-session app: login window after logout/restart (our host starts only after login), FileVault preboot (no third-party code runs), Recovery. These need a physical display or another recovery path (Screen Sharing/SSH after login, Apple's own Sidecar is also unavailable pre-login). Lock/unlock within a session is expected to work but is **NOT RUN**.

## 7. Audio, camera, signing

| Feature | Mechanism | Evidence | Free Personal Team? |
|---|---|---|---|
| Virtual speaker / mic (R-AUD-01/02) | AudioServerPlugIn (`CoreAudio/AudioServerPlugIn.h`) installed in `/Library/Audio/Plug-Ins/HAL` | Three third-party HAL plug-ins are installed and loaded on this Mac, so the mechanism works on macOS 27.2. **RESEARCH** | Likely yes: needs admin install and a valid signature but no restricted entitlement. **Unverified.** |
| Virtual camera (R-CAM-01) | CoreMediaIO Camera Extension (`CMIOExtensionProvider.h`, macOS 12.3+), a system extension | Header present. **RESEARCH** | **No.** Needs `com.apple.developer.system-extension.install`, a restricted entitlement that must be authorised by a provisioning profile; none of the 9 local profiles carries it. **BLOCKED** without a paid membership. |
| iPad app | Standard app | TransportProbe signed with the free Personal Team, installed and run (E-05). **HW** | Yes, but the profile expires after **7 days** (observed lifetime), then the app must be rebuilt and reinstalled from Xcode; limited number of App IDs per week. |
| Mac host | Non-sandboxed app, private API | — | Runs locally with development or ad-hoc signing. Notarized distribution needs a paid membership. |

Sources: [Apple — Choosing a Membership](https://developer.apple.com/support/compare-memberships), [Apple forum — Camera Extension signing](https://developer.apple.com/forums/thread/710046).

## 8. GO / NO-GO

**Research verdict: GO, conditionally.** Nothing found makes the core path (virtual display → capture → USB → iPad → touch) impossible, and each link has a working precedent on this exact OS.

**Hard gate verdict: NOT PASSED.** Verified on hardware: wired transport (E-05). Not verified: display creation by our code, video on the iPad, and a click. The remaining experiments each need a decision from the user:

| # | Experiment | Why it needs consent |
|---|---|---|
| E-03 | Create and remove a virtual display for 8 s | Changes the live display set of a Mac whose only screen is the iPad. The probe removes the display and exits non-zero if any existing display changes, but WindowServer may still rearrange windows briefly. |
| E-05b | Repeat E-05 with Wi-Fi and Bluetooth off on the iPad (the Mac must keep Wi-Fi: it is its only internet link); unplug the cable mid-run | **Deferred by the user, 2026-11-16.** The only view of the Mac is Sidecar on the same iPad, so the instructions cannot be read while the probe is in front, and either step may drop Sidecar. Repeat once a second way into the Mac exists. E-05 itself is **done**. |
| E-07 | Grant Accessibility to the host probe | A TCC permission only the user can grant in System Settings. |

**Known NO-GO items regardless of the gate:** pre-login / FileVault display; virtual camera on a free team; App Store distribution of the Mac host.
