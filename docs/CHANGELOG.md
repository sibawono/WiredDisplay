# Change Reports

## CHANGE ID: P0-001 — Phase 0 feasibility scaffold and probes

**OBJECTIVE:** Establish what is feasible on this exact hardware/OS and build the smallest hardware-testable pieces of the critical path, without touching the live display arrangement.

**FILES CHANGED:** `Package.swift`; `Shared/{Protocol,Usbmux,Geometry}/*`; `macOSHost/Display/CVirtualDisplay/*`; `macOSHost/Probes/{wd-usbmux-probe,wd-vdisplay-probe}/main.swift`; `iPadOSClient/TransportProbe/**`; `Tests/Unit/{WDProtocolTests,WDUsbmuxTests,WDGeometryTests,CVirtualDisplayTests}/*`; `scripts/verify.sh`; `docs/*`.

**APIs/ENTITLEMENTS USED:** private `CGVirtualDisplay*` (runtime-resolved, no linked symbol); usbmuxd plist protocol over `/var/run/usbmuxd`; Network.framework `NWListener` (loopback); VideoToolbox (probe only); CoreGraphics display queries. No entitlements. No TCC permission requested or used by our code.

**IMPLEMENTATION SUMMARY:** versioned 36-byte frame header with per-stream caps and a bounded, poison-on-error parser; usbmuxd codec and a deadline-bounded client with a mux/tunnel/dead lifecycle and Wired Only device policy; aspect-fit coordinate mapper; fail-closed virtual display shim; a probe for each critical-path experiment; a loopback echo app for the iPad.

**PASS A CHECKS:**
- `swift build` (Swift 6 language mode, complete concurrency checking): 0 errors, 0 warnings.
- `swift test`: **60 tests, 0 failures, 0 skipped** (Protocol 23, Usbmux 27, Geometry 7, Shim 3).
- Shared libraries `xcodebuild … -destination generic/platform=iOS`: BUILD SUCCEEDED.
- TransportProbe app, unsigned, for the iOS device SDK: BUILD SUCCEEDED.
- `wd-vdisplay-probe check`: private surface present, expected ABI.
- `wd-usbmux-probe list` / `echo`: against the real daemon, the iPad is reached as USB and the connection is refused (no listener installed).

**PASS B ADVERSARIAL FINDINGS:**
- Self-review: BUG-001 to BUG-003.
- Independent reviewer agent: 14 confirmed findings, recorded as BUG-004 to BUG-010. Remaining S4 items: misleading error names, ignored mistyped CLI flags, a header comment. Fixed or documented, except that the probe CLIs still ignore unknown flags (S4, tracked).
- Most serious: BUG-004. The display shim leaked the private display object, so a display could never have been removed. The first Pass B missed it.

**NEGATIVE/EDGE TESTS:** truncated/garbage/bit-flipped frames (fuzzed, seeded); per-stream length boundaries; 4 GiB announced length; undrained-append bound; poison semantics; duplicate, reordered and exhausted sequence numbers; usbmuxd hostile length, tag mismatch, truncated reply, peer close, refusal, tunnel-state misuse, non-USB device; trickling peer vs. deadline; letterbox bars, NaN/∞, denormal and huge geometry; 10 invalid display configs.

**REGRESSION TESTS:** one or more per bug, BUG-001 to BUG-010 (see BUG_LOG.md). Socket tests: 5 serial runs and 3 parallel runs with 8 workers, all green.

**REAL DEVICE TESTS:** usbmuxd lists the iPad as USB at 480 Mbit/s, and a connect request reaches its TCP stack (refused). **NOT RUN:** E-03 virtual display, E-05 bytes over the cable, E-07 input injection.

**BUGS FOUND/FIXED:** BUG-001 to BUG-010, all fixed. BUG-004 and BUG-010 are verified only as far as possible without hardware.

**REMAINING RISKS:** see RISKS.md, chiefly R-01 (stranding the headless Mac), R-02 (no authentication yet), R-03 (private API), R-09 (camera blocked on the free team).

**MEASURED PERFORMANCE:** NOT MEASURED. Only hardware encoder availability was observed.

