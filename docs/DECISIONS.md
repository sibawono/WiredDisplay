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

## D-031 Automatic format step-down per iPad; panel density from the iPad (user request, 2026-11-17)

Not every iPad on iPadOS 17 can decode HEVC 4:4:4 (Ultra, High Color, and the still lane of Balanced) or 10-bit, and VideoToolbox offers no cheap way to ask in advance. **Decision:** the iPad watches its video renderer; three failures within 10 s (`DecodeFailureDetector`) send `decodeFailed` to the Mac, which drops 4:4:4 first and then 10-bit (`DecodeLimits`), restarts the encoder on the same display, and remembers the limit for that iPad's key (`decodeLimits` in UserDefaults; cleared by "Forget Paired iPads"). The user's preset is unchanged; the menu shows "(this iPad: …)". The iPad advertises HEVC only when `VTIsHardwareDecodeSupported` says so, and sends its panel density (326 ppi for iPad mini, 264 otherwise) so the virtual display's physical size is right. Protocol version 3 (the hello gained `pixelsPerInch`). Verified on hardware with `--test-decode-fallback` (a simulated failure stepped Pro down to 4:2:0 8-bit in 0.1 s, video continued); a real failing iPad has not been tested.

## D-032 One-way audio devices for apps, hidden taps for the host (user request, 2026-11-17)

**Problem:** "iPad Speaker" and "iPad Microphone" were each one two-way loopback device, so both appeared in every app's microphone list and speaker list. In a Google Meet call the wrong pairing gave exactly the reported symptoms (others could not hear the user; the user could not hear them), and the names do not make the mistake obvious. **Decision:** each loopback channel (one ring buffer and timeline) is now published as two devices: a visible one-way device for apps ("iPad Speaker" output only, "iPad Microphone" input only) and a hidden one-way device for the host ("iPad Speaker Tap" input, "iPad Microphone Feed" output; `kAudioDevicePropertyIsHidden`, found by UID). Visible UIDs are unchanged, so app and system preferences keep pointing at the same devices. **Verified:** `wd-audio-probe loopback speaker|microphone` pass (1 kHz tone, RMS 0.177 as sent); `wd-audio-probe list` shows the visible devices one-way and the taps hidden; the host's speaker and microphone bridges run on the taps; a Google Meet call then worked both ways (user). The driver must be reinstalled; a host from before D-032 cannot find its devices with the new driver (and the reverse).

## D-033 Real iPad brightness from the Mac (user request, 2026-11-17)

The virtual display has no backlight, so macOS brightness keys do nothing and BetterDisplay falls back to software dimming (a darker picture; the cursor, composited later by ScreenCaptureKit, stays bright; the iPad backlight stays on). **Decision:** the iPad app sets its real screen brightness (`UIScreen.brightness`, public API, app in the foreground) when the Mac sends `brightness(Float)`, and reports its brightness on connect and whenever it changes (Control Center), echo-suppressed. On the Mac, the brightness keys (Apple keyboards: system-defined events; third-party keyboards such as the ProtoArc K90: key codes 144/145, found with `--trace-keys`; active event tap at HID level so it runs before BetterDisplay/MonitorControl, needs Accessibility) step it in 16 steps (64 with Option-Shift) while an iPad is connected and pass through otherwise; the menu has a brightness slider. The iPad shows a short indicator. Protocol version 4. BetterDisplay's own brightness control for the WiredDisplay screen should be turned off to avoid both acting on the keys.

## D-034 Headphones in, iPad out: automatic audio device switching (user request, 2026-11-17)

macOS usually moves output to headphones when they connect, but on disconnect it falls back to whatever it ranks next (often "Mac mini Speakers"), not to the iPad, and a headset microphone may or may not become the input. **Decision:** the host (`AudioRouter`) watches the device list and acts only on changes: a Bluetooth (AirPods), USB (USB-C earphones, headsets) or headphone-jack output that appears becomes the default output, and a microphone of such headphones (a device with input and output, so a webcam or lone USB mic is ignored) the default input; when they disappear, the default goes back to "iPad Speaker" / "iPad Microphone" if the iPad has that direction on. When the iPad turns a direction on and no headphones are connected, that iPad device becomes the default. Manual choices are never overridden outside those transitions. A switch in the panel's Audio tab turns it off (`autoSwitchAudio`, on by default). Note: making AirPods the input switches them to the Bluetooth headset profile (lower output quality), as macOS itself does. So a second switch, "Use their microphone too" (`autoSwitchMicrophone`, default on), can be turned off for "output only": headphones get the sound, the input stays on the iPad microphone (or the previous one); if macOS moves the input to the headset mic within 5 s of the headphones arriving, the host moves it back. Later manual choices stand.

