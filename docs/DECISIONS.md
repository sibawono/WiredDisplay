# Decisions

Each entry: context → decision → consequence. Status is *accepted* unless noted. Reversing one needs a new entry, not an edit.

## D-001 Private `CGVirtualDisplay` behind a runtime-resolved, fail-closed shim
Public CoreGraphics cannot create a display; the public route (DriverKit) needs an Apple-granted entitlement and a paid team. **Decision:** use `CGVirtualDisplay`, confined to `macOSHost/Display/CVirtualDisplay`. No private symbol is linked: classes come from `objc_getClass`, each selector's type encoding is compared with the table recorded on macOS 27.2 before any call, and any mismatch returns an error. **Consequence:** no App Store; an OS update can disable display creation but cannot crash the app at launch; one file to update when the ABI changes.

## D-002 USB transport = usbmuxd on the Mac, loopback-only TCP listener on the iPad
iPadOS offers apps no raw USB; the USB network interfaces are inactive. **Decision:** the iPad app listens on `127.0.0.1`; the Mac connects through `/var/run/usbmuxd`. **Consequence:** depends on an undocumented but long-stable daemon protocol; the iPad app must be foregrounded; the Mac host cannot be App-Sandboxed. To be confirmed by E-05 before anything is built on it.

## D-003 Wired Only is enforced by construction
**Decision:** the iPad listener binds loopback only, and the Mac rejects every usbmuxd device whose `ConnectionType` is not `USB` (`UsbmuxConnection.connect` throws `.notWired`). There is no code path that falls back to Wi-Fi. **Consequence:** an optional Wi-Fi mode later must be a separate, explicitly enabled listener, never a fallback inside this one.

## D-004 The Mac dials, the iPad listens
**Decision:** the Mac never opens a listening port for this product. **Consequence:** input events travel iPad → Mac over a connection the Mac itself initiated to a USB-attached, trust-paired device; nothing on the LAN can reach the injector. Residual risk: another app on the iPad could occupy the port first (see RISKS R-07), which is why D-006 still stands.

## D-005 Wire format: fixed 36-byte big-endian header, per-stream payload caps
See `Shared/Protocol/FrameHeader.swift`. **Decision:** magic, version, stream type, flags, session ID, per-stream sequence, monotonic timestamp, payload length; the length is validated against a per-stream cap before any payload is buffered; a malformed header poisons the parser and the connection must be closed. **Consequence:** bounded memory for hostile input; no resynchronisation logic to get wrong.

## D-006 No unauthenticated production path; the auth flag is reserved and refused
Phase 0 has no cryptography. **Decision:** the `authenticated` flag exists in the format but both encoder and decoder reject it, so a Phase 0 build can never interoperate with, or be mistaken for, an authenticated build. `SequenceValidator` is documented as ordering hygiene, not replay protection. Input injection in Phase 1 is permitted only in a supervised PoC session; mutual authentication (Keychain-held keys, AEAD with the header as associated data) must land before any auto-connect or launch-at-login feature. **Consequence:** Phase 5's pairing work is a prerequisite for unattended use, not a polish item.

## D-007 Experiments that touch the user's live session require explicit consent
The Mac's only screen is the iPad via Sidecar. **Decision:** creating a display, foregrounding another iPad app, or changing display arrangement is never done automatically; `wd-vdisplay-probe create` refuses without `--confirm` and self-reverts if any pre-existing display changes. **Consequence:** Phase 0 ends with three experiments pending rather than assumed.

## D-008 One SwiftPM package for shared logic and probes; app targets come later
**Decision:** `Package.swift` at the root maps `Shared/*`, the shim and the probes; the iPad probe is a minimal hand-written Xcode project with no dependencies. The full workspace layout from the specification (host app, client app, extensions) is created when Phase 1 starts. **Consequence:** less scaffolding to review now; the probe app does not yet exercise the shared package on-device (the three libraries are compiled for the iOS device SDK separately).

## D-009 OpenDisplay is a behavioural reference only
It is GPL-3.0. **Decision:** no source is copied or translated; only publicly described behaviour and protocol facts were used, and our wire format is independent. **Consequence:** licence stays the user's choice.

## D-010 Single-owner, deadline-bounded POSIX I/O in the Phase 0 usbmux client
**Decision:** `UsbmuxConnection` is a single-owner, non-`Sendable` class. The socket is non-blocking and every operation (request, read, write, duplex `exchange`) runs one `poll` loop against one deadline. An explicit `.mux` → `.tunnel` → `.dead` lifecycle means any error closes the socket. *(Revised 2026-11-16 after BUG-006/007; originally per-syscall blocking timeouts.)* **Consequence:** good enough for probes; Phase 1 wraps or replaces it with an actor-isolated transport with separate send and receive paths and prioritised queues.