**ROLLBACK/RECOVERY:** nothing is installed or registered; no system setting was changed. Deleting the folder fully reverts this change. A display created by the probe is tied to the process lifetime.

**STATUS:** PARTIALLY VERIFIED. Code is verified locally; the critical-path hardware gate is not passed.

**NEXT SAFE STEP:** with the user's consent, E-05 first (it touches neither the display set nor TCC), then E-03 with a second way into the Mac ready.

## CHANGE ID: P0-002 — E-05 wired transport on hardware

**OBJECTIVE:** Prove bidirectional bytes between the Mac and a sandboxed iPad app over the USB-C cable.

**FILES CHANGED:** `iPadOSClient/TransportProbe/Sources/EchoServer.swift` (BUG-011); `docs/{FEASIBILITY,CAPABILITY_MATRIX,RISKS,BUG_LOG,CHANGELOG}.md`; `docs/evidence/e05-*`.

**APIs/ENTITLEMENTS USED:** usbmuxd `ListDevices`/`Connect`; `NWListener` on 127.0.0.1; free Personal Team development signing (new App ID `dev.wireddisplay.u<team>.transportprobe`, 7-day profile); `devicectl` install, launch and screenshot.

**PASS A CHECKS:** signed device build `BUILD SUCCEEDED`; install and launch OK; 5 echo runs, exit 0, byte-exact.

**PASS B ADVERSARIAL FINDINGS:**
- The first hardware attempt failed (BUG-011), caused by an unverified review fix; now fixed and recorded.
- One 256 MiB run ended with `closedByPeer` because the app was backgrounded (expected platform behaviour, R-06), not a defect.
- A batch-script error on the measurement host (zsh word-splitting) produced no data and was rerun; not a product defect.
- The rate metric understates one-way capacity (documented).

**NEGATIVE/EDGE TESTS:** listener absent → refused (exit 3); app backgrounded mid-transfer → `closedByPeer` within one frame, no hang; frame sizes 4 KiB to 4 MiB.

**REAL DEVICE TESTS:** **E-05 VERIFIED ON REAL HARDWARE** (Mac18,5, macOS 27.2.1; iPad14,10; usbmuxd link 480 Mbit/s). **NOT RUN:** Wi-Fi off, unplug mid-run, iPad-side disconnect detection, cable swap.

**MEASURED PERFORMANCE:** 29 / 95 / 102 / 119 Mbit/s one-way lower bound at 4 KiB / 64 KiB / 256 KiB / 4 MiB frames; round trip p50 0.54 ms at 4 KiB, 5.29 ms at 256 KiB.

**ROLLBACK/RECOVERY:** delete the WD Probe app from the iPad; the free-team App ID expires on its own. No Mac or display setting was changed.

**STATUS:** VERIFIED for transport; PARTIALLY VERIFIED for the "wired only" proof.

**E-05b (Wi-Fi off, unplug):** started, then aborted before any Wi-Fi or cable change. The user's only screen for the Mac is Sidecar on the same iPad: the instructions could not be read while the probe was in front, and the steps could drop Sidecar. Deferred by the user's decision. Monitor log: `evidence/e05b-aborted-monitor.txt` (23 more byte-exact passes while in the foreground, then refused once backgrounded; this confirms R-06 a second time).

**NEXT SAFE STEP:** provide a second way into the Mac (a physical monitor or HDMI dummy for test days, or Screen Sharing/SSH from another device), then E-05b and E-03.

## CHANGE ID: P1-001 — End-to-end pipeline (built ahead of the hardware gate, D-012)

**OBJECTIVE:** Everything needed for the first real session: Mac virtual display → capture → hardware encode → USB → iPad display, and iPad touch → Mac input.

**FILES CHANGED:** new `Shared/Session/{Wire,Messages,SendScheduler,TouchInterpreter}.swift`, `Shared/Video/{AnnexB,SampleBuffers}.swift`, `Shared/Transport/FramedSocket.swift`; `macOSHost/Host/*` (HostController, CaptureEngine, VideoEncoder, InputInjector, VirtualDisplayController, Log, main); `iPadOSClient/WiredDisplayClient/**`; `Shared/Usbmux/UsbmuxClient.swift` (`detachTunnel`); `scripts/{build-host-app,install-ipad-app}.sh`; tests `WDSessionTests`, `WDVideoTests`, `WDTransportTests`; docs.