## D-035 Investigation: a true 10-bit virtual display (2026-11-17, no code change)

Question (user): BetterDisplay shows the WiredDisplay screen as 8-bit although the preset says 10-bit. **Finding:** correct. Today the virtual display framebuffer is 8-bit (`--------RRRRRRRRGGGGGGGGBBBBBBBB`), capture is 8-bit (BGRA or 4:2:0 8-bit), and only the HEVC encode is 10-bit (Main 10), which avoids extra banding from compression but adds no colour depth. Probing the private API with short-lived 1280×800 test displays (main display and arrangement unchanged each time): `CGVirtualDisplayMode initWithWidth:height:refreshRate:transferFunction:` with transferFunction 0, 2, 3, 4, 5 and an EDID declaring 10 bpc (`displayInfo` key `IODisplayEDID`) all stay 8-bit SDR; **transferFunction 1 makes the display HDR** (`NSScreen.maximumPotentialExtendedDynamicRangeColorComponentValue` = 5.0), i.e. WindowServer composites it in extended range. The legacy pixel-encoding string and `NSScreen.depth` still say 8 bits for it, so they do not reflect HDR compositing. **Possible next step (not done):** an experimental "HDR / 10-bit" preset: HDR virtual display (transferFunction 1) + ScreenCaptureKit HDR capture in a 10-bit pixel format + HEVC Main 10 with HDR metadata, and HDR playback on the iPad. Open questions: whether captured SDR content then carries more than 8 bits, how SDR UI looks after tone mapping on the iPad's SDR panel, cost and latency.

**D-035 experiment result (user request, same day; code reverted):** an experimental preset was built and tried on hardware. (1) HDR display + ScreenCaptureKit HDR preset (`xf44`, 4:4:4 10-bit full range, Display P3 PQ) + HEVC Main 10 tagged from the capture (first without tags, the iPad saw "transfer none"; then P3/PQ): ~50 fps, but the user found it washed out on the iPad's SDR panel. (2) HDR display captured SDR-referred as 10-bit RGB (`l10r`, sRGB) + the 10-bit conversion lane, tagged BT.709 like Pro: the user saw no difference from Pro, and latency rose noticeably (~40 fps, 285 ms gaps). **Decision:** not shipped; the code was reverted and Pro stays the recommended preset. The 10-bit HEVC encode of the existing presets remains the useful part (less banding from compression).

## D-036 ProMotion (up to 120 Hz) and living next to Sidecar and DisplayLink (user request, 2026-11-17)

**Refresh:** the host now follows the iPad's maximum refresh (120 Hz on iPad Pro, 60 Hz elsewhere) unless the panel switch "Match the iPad's refresh rate" is off (60 Hz) or `--fps` fixes a rate. Measured on this Mac (Apple M6) with a VideoToolbox benchmark: the low-latency rate controller cannot go past ~60 fps at iPad Pro sizes (2752×2064: every frame dropped above 60; 2420×1668: ~83 fps at 57 ms), while the standard rate controller sustains 120 fps (7–9 ms). So above 60 fps the 4:2:0 lane uses standard rate control. (`MaxFrameDelayCount` turned out to be unsupported by this encoder, error -12900; the drop from 44 to 8 ms seen in the first 120 Hz run was encoder warm-up, not that property.) End to end with `--force-refresh 120` on the 60 Hz iPad Air (3180×2384, larger than any iPad Pro) and an animation: capture, encode and iPad presentation ~119 fps, encode p50 8.3 ms / p95 11.7 ms after warm-up (p50 30–44 ms during the first seconds). On the iPad side, video is enqueued with "display immediately" and carries no frame rate, so an adaptive ProMotion panel could stay at 60 Hz; while the stream is above 60 fps the iPad app now runs a `CADisplayLink` with `preferredFrameRateRange` up to the stream rate (and sets `CADisableMinimumFrameDurationOnPhone`), logging "refresh: stream N Hz, screen up to M Hz, requested K Hz". Verified on the 60 Hz iPad Air with `--force-refresh 120`: the link is created and clamps to 60, and the app decodes and presents ~119 fps. Not yet seen on a real ProMotion iPad.

**Coexistence:** (1) the host used to try only the first cabled device usbmuxd listed; with another iPad on wired Sidecar or an iPhone plugged in first it would never reach the WiredDisplay iPad. It now tries every cabled device, the last one that answered first (`UsbmuxDevice.preferring`). (2) Brightness keys go to the iPad only when it is the only display or the pointer is on it, so a DisplayLink monitor or a Sidecar iPad keeps its own brightness keys. (3) Automatic audio switching ignores USB audio of docks and monitors (DisplayLink docks expose one), so plugging in a dock does not take the sound from the iPad. Nothing else is shared: each product has its own virtual display, the arrangement is never changed (D-015), and the hardware encoder serves several sessions (heavy use of all three at once may cost frame rate). Not tested here: a second iPad on Sidecar, a DisplayLink display.