## D-011 Private-API calls go through ARC-visible protocol declarations
After BUG-004. **Decision:** never call `alloc`/`init` or any object-returning private selector through a casted `objc_msgSend`. Declare the selectors in a local `@protocol` and use message syntax on a class obtained from `objc_getClass`. **Consequence:** ARC balances ownership, and the ownership test can detect a regression without creating a display.

## D-012 Build ahead of the hardware gate; one consolidated hardware test session (user decision, 2026-11-16)
The specification's hard gate says full development waits until wired transport, a real display source, iPad rendering and one touch are proven on hardware, unless the user decides otherwise. Status at the time: wired transport proven (E-05); E-05b partly proven (unplug stops traffic; Mac refuses Network-type devices) and its rerun was stopped by the user; E-03, video and input not run. **Decision (user, explicit):** "continue development until done, then test when everything is ready, to save tokens." **Consequence:** the end-to-end pipeline is built and unit-tested now, and every hardware experiment (E-03, E-05b, E-07, end-to-end video and touch) runs in one session from `docs/TEST_SESSION.md`. Hardware-only defects will surface later and possibly several at once. Nothing in this build changes the main display, auto-starts, or injects input unless the user enables it on that run (D-006 still holds).

## D-013 iPad presents video with AVSampleBufferDisplayLayer for the PoC
**Decision:** the client hands decoded-on-demand H.264/HEVC sample buffers to `AVSampleBufferDisplayLayer` (hardware decode and presentation by the system, zero-copy) instead of a hand-written VideoToolbox decoder + Metal renderer. **Consequence:** far less code on the critical path; less control over colour conversion, scaling filter and pacing. Revisit with Metal (R-VID-02) if measurements show a need.

## D-014 Product transport uses port 9100; the echo probe keeps 9000
**Decision:** separate ports so the probe and the client can never be confused. The Mac dials, the iPad listens on 127.0.0.1 (D-004), and the Mac only accepts USB-type usbmuxd devices (D-003).

## D-015 Extend, never take over, the main display
**Decision:** the host creates its virtual display as an additional display and never calls a main-display or mirroring API. **Consequence:** the existing Sidecar/BetterDisplay arrangement, which is the user's only screen, stays as it is; R-01 is not made worse. Making the iPad the main display stays Phase 2 work behind a rollback path.

## D-016 Audio before camera; camera deferred until a paid membership (user decision, 2026-11-16)
The camera needs a CoreMediaIO Camera Extension, which needs `com.apple.developer.system-extension.install`; a free Personal Team cannot provision it and disabling SIP is out of scope. **Decision (user):** build iPad speaker and microphone as Mac audio devices now; camera later. Touch-mapping offset (E-07, ~5 % vertical) is parked and stays open.

## D-017 Own loopback AudioServerPlugIn, bridged by the host app (user decision)
**Decision:** a minimal HAL plug-in (`MacVirtualDevices/AudioDriver`) publishes two loopback devices, "iPad Speaker" and "iPad Microphone". Apps play into "iPad Speaker"; the host reads its loopback input and streams PCM to the iPad. The host plays iPad microphone PCM into "iPad Microphone"; apps record its loopback input. **Consequence:** the driver runs inside coreaudiod with no IPC, sockets or custom Mach services (smallest privileged surface). Each device also shows its other direction in Audio MIDI Setup (as BlackHole does); only the intended direction may become a system default. Installing needs admin once. No third-party code (BlackHole is GPL-3.0).

## D-018 Background audio keeps the session; video pauses (user-visible behaviour)
With audio active the iPad app may run in the background (`UIBackgroundModes: audio`, a public mode). Leaving the foreground then pauses video instead of ending the session: the host stops capture and removes the virtual display, keeping audio, and recreates both when the app returns. Microphone capture is off by default and only starts from the in-app toggle (spec §7 privacy).

## D-019 HEVC is the default video codec (user A/B test, 2026-11-17)
**Context:** the spec makes H.264 the baseline and HEVC optional after negotiation. In a timed A/B test (H.264 and HEVC alternating every 20 s, three rounds, same 80 Mbit/s and test page) the user judged HEVC better for text and colour edges; HEVC frames were also ~25 % smaller. **Decision:** request HEVC by default; it is used only when the iPad advertises it, and the host falls back to H.264 if the hardware HEVC session cannot be created. `--codec h264` remains. **Consequence:** H.264 stays the guaranteed baseline path; HEVC Main10 / 4:4:4 remain experiments (they need P3/HDR work and iPad decode verification).