**APIs/ENTITLEMENTS USED:** private `CGVirtualDisplay` (via the shim); ScreenCaptureKit; VideoToolbox; CGEvent; AVSampleBufferDisplayLayer; Network.framework; usbmuxd. TCC: Screen Recording, Accessibility (host app). No entitlements; host is Developer-signed and not sandboxed.

**PASS A CHECKS:** `swift build`: 0 warnings. `swift test`: **102 tests, 0 failures**, 3 more parallel runs (8 workers) green. iPad client + probe: BUILD SUCCEEDED (device SDK). Host bundle built and signed with a stable identity.

**PASS B ADVERSARIAL FINDINGS:** independent reviewer — 15 confirmed + 7 plausible. Fixed: BUG-016 (S1 host crash) to BUG-022; documented: R-16, R-18, colour tag (R-VID-04). Own review during the build: BUG-015 (recursion), a main-actor read of queue state in the client.

**NEGATIVE/EDGE TESTS:** fuzzed message/Annex-B decoders; out-of-picture/non-finite pointer; scroll bounds; truncated/trailing/unknown messages; scheduler overflow/keyframe supersession; socket: garbage, first-frame-not-control, peer not reading (write deadline), oversize video, concurrent senders; touch: letterbox, cancel, long press, finger lift during scroll.

**REAL DEVICE TESTS:** NOT RUN for this change (by user decision, D-012). Codec round trip ran on the Mac's own hardware encoder/decoder.

**REMAINING RISKS:** R-01, R-02 (no authentication), R-03, R-16, R-17, R-18; untested: SCK on a virtual display, `AVSampleBufferVideoRenderer` threading, CGEvent on the virtual display, latency.

**MEASURED PERFORMANCE:** NOT MEASURED.

**ROLLBACK/RECOVERY:** Quit from the WD menu, or `pkill -x WiredDisplayHost`; the virtual display disappears with the process; Sidecar Travel `ctl.js connect` restores Sidecar. Nothing is installed system-wide.

**STATUS:** PARTIALLY VERIFIED (unit + local codec verified; hardware pending).

**NEXT SAFE STEP:** run `docs/TEST_SESSION.md`.

## CHANGE ID: P1-002 — Hardware session 1 + iPad audio as Mac devices (D-016…D-018)

**OBJECTIVE:** run the end-to-end pipeline on hardware; then (user priority) iPad speaker and microphone as Mac audio devices.

**FILES CHANGED:** `MacVirtualDevices/AudioDriver/WiredDisplayAudio.c` (new HAL driver), `scripts/build-audio-driver.sh`, `Shared/MacAudio/*`, `Shared/Session/{Messages,AudioJitterBuffer,SendScheduler}.swift`, `macOSHost/Host/{HostAudioBridge,HostController,InputInjector,main}.swift`, `macOSHost/Probes/wd-audio-probe`, `iPadOSClient/WiredDisplayClient/Sources/{ClientAudio,ClientLog,ClientSession,ClientApp,VideoView}.swift`, `Info.plist`, scripts, docs.

**PASS A CHECKS:** `swift test` 112 passed, 0 failures; driver built with `-Wall -Wextra -Werror`; iPad and host build clean.

**PASS B / HARDWARE FINDINGS:** BUG-023 … BUG-031 (all found on hardware, fixed, re-verified).

**REAL DEVICE TESTS:**
- VERIFIED: virtual display (extend-only, HiDPI 3180×2384), live video with sharp text (2,217 frames, 0 dropped), disconnect/reconnect and display release, input injection at the correct display coordinates, driver loopback (both devices, two readers), speaker to iPad, Mac volume keys/slider/mute, iPad microphone into "iPad Microphone".
- NOT VERIFIED: touch offset (~5 % low, open), mic+speaker echo quality, FaceTime/Zoom/browser device selection, audio latency.