## D-037 Latency work at 60 Hz, and what OpenDisplay teaches (user request, 2026-11-17)

**Priority (user):** 60 Hz with the lowest latency and the best picture. **Measured** (new iPad log line "sent->enqueued": Mac send → iPad display layer, clocks aligned with pings): with an animation at 3180×2384, encode is ~15–16 ms and Mac→iPad transfer ~1 ms; encode is the whole budget. Tried and rejected: standard rate control at 60 Hz (70 ms), telling the encoder 120/240 fps (no change), completing each frame right after submit (no change, fewer fps), `MaximizePowerEfficiency` false (no change; kept, harmless), `PrioritizeEncodingSpeedOverQuality` and `MaxFrameDelayCount` (both unsupported here, -12900). **Why:** OpenDisplay's measurements put the Apple encoder at roughly 400–500 Mpx/s; 3180×2384 at 60 Hz is 455 Mpx/s, so the encoder is saturated and every frame takes a full frame period. **Changed:** no periodic keyframes (every 2 s was a large frame and a hitch; the iPad requests one when it needs it), as OpenDisplay does. **Found:** the iPad reports 3180×2384 although an iPad Air 13″ panel is 2732×2048, i.e. its Display Zoom is probably "More Space"; at Default the stream would be 2732×2048 (26 % less encode work, ~11–12 ms expected, and 1:1 pixels instead of a double scale). Not verified.

**OpenDisplay (opendisplay.app, GPL-3.0, studied from source):** same architecture (CGVirtualDisplay, ScreenCaptureKit, VideoToolbox, usbmuxd, AVSampleBufferDisplayLayer). Worth adopting, in order of value for the user's priority: (1) **local cursor**: the cursor is left out of the video and drawn on the device from a separate, tiny position/image channel, so it moves with transfer latency (~1 ms) instead of the encode pipeline (~16 ms); (2) no periodic keyframes (done); (3) capture straight to 4:2:0 to skip a conversion (relevant to the 8-bit presets; our 10-bit path converts by design); (4) an optional Metal renderer with `VTDecompressionSession` instead of the display layer, which they suspect buffers one extra frame (experimental there); (5) an on-screen latency/fps overlay; (6) features: portrait orientation (rebuild the display when the device rotates), several iPads at once, Apple Pencil pressure/tilt/hover as tablet events, iPhone as a receiver, and the tip to enable System Settings › Notifications › "Allow notifications when mirroring or sharing the display" (macOS hides notifications while any app captures the screen).

## D-038 Local cursor (user request, after OpenDisplay, 2026-11-17)

The cursor baked into the video carries the whole capture→encode→transfer pipeline (~16 ms encode alone at 3180×2384, D-037). **Decision:** by default the capture leaves the cursor out (`showsCursor` false) and the host streams it separately: `CursorEcho` samples the pointer at 120 Hz and sends `cursor(x, y, visible)` (normalized to the WiredDisplay screen; hidden off-screen or when macOS hides the pointer, `CGCursorIsVisible`), and checks `NSCursor.currentSystem` at 30 Hz, sending `cursorImage` (PNG ≤ 32 KB, size as a fraction of the display, hot spot as a fraction of the image) only when it changes. The iPad draws it in a `CALayer` above the video. When the iPad's own trackpad moves the pointer, the layer follows the finger immediately and ignores the Mac's echo for 150 ms, so it never lags. Panel switch "Draw the cursor on the iPad" (Display tab, `localCursor`, default on) puts it back into the video. Protocol version 5. Verified: messages round-trip (unit test); host streams with the cursor drawn on the iPad. On hardware the user confirmed the cursor looks right and feels more responsive.

## D-039 Portrait orientation (user request, after OpenDisplay, 2026-11-17)

The iPad app now supports all four orientations. When its view flips between landscape and portrait (debounced 0.4 s) it sends `panelSize(width, height)` with the panel pixels in the new orientation; the next hello also carries the current orientation. The host updates the iPad's hello and rebuilds the display (`restartVideo(hello:)`) with the swapped size, so macOS sees a vertical monitor at native resolution; the session stays up. Protocol version 6. Not yet tried by rotating the iPad.

## D-040 Metal renderer, experimental (user request, after OpenDisplay, 2026-11-17)