## D-020 Follow mirroring instead of fighting it (user decision, 2026-11-17)
**Context:** the user's display tools (BetterDisplay) can put the WiredDisplay screen into a mirror set; ScreenCaptureKit does not offer a mirrored display. **Decision:** capture the mirror set's primary display (`CGDisplayPrimaryDisplay`) and stream that, so the iPad shows what the mirror shows. **Consequence:** D-015 still holds — the host never changes the arrangement or the main display.

## D-021 sRGB is the default colour path (measurement, BUG-033)
P3 end to end produced visibly paler colours on the iPad. sRGB / BT.709 is the default; Display P3 is behind `--color p3`.

## D-022 Hybrid chroma is the default (user test, 2026-11-17)
**Context:** 4:2:0 bleeds colour on edges; full 4:4:4 needs the standard rate controller, which made the cursor lag (200+ ms frame gaps). **Decision:** `--chroma hybrid` by default — 4:2:0 low-latency while >10 % of the screen changes or the cursor moves, 4:4:4 once the screen is quiet (BUG-034). User verdict: cursor smooth, click effects sharp. **Consequence:** two hardware encode sessions and BGRA capture per stream (host CPU unchanged in measurements); `--chroma 420` remains the fallback.

## D-023 Authenticated, encrypted channel with pairing (R-SEC-01, 2026-11-17)
**Context:** any process on the Mac can reach the iPad's port 9100 through usbmuxd, and any iPad app could listen on that port. Without authentication, the host would stream the Mac's screen to whatever answers there and inject its input. **Decision:** protocol v2.
- Each side has an Ed25519 identity, stored in the Keychain (this device only).
- Every connection exchanges fresh X25519 keys. HKDF-SHA256 derives one AES-256-GCM key per direction, with the transcript of both hellos as the salt.
- Each side proves its identity with an Ed25519 signature over the transcript.
- Every frame after the handshake is encrypted. The 36-byte header is the AAD, and the nonce is the stream plus its sequence number. Together with the sequence validator, tampering, replay and reordering all close the connection.
- Nothing except ping, pong and bye is accepted before verification. The host also holds control messages and drops media and input until it trusts the peer.

**Trust:**
- The iPad always asks the user to pair with an unknown Mac, showing a 6-digit code that both sides derive.
- The Mac pairs the first iPad automatically when none is paired yet (trust on first use), because a headless Mac has no screen to ask on. Any other unknown iPad needs confirmation in an alert, which times out after 2 minutes.
- Both sides can forget their paired peers: the Mac from its menu, the iPad from its controls.

**Consequence:**
- Old app builds are refused (`unknownTag(9)` in the log).
- The trust-on-first-use window is the time between install (or Forget) and the first connection. The Mac menu shows the paired iPad and the connection code.
- Measured on hardware: 42 fps, the same as before encryption, with a 1.45 ms control RTT.

## D-024 Magic Keyboard and trackpad (R-INP-02, 2026-11-17)
**Keyboard:**
- The iPad sends each key's HID usage (its physical position), and the Mac's own keyboard layout decides the character.
- The host tracks modifier state and generates key repeat at the Mac's repeat settings.
- Keystrokes are never logged.
- Shortcuts that iPadOS reserves for itself never reach the app: Cmd-Tab, Cmd-Space, Globe shortcuts and the Home or App Switcher keys.

**Trackpad:**
- The iPad pointer is hidden while streaming.
- A click is a real button press (drag and double click work); a two-finger click is a right click.
- Two-finger scrolling sends phased, continuous scroll events with momentum generated on the iPad, so Mac apps scroll like with a trackpad, including the edge bounce.

**Not possible with public APIs:** pinch-zoom, rotate and smart-zoom gestures, and three- and four-finger swipes (which iPadOS keeps). Native macOS multitouch stays UNSUPPORTED (R-INP-01b).

**Gating:** all of this is gated by the same "Allow input" switch and the Accessibility permission as touch (D-006).

## D-025 iPad as the main display of a headless Mac; "looks like" sizes (2026-11-17)
**Context:**
- With no other display attached, the WiredDisplay screen is the Mac's only display, so macOS makes it the main display by itself. The host still never rearranges displays (D-015).
- The virtual display had a single native mode (1590×1192 pt for this iPad), and the only other choices macOS offered were smaller.

**Decision:**
- Offer three HiDPI modes: native, "more" (×1.125, 1788×1340) and "most" (×1.25, 1988×1490).
- "more" is the default, at the user's request. Choose with `--space`, or in System Settings › Displays.
- The framebuffer limit grows to fit the largest mode. Capture scales it to the iPad's panel pixels (`scalesToFit`), so the stream size does not change.

**Limits:**
- The login window, FileVault pre-boot and Recovery stay unsupported (R-DIS-04b): the host runs only inside a logged-in session. Open at Login (P1-010) starts it right after login.