**MEASURED PERFORMANCE:** control RTT 1.2–1.5 ms; video 0 dropped at 30 Mbit/s; audio jitter-buffer underruns 4 in 40 s (mic). Link negotiated at 480 Mbit/s (USB 2): a USB 3 cable is needed before raising bitrate.

**ROLLBACK/RECOVERY:** uninstall driver: `sudo rm -rf /Library/Audio/Plug-Ins/HAL/WiredDisplayAudio.driver && sudo killall coreaudiod`; quit host from the WD menu.

**STATUS:** PARTIALLY VERIFIED. **NEXT SAFE STEP:** audio latency (CoreAudio IO callbacks instead of 100 ms taps), then the USB 3 cable test.

## CHANGE ID: P1-003 — Low-latency audio (step 2)

**CHANGE:** Mac speaker capture via a CoreAudio IOProc at 240-frame (5 ms) IO buffers instead of AVAudioEngine taps (~100 ms chunks); iPad microphone via `AVAudioSinkNode` (one block per IO cycle, 7.5 ms observed) instead of a tap (~50 ms); jitter targets 30 ms (cap 100 ms) on both sides; iPad IO buffer 5 ms.
**PASS A:** 112 tests, 0 failures; host and iPad builds clean.
**REAL DEVICE TESTS:** VERIFIED by user: speech video lip-sync and music clear; microphone works. Logs: speaker 44,500 packets, 0 underruns; microphone 4,000 packets, 0 underruns (`evidence/audio-lowlatency-ipad-client.log`, host log).
**MEASURED PERFORMANCE:** buffer levels 25–47 ms; end-to-end latency estimated ~40–50 ms per direction (not instrumented).
**REMAINING:** acoustic latency measurement; FaceTime/Zoom/browser device checks.

## CHANGE ID: P1-004 — Link speed correction, 80 Mbit/s default, motion cadence analysis (step 3)
- **Link:** 10 Gb/s confirmed (System Information, IORegistry). usbmuxd's 480 Mbit/s field is not the link speed (BUG-032). Echo probe fixed; measured up to 1,386 Mbit/s per direction while streaming.
- **Bitrate:** default raised 30 → 80 Mbit/s (`--bitrate-mbps` 5…150).
- **Motion stutter (user report):** instrumented capture/encode/present cadence (`FrameRateMeter`). Capture 33–40 fps → encode identical → present identical; 0 video drops. Standalone ScreenCaptureKit measurements: a native 60 fps animation on the WiredDisplay screen is captured at only 34–44 fps; the main (Sidecar) display behaves the same; capture resolution makes no difference. Cause is upstream of the pipeline (display composition cadence under Sidecar + mirror load) — R-19. Change: capture minimum interval = half frame period (removes 50 ms gaps; max gap 33 ms).
- **Diagnostics added:** echo listener inside the client app (port 9000, foreground only), `docs/assets/test-pattern.html`.
- **Codec (D-019):** timed A/B test (H.264 ↔ HEVC every 20 s, 3 rounds): user preferred HEVC; HEVC frames ~25 % smaller at equal cadence, 0 drops, iPad decodes without errors. HEVC is now the negotiated default with H.264 fallback.

## CHANGE ID: P1-005 — Display P3 trial, sRGB default, mirror following (step 4)
- **P3 trial:** virtual display created with P3 primaries (optional setters, fail-closed), capture in Display P3, encoder tags P3-D65/sRGB/709. Tags survive the wire (unit test). On the iPad the colours were washed out (BUG-033), so **sRGB is the default**; `--color srgb|p3` selects the path.
- **Mirror following (D-020):** if the WiredDisplay screen is in a mirror set, the host captures the set's primary display (ScreenCaptureKit does not offer mirrored displays) and reports its point size to the iPad for input mapping. The arrangement is never changed.
- **PASS A:** A/B measurement sRGB 0.885 vs P3 0.711 chroma ratio. **PASS B:** default run 0.886; all unit tests pass.
- **REMAINING:** P3 only becomes useful if the iPad presentation path honours the tags (e.g. decode to tagged pixel buffers and present through a P3 Metal layer) — not pursued.