An alternative to AVSampleBufferDisplayLayer, which may hold about one extra frame: `MetalVideoRenderer` decodes with `VTDecompressionSession` (real-time; 8- or 10-bit 4:2:0 output by the stream's bit depth) and draws the newest frame with a BT.709 video-range YUV→RGB shader onto a `CAMetalLayer` (`bgr10a2Unorm`, sRGB, aspect fit) as soon as it is decoded. `SwitchableSink` lets the session feed either path; switching restarts at a keyframe. iPad Controls › Display › "Metal renderer" (remembered). Verified on the iPad: the Metal path decodes and presents ~60 fps with no decode errors, and the user judged it better than the system layer, so **Metal is now the default**; the switch turns it off.

## D-041 Several iPads at once (user request, after OpenDisplay, 2026-11-17)

`HostFleet` watches usbmuxd and runs one `HostController` per cabled device (device filter by serial), each with its own virtual display, capture, encoder, input injector and brightness-key tap (keys act on the display under the pointer). Each display gets its own serial number so macOS keeps arrangement and mode apart; the first iPad ever seen keeps serial 1, the identity WiredDisplay always used (`displaySerials` in UserDefaults), so the existing setup is unchanged. One audio driver: the first iPad that turns audio on owns it until it turns audio off or disconnects; the others' audio requests are logged and ignored. The panel shows the first streaming iPad, lists the others ("Also: …"), and applies global settings (quality, input, refresh, cursor) to all. Each iPad costs encoder time: two iPads at 3180×2384 exceed the encoder (~455 Mpx/s each, D-037), so frame rate will drop; smaller iPads leave room. Verified with one iPad (fleet with one controller, serial 1, streaming normal). Not tested with two iPads.

## D-042 v0.4.1: correctness and real measurements from the v0.4.0 audit (2026-11-17)

From `WIREDDISPLAY_V0.4.0_AUDIT.md`, checked against the code and fixed:
- **Metal kept 4:4:4 only as 4:2:0.** The decoder output was always 4:2:0, so Balanced (its still lane), Ultra and High Color lost the colour detail they encode. The renderer now reads `chroma_format_idc` and bit depth from the HEVC SPS (`HEVCSPSInfo`, unit-tested against real encoder output) and asks for 4:4:4 (8/10-bit) output when the stream is 4:4:4; the shader is unchanged (full-size chroma plane). Balanced's lane switches reuse the other lane's decoder instead of rebuilding it. Verified on the iPad: "metal decoder: 4:4:4 10-bit output" with Balanced.
- **Decode and presentation shared one queue**, so waiting for a drawable held up decoding. Now separate queues, newest decoded frame wins, and a generation fence drops decodes and frames from before a flush (renderer switch, rotation, reconnect).
- **Video could overtake its stream config** and the iPad ended the session. The host now sends `streamConfig` before capture starts, and the iPad drops an early frame and asks for a keyframe instead of failing.
- **"video presented" counted enqueues, not frames on the glass.** The Metal path now logs `metal on glass`: frames that reached the display (`addPresentedHandler`) and enqueue→glass time. Measured on the iPad Air (Pro preset, animation): ~59.6 fps on the glass, decode ~4 ms, **enqueue→glass p50 ~39–41 ms**, so ~35 ms is Core Animation composition and scan-out (about two refreshes). Tried `CAMetalDisplayLink` with `preferredFrameLatency` 1: no improvement (~39 ms) and fewer frames (53–55 fps), reverted. Next lever (not done): conditions for direct-to-display (a full-screen opaque Metal layer with nothing composited over it).
**Raster test (done):** the iPad was on Display Zoom "More Space", so it reported 3180×2384 for a 2732×2048 panel. Switched to **Default**, the whole chain runs at 2732×2048: host encode p50 **16 → 12.2 ms**. At first the Metal path then fell to 30 fps (80 ms) because two drawables starved while composition held one; with `maximumDrawableCount` 3 it shows **60 fps on the glass with enqueue→glass p50 ~30 ms** (from ~40 ms), 0 frames replaced. So Default saves ~4 ms of encode and ~10 ms of presentation, and sends 1:1 pixels; More Space keeps the larger Mac workspace (up to 1788×1340 instead of 1708×1280). Not done: a CI build of the production app.

## D-043 WiredDisplay's own display size may change when it is the main display (2026-11-25)
**Context:** with no other monitor connected (a headless Mac, or the main monitor switched off), macOS makes the WiredDisplay virtual display the main display on its own. The panel's Default / More / Most Space control refused any main display (D-015), so only Default was left. **Decision:** the size control may change the mode of WiredDisplay's own virtual display even when macOS made it the main display. It still only picks one of that display's own modes, applies it for the session only, and never touches a mirrored display. **Consequence:** D-015 still holds: the host never makes its display the main display, and never changes another display or the arrangement.