## D-026 Touch follows Sidecar's direct touch (user decision, 2026-11-17)
**Context:** the user found Sidecar's touch model (direct touch in macOS 27) more natural than the earlier mapping, in which a drag was a mouse drag and a hold was a right click.

**Decision:**
- One finger: tap = click; drag = scroll, with trackpad phases and momentum; hold for 0.35 s, then drag = left-button drag (select text, move windows).
- Two fingers: tap = right click; drag = scroll; pinch = zoom, sent as Command-= / Command-- steps (one per ×1.3), because macOS has no public magnify-event API.
- Three fingers: pinch in = copy (twice within 1.5 s = cut); pinch out = paste; swipe left or right = undo or redo. These are sent as key shortcuts.
- Gestures with two or more fingers use UIKit recognizers, including a custom three-finger recognizer (BUG-025: raw touches never saw the second finger). The pure logic (`TouchInterpreter`, `EditGesture`, `PinchZoomStepper`) is unit-tested.

**Consequence:**
- The old mapping ("hold = right click", "drag = drag") is gone.
- Pinch zoom works only where Command +/- zooms (browsers, Preview, most document apps), not as smooth magnification.
- All of these go through the same input switch and the Accessibility permission (D-006).

## D-027 Quality presets in the menu bar (user request, 2026-11-17)
**Decision:** a **Quality** submenu in the host's menu bar, with four presets:

| Preset | Chroma | Depth |
|---|---|---|
| Balanced (default) | hybrid | 10-bit |
| Pro | 4:2:0 | 10-bit |
| Ultra | 4:4:4 | 10-bit |
| High Color | 4:4:4 | 8-bit |

- A switch is live: only the capture and the encoder are rebuilt. The virtual display and the session stay up, and the iPad rebuilds its decoder from the next keyframe.
- The choice is saved in UserDefaults and applies at the next launch, including Open at Login. `--chroma` and `--depth` still override it.

**Measured on hardware (10:13, user switching through all four presets):**
- Each switch took 70–150 ms, with no disconnect.
- Encode p50 / p95 per preset:
  - Pro: 15 / 16 ms.
  - Balanced: 15–16 / 16–22 ms.
  - Ultra: 14–62 / up to 100 ms during motion. This is the standard rate controller's lag (BUG-034), now a deliberate trade-off the user can choose.
  - High Color: 10–38 / about 56 ms.

## D-028 The input choice is remembered across launches

Input from the iPad (touch, Magic Keyboard, trackpad) still starts **off** on a new install, and only the user's own menu choice turns it on (D-006, D-012). **Change:** that choice is now saved (`allowInput` in the host's UserDefaults) and applied at the next launch, because with the host opening at login the user otherwise had to re-enable it after every restart and read it as "keyboard/trackpad do not work". Turning it off in the menu is remembered the same way. Input still requires a trusted, paired iPad (D-023) and Accessibility permission.

## D-029 Real pinch and rotate gestures on the Mac (user request, 2026-11-17)

Pinch and two-finger rotate, from the touch screen and from a Magic Keyboard trackpad, are sent as `magnify` / `rotate` input events (incremental, macOS conventions) and posted on the Mac as trackpad gesture events: CGEvent type 29 with IOHID type 8 (zoom) or 5 (rotation), value in field 113/114, phase in field 132 (1 began, 2 changed, 4 ended, 8 cancelled). This layout is undocumented (also used by Hammerspoon); `NSEvent(cgEvent:)` turns it into NSEventTypeMagnify / NSEventTypeRotate on macOS 27. **Consequence:** smooth zoom and rotate in apps that support trackpad gestures (Safari, Maps, Preview, Photos). It may break in a later macOS; if the event cannot be created, pinch falls back to Command-plus / Command-minus (the D-026 behaviour). Three- and four-finger trackpad gestures stay unavailable: iPadOS keeps them and never delivers them to apps.

## D-030 Control stands in for Command for shortcuts iPadOS keeps (user decision, 2026-11-17)

Key commands with `wantsPriorityOverSystemBehavior` did not help: on hardware iPadOS still took Command-Tab, Command-Space and the screenshot shortcuts, and none reached the Mac. **Decision (user):** on the iPad keyboard, Control-Tab, Control-Shift-Tab, Control-`, Control-Space and Control-Shift-3/4/5 are sent to the Mac as the same shortcut with Command (`ShortcutRemapper`). Control keeps acting as Command until it is released, so holding Control and tapping Tab walks the Mac app switcher. Every other shortcut, including Control-C and Control-arrows, goes through unchanged. **Trade-off:** the Mac's own Control-Tab (next browser tab) and Control-Space (input source) are not reachable from the iPad keyboard; Command-Shift-] / [ switch tabs instead. The iPad app lists the shortcuts under Controls › Keyboard & trackpad.