## CHANGE ID: P1-006 — Colour accuracy and edge quality (BUG-034)
- BT.709 transfer tag (fixes ~10-level brightness lift); idle refinement of still frames; experimental `--chroma 444` (HEVC RExt 4:4:4).
- **PASS A:** A/B measurements in BUG-034. **PASS B:** repeated runs for each mode (two pages each), unit tests pass.
- **P1-006b:** `--chroma 420|444|hybrid`, hybrid default (D-022, user-verified); hybrid lane switching with per-lane latency stats in the host log (`lanes:` lines every 5 s).
- **P1-007:** 10-bit HEVC by default (`--depth 8|10`) against gradient banding (BUG-035).
- **P1-008:** iPad video layer composited by the GPU (opacity 0.999) to keep dithering; toggle in the control panel (BUG-035, user-verified).

## CHANGE ID: P1-009 — Icons and DMG
- Menu bar glyph (screen + USB-C plug, vector template image; filled screen while streaming) replaces the "WD" text (`macOSHost/Host/MenuBarIcon.swift`).
- App icon (blue screen with USB-C plug): iPad asset catalog (1024 px, opaque) and host `AppIcon.icns`; generated by `scripts/make-icons.sh`.
- `scripts/build-dmg.sh` → `dist/WiredDisplay-<version>.dmg`: host app, Applications shortcut, audio driver with install/uninstall `.command` scripts (they ask for the admin password; the build never uses sudo), README, volume icon. Signed with the Apple Development identity; **not notarized**.
- **Verified:** icon compiled into the iPad app (`Assets.car`) and installed; glyph visible in the menu bar (streaming state); DMG mounts, app/driver/DMG signatures valid, `hdiutil verify` passes.
- **Fix (user report "icon is just black"):** the first iPad icon was all black — flattening to an opaque image through a 3-channel `NSBitmapImageRep` context renders nothing. Now flattened through a `CGContext` (RGB, no alpha), and `make-icons.swift` refuses to write a dark result. Verified: compiled iPad icon centre brightness 0.95; reinstalled on the iPad.

## CHANGE ID: P1-010 — Open at Login
- New `macOSHost/Host/LoginItem.swift`: registers the host as a login item with `SMAppService.mainApp`. It is switched on automatically the first time the host runs, and the menu has an "Open at Login" toggle to switch it off. The setting shows in System Settings › General › Login Items.
- A login launch has no command-line flags, so it uses the defaults, including touch input off (D-006). The host then waits for the iPad on USB and connects as soon as the WiredDisplay app is open on the iPad.
- Verified: status `enabled` (1), and `sfltool dumpbtm` shows `dev.wireddisplay.host` as `[enabled, allowed]`. Not yet verified: a real reboot or log-in cycle.

## CHANGE ID: P1-011 — iPad icon in Continuity style
- `scripts/make-icons.swift` has a new `drawContinuityIcon()` for the iPad icon, styled after Apple's Sidecar and Continuity icons. It draws white line art on a vivid blue gradient: an iPad in landscape with a translucent screen and a camera dot, and a USB-C plug in its side port. There is no cable, as the user asked. The macOS icon is unchanged.
- Installed on the iPad under the `…transportprobe` bundle ID, because free teams can create only 10 App IDs per 7 days.

## CHANGE ID: P1-012 — Secure channel, keyboard and trackpad, "more space" modes
- **Security (D-023, R-SEC-01):**
  - New `Shared/Session/SecureChannel.swift` and `TrustStore.swift`. Protocol version 2, and frames now carry the `authenticated` flag.
  - `FramedSocket` and the iPad session run the handshake. The host gates media and input on trust, and the menu gains "Paired: …", the connection code and "Forget Paired iPads…".
  - The iPad shows a pairing card with the code and lists paired Macs, with a Forget button.
  - 12 new tests.
- **Keyboard and trackpad (D-024):** new `KeyMap.swift`, with `InputEvent.key` and `.gestureScroll`. The host's `InputInjector` handles keys, modifiers, repeat and phased scroll. The iPad's `VideoView` handles key presses, trackpad clicks as real button presses, the hidden pointer and scroll momentum.
- **Display (D-025):** the shim accepts several modes (`modeSizes`). The host offers native, more and most, with more as the default and `--space` to choose; capture uses `scalesToFit`.
- **Verified on hardware:** a 1788×1340 main display; first pairing on both sides; encrypted streaming at about 42 fps (unchanged), 1.45 ms RTT and 0 drops.
- **Pending:** the user's test of keyboard and trackpad. Input is off by default; turn it on in the menu.

## CHANGE ID: P1-013 — Sidecar-style touch (D-026)
- `TouchInterpreter` rewritten to handle one finger only: tap = click, drag = scroll with fling, hold then drag = drag. New `EditGesture` (three-finger copy, cut, paste, undo and redo) and `PinchZoomStepper`.
- `VideoView`:
  - two-finger tap recognizer for right click;
  - pinch recognizer, running alongside the two-finger scroll;
  - new `ThreeFingerRecognizer`;
  - one-finger scroll reuses the trackpad momentum.
- 11 interpreter tests replace the old touch tests; all package tests pass. The iPad app is built and installed. Not yet tested by hand.

## CHANGE ID: P1-014 — iPad app UI redesign
- New `iPadOSClient/WiredDisplayClient/Sources/ClientUI.swift`: pure SwiftUI on plain values, so each state can be rendered for review on a Mac.
  - Waiting and connecting screen: a blue glow backdrop, the icon tile, a live status line and a three-step checklist that ticks as the connection progresses. A failure or the last disconnect reason appears in an orange callout.
  - Pairing screen: the code is shown as two groups of digit cells, with Pair and Don't Pair buttons.
  - Controls panel in grouped sections (Display, Audio, Touch, Security), with a status pill, a gesture reference, a confirmation before "Forget", and Reconnect.
  - A round controls button that dims while streaming.
- `ClientApp.swift` now only binds the session to those views. Behaviour is unchanged.
- All four states were rendered and reviewed. The app is built and installed on the iPad.

## CHANGE ID: P1-015 — Quality presets; reboot diagnostics; re-plug hint
- **Quality presets (D-027).**
  - New `QualityPreset` and `HostController.setQuality`.
  - Encoding split into `startEncoding` and `restartEncoding`, so the quality can change without recreating the virtual display.
  - Menu bar Quality submenu with a description under each preset; the choice is remembered.
  - Lane stats label single-lane modes "single-lane".
- **BUG-037 (iPad off the USB bus after a Mac reboot until re-plugged).**
  - Host: logs wait-state and USB-bus state changes (new `UsbRegistry.swift`, read-only IORegistry).
  - iPad: logs app activation, listener state and connection ends.
  - iPad: the waiting screen shows a re-plug hint after 20 s.
- **Display mode follow (bug the user found, 10:15).** The iPad kept showing "Looks like 1788 × 1340" after the user picked 1590 × 1192 in System Settings, and used the stale point size to scale scrolling.
  - Host: every 2 s it compares the display's bounds with the point size it sent, and resends `streamConfig` when the "looks like" size changed.
  - iPad: keeps its decoder when only the point size changes.
  - Verified: at relaunch macOS restored the remembered 1590 × 1192; the host corrected the iPad about 1 s after streaming started.

## CHANGE ID: P1-016 — Remembered input choice; real pinch/rotate; Control shortcuts; sharing package

**OBJECTIVE:** Make Magic Keyboard/trackpad input work after a restart, give pinch and rotate their real Mac behaviour, reach the Mac shortcuts iPadOS keeps, and package the app for sideloading by a friend.

**FILES CHANGED:** `macOSHost/Host/{main,HostController,InputInjector}.swift`; `Shared/Session/{Messages,TouchInterpreter,ShortcutRemapper}.swift`; `iPadOSClient/WiredDisplayClient/Sources/{VideoView,ClientUI}.swift`; `Tests/Unit/WDSessionTests/SecureChannelTests.swift`; `scripts/build-ipa.sh`; `docs/{DECISIONS,CHANGELOG}.md`; `docs/share/PANDUAN-INSTALASI.txt`.

**IMPLEMENTATION SUMMARY:** the menu's input choice is saved and reapplied at launch (D-028; menu item renamed "Allow Input from iPad (touch, keyboard, trackpad)"). New `magnify` / `rotate` input events, fed by UIKit pinch and rotation recognizers (touch and trackpad) through `TransformTracker`, posted on the Mac as undocumented type-29 gesture CGEvents, with the Command-plus/minus fallback (D-029). `ShortcutRemapper` sends Control-Tab, Control-Shift-Tab, Control-`, Control-Space and Control-Shift-3/4/5 as Command shortcuts, Control acting as Command until released (D-030); the iPad Controls panel lists them. `build-ipa.sh` builds an unsigned Release IPA for AltStore/SideStore; the shared DMG is signed ad hoc so it carries no Apple ID.

**VERIFIED:** unit tests pass (5 new). On hardware: input remembered across relaunch; pinch zoom and rotate work in Mac apps; Control-Tab (repeated while held), Control-Space, Control-Shift-4, Control-arrows work; Command-Tab/Space/Shift-3 with key-command priority did not reach the Mac (iPadOS keeps them). Not verified: AltStore install on another iPad; ad-hoc-signed audio driver on another Mac.

## CHANGE ID: P1-017 — Decode fallback per iPad; panel density

**OBJECTIVE:** Make WiredDisplay safe on iPads that cannot decode every format, and size the display right on iPad mini.

**FILES CHANGED:** `Shared/Session/{Messages,DecodeLimits}.swift`; `macOSHost/Host/{HostController,VirtualDisplayController,main}.swift`; `iPadOSClient/WiredDisplayClient/Sources/{ClientApp,ClientSession}.swift`; `Tests/Unit/WDSessionTests/SecureChannelTests.swift`; `docs/{DECISIONS,CHANGELOG}.md`; `README.md`.

**IMPLEMENTATION SUMMARY:** D-031. Protocol 3: `Hello.pixelsPerInch`, `ControlMessage.decodeFailed`. iPad: HEVC advertised only with hardware decode; renderer failures counted and reported. Host: per-iPad `DecodeLimits`, effective quality = preset within limits, live encoder restart, menu note, `--test-decode-fallback` diagnostic flag; display physical size from the reported ppi.

**VERIFIED:** 3 new unit tests pass. On hardware, `--test-decode-fallback` stepped 4:2:0 10-bit down to 8-bit with video continuing; limits reset and normal launch back at 10-bit. Not verified: an iPad that really fails to decode; iPad mini sizing.

## CHANGE ID: P1-018 — One-way audio devices (D-032)

**OBJECTIVE:** Make it impossible for call apps to pick the WiredDisplay audio devices the wrong way round (Google Meet report: no audio either way).

**FILES CHANGED:** `MacVirtualDevices/AudioDriver/WiredDisplayAudio.c`; `Shared/MacAudio/AudioDevices.swift`; `macOSHost/Host/HostAudioBridge.swift`; `macOSHost/Probes/wd-audio-probe/main.swift`; `docs/{DECISIONS,CHANGELOG}.md`.

**IMPLEMENTATION SUMMARY:** the driver's ring buffer and timing move into a shared `LoopbackChannel`; four devices (two visible one-way, two hidden one-way) point at the two channels. `AudioDevices.find` translates UIDs (works for hidden devices). The host records "iPad Speaker Tap" and plays into "iPad Microphone Feed". The probe tests each channel end to end.

**VERIFIED:** both loopback probes pass; device list correct; host bridges start on the taps. Diagnosis before the change: measured on hardware that the Mac side delivered the iPad microphone at −8 dBFS into "iPad Microphone" and nothing leaked into "iPad Speaker". Google Meet call (browser on iPad Microphone / iPad Speaker) confirmed working both ways by the user.

## CHANGE ID: P1-019 — iPad brightness from the Mac (D-033)

**FILES CHANGED:** `Shared/Session/{Messages,BrightnessStep}.swift`; `macOSHost/Host/{BrightnessKeys,HostController,main}.swift`; `iPadOSClient/WiredDisplayClient/Sources/{ClientSession,ClientApp,ClientUI}.swift`; `Tests/Unit/WDSessionTests/SecureChannelTests.swift`; `docs/{DECISIONS,CHANGELOG}.md`.

**IMPLEMENTATION SUMMARY:** `ControlMessage.brightness` both ways (protocol 4); host keeps the iPad's last value, steps it from the brightness keys (`BrightnessKeys` event tap) and a menu slider; iPad applies it to `UIScreen.brightness`, reports Control Center changes, shows a HUD.

**VERIFIED:** 2 new unit tests pass; host builds and its key tap starts ("brightness keys: listening"). On hardware: brightness keys and the menu slider change the real iPad brightness (user confirmed).

## CHANGE ID: P1-020 — Menu bar panel redesign; brightness keys on any keyboard

**OBJECTIVE:** A tidier, more detailed menu bar UI (user request, styled after a tabbed popover the user showed), and the brightness keys of a third-party keyboard reaching the iPad instead of BetterDisplay's software dimming.

**FILES CHANGED:** `macOSHost/Host/{StatusPanel,main,BrightnessKeys,HostController}.swift`; `docs/{DECISIONS,CHANGELOG}.md`.

**IMPLEMENTATION SUMMARY:** the NSMenu becomes an NSPopover with a SwiftUI panel: header (icon, status dot, connected time), icon tab bar (Display, Input, Audio, Security, General) over cards: resolution and codec, a full-width brightness slider, quality chips with descriptions, the input switch and shortcut list, audio status, the connection code and paired iPads, permissions with Grant buttons, Open at Login; footer Show Log and Quit. The host keeps a `SessionStatus` snapshot for it. `--render-panel <dir>` renders every tab (light and dark) to PNG for review. The brightness key tap moved to the HID level and also handles key codes 144/145; `--trace-keys` logs system-defined events and function keys (never letters or digits) for 10 minutes.

**VERIFIED:** panel rendered and reviewed in light and dark; on hardware the user confirmed the panel and that the ProtoArc K90 brightness keys now change the iPad's real brightness. **Incident:** while adding `--trace-keys` the host briefly rejected the new flag at launch (unknown option) and the iPad display was down for about 6 minutes; the parser now accepts it.

## CHANGE ID: P1-021 — Automatic headphone switching (D-034)

**FILES CHANGED:** `macOSHost/Host/{AudioRouter,HostController,StatusPanel,main}.swift`; `Shared/MacAudio/AudioDevices.swift`; `docs/{DECISIONS,CHANGELOG}.md`.

**IMPLEMENTATION SUMMARY:** `AudioRouter` listens for device-list changes and sets the default output/input on transitions only (headphones in: to them; out: back to the iPad devices if the iPad has that direction on; iPad direction on with no headphones: to the iPad). Headset microphones published as separate input-only devices (AirPods "<address>:input", USB-C "Headset") are paired by UID prefix or by arriving/leaving with a headphone output of the same transport. Panel Audio tab: "Switch to headphones automatically" (default on).

**VERIFIED (hardware):** USB-C "CtoL Audio" plugged in → output CtoL Audio and input its "Headset" mic; unplugged → iPad Speaker / iPad Microphone. AirPods 4 connected → output AirPods; disconnected → iPad Speaker.

## CHANGE ID: P1-022 — "Output only" for headphones

**FILES CHANGED:** `macOSHost/Host/{AudioRouter,StatusPanel,main}.swift`; `docs/{DECISIONS,CHANGELOG}.md`.

**IMPLEMENTATION SUMMARY:** panel switch "Use their microphone too" (`autoSwitchMicrophone`). Off: headset microphones are not selected, and when macOS moves the default input to one within 5 s of the headphones connecting, the router restores the iPad microphone (or the previous input).

**VERIFIED (hardware):** option off, iPad mic on, AirPods 4 connected → output AirPods 4, input moved back to iPad Microphone 50 ms later.
