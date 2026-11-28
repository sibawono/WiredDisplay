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

## CHANGE ID: P1-023 — One Sidecar-style icon everywhere

**FILES CHANGED:** `scripts/{make-icons.swift,make-icons.sh}`; `macOSHost/Resources/AppIcon.icns`; `iPadOSClient/WiredDisplayClient/Assets.xcassets/{AppIcon.appiconset,AppIconArt.imageset}`; `iPadOSClient/WiredDisplayClient/Sources/ClientUI.swift`; `docs/CHANGELOG.md`.

**IMPLEMENTATION SUMMARY:** the icon is now just a white iPad in landscape on the blue gradient, like the Sidecar icon (no plug or cable, user request). The Mac icon uses the same artwork inside the macOS squircle (it was still the older screen-and-cable design). The iPad splash/status screen and the Controls header show the icon itself (`AppIconArt` image, written by `make-icons.sh`) instead of an SF Symbol. The menu bar glyph is now an iPad in landscape with its home bar (screen filled while streaming), no plug.

**VERIFIED:** icons rendered and reviewed; iPad build contains `AppIconArt`; host smoke-tested and relaunched.

## CHANGE ID: P1-024 — 0.4.0: ProMotion, coexistence, local cursor, portrait, Metal, several iPads

**FILES CHANGED:** host (`HostController`, `HostFleet`, `CursorEcho`, `VideoEncoder`, `CaptureEngine`, `VirtualDisplayController`, `BrightnessKeys`, `AudioRouter`, `StatusPanel`, `main`), the display shim (serial number), shared (`Messages` protocol 6, `UsbmuxDevice.preferring`), iPad (`VideoView`, `ClientSession`, `ClientApp`, `ClientUI`, new `MetalVideoRenderer`), tests, docs (D-035–D-041), README, guide.

**SUMMARY:** D-036 refresh follows the iPad (120 Hz on ProMotion; standard rate control above 60 fps; the iPad requests a 120 Hz panel); every cabled device is tried, brightness keys follow the pointer, dock audio is not headphones. D-037 latency study (encoder saturated at 3180×2384; periodic keyframes removed; sent→enqueued measurement on the iPad). D-038 local cursor. D-039 portrait. D-040 Metal renderer (default). D-041 one controller per iPad with per-iPad display serials and single audio owner.

**VERIFIED:** unit tests pass; 120 Hz path end to end with `--force-refresh 120` (~119 fps); local cursor, portrait both ways, Metal renderer confirmed by the user on hardware; fleet with one iPad keeps serial 1 and streams normally. Not verified: a real ProMotion iPad; two iPads at once; Sidecar on a second iPad and DisplayLink alongside.

## CHANGE ID: P1-025 — v0.4.1 work: audit fixes and real on-glass measurement (D-042)

**FILES CHANGED:** `Shared/Video/HEVCSPS.swift` (new), `Tests/Unit/WDVideoTests/VideoTests.swift`, `iPadOSClient/WiredDisplayClient/Sources/{MetalVideoRenderer,ClientSession}.swift`, `macOSHost/Host/HostController.swift`, `docs/{DECISIONS,CHANGELOG}.md`, `docs/share/PANDUAN-INSTALASI.txt`, `README.md`.

**SUMMARY:** Metal decodes 4:4:4 as 4:4:4 (chroma and depth read from the HEVC SPS) and reuses the other lane's decoder; decode and presentation on separate queues with a generation fence; three drawables; config before capture, and an early frame is dropped instead of ending the session; a "metal on glass" meter. Display Zoom Default recommended.

**VERIFIED (iPad Air 13″, Pro preset, animation):** at Display Zoom Default (2732×2048) host encode p50 12.2 ms (16 at More Space), 60 fps on the glass, enqueue→glass p50 ~30 ms (~40 before); Balanced decodes "4:4:4 10-bit". The user judged the text sharper. Not released yet.

## CHANGE ID: P1-026 — v0.4.2 work: full-audit batch A (audio hand-back, settings, log, click)

**FILES CHANGED:** `macOSHost/Host/{AudioRouter,HostController,HostFleet,InputInjector,Log}.swift`, `docs/CHANGELOG.md`.

**SUMMARY:**
- When the iPad stops carrying audio (switched off, unplugged, app closed), a default output/input that is still "iPad Speaker" / "iPad Microphone" moves back to the last real device, else the built-in one. The session end now releases the audio owner, so another iPad can take audio over. Found by the audit: with no iPad attached, the Mac's input was still "iPad Microphone".
- An iPad plugged in after launch gets the menu's current input and quality choices, not the launch values. Before, input switched off after launch was on again for that iPad (D-006).
- Input logging: only clicks, gesture boundaries and releaseAll. Scroll and gesture steps are counted, not logged, and "input disabled" is logged once. The host log rotates at 5 MB into `WiredDisplayHost.old.log`; it had reached 7.8 MB.
- A short tap's mouse-up is posted 25 ms later from the session queue instead of `usleep` on it. Audio, control and other input no longer wait, and the next event posts a held-back up first, so order is kept.

**VERIFIED:** builds; unit tests pass; host relaunched; the log rotated at launch. Not verified on hardware yet: audio hand-back on unplug, short taps and double-clicks.

## CHANGE ID: P1-027 — v0.4.2 work: full-audit batch B (sharpness, latency, CPU)

**FILES CHANGED:** `macOSHost/Host/{VideoEncoder,HostController,HostAudioBridge,CursorEcho,AudioRouter}.swift`, `iPadOSClient/WiredDisplayClient/Sources/ClientSession.swift`, `docs/CHANGELOG.md`.

**SUMMARY:**
- Balanced with the local cursor: pointer movement no longer counts as motion, because the pointer is not in the video. The screen refines to 4:4:4 while the mouse moves.
- The host video queue holds at most 4 frames (was 6, ~100 ms at 60 Hz) before it restarts at a keyframe.
- Speaker bridge: the real-time IO thread only converts into a preallocated FIFO, using a try-lock and no allocation. A normal thread builds, encrypts and queues the packets.
- Cursor image: checked only while the pointer is on the iPad's display, with a cheap bitmap key. The PNG is made only on a real change. `resendImage` (dead code) is removed.
- iPad: frame counters are published to the UI once a second instead of on every frame.
- At host start, a leftover "iPad Speaker" / "iPad Microphone" default is moved to a real device (automatic switching on). The iPad takes it back when it connects.

**VERIFIED:** builds (host; iPad for generic iOS); unit tests pass; live session after relaunch: speaker FIFO 200 IO cycles/s with 0 overflows, packets reach the iPad; the stale default input moved off "iPad Microphone"; encode p50 ~12 ms (Pro). Not verified: the Balanced lane change by eye; the iPad build is not installed on the iPad yet.

## CHANGE ID: P1-028 — v0.4.2 work: second full audit, batch C (audio drift, typing, quit, build)

**FILES CHANGED:** `Shared/Session/AudioJitterBuffer.swift`, `Tests/Unit/WDSessionTests/SessionTests.swift`, `macOSHost/Host/{BrightnessKeys,main,AudioRouter,HostAudioBridge,HostController}.swift`, `iPadOSClient/WiredDisplayClient/Sources/ClientAudio.swift`, `scripts/install-ipad-app.sh`, `docs/CHANGELOG.md`.

**SUMMARY:**
- C-1 jitter buffer drift correction. Outside a band around the target (−50 %/+33 %), one frame per pull is repeated (too empty) or skipped (too full) until the level is back near the target. Found in client.log: latency wandered 19–84 ms, and slow drain caused an underrun (~30 ms gap) about every 10 minutes.
- C-5 two-pointer `pull` that builds no array. Used by both render callbacks (iPad speaker, Mac microphone).
- C-3 brightness keys use one shared event tap on its own thread, instead of one tap per iPad on the main thread. Every key press on the Mac had waited for the host's main thread.
- C-4 Quit hands the audio back synchronously, before and right before terminating.
- C-8 (found while testing) the "on USB" wait line is logged only when the device set changes. With a cabled device that does not run the app (an iPhone), it alternated with "nothing listens" and wrote 2 lines/s.
- C-2 `install-ipad-app.sh` builds Release by default (`CONFIG=Debug` to override).

**VERIFIED:** builds (host; iPad Release, installed); unit tests pass, including 3 new jitter-buffer tests (drain held without underrun, excess trimmed to the target, two-pointer pull); host relaunched, the brightness tap is listening and the log is quiet with the iPhone cabled. Cmd-click and Shift-click from the iPad trackpad confirmed by the user, so mouse events carry the modifiers (open audit item closed). Not measured yet: Debug vs Release latency on the iPad. The Debug baseline at idle is sent→enqueued p50 3.5–3.8 ms and decode p50 3.5 ms. Also not measured: the drift fix over a long session.

## CHANGE ID: P1-029 — v0.4.2 work: soak test and the remaining audit items

**FILES CHANGED:** `iPadOSClient/WiredDisplayClient/Sources/{VideoView,ClientApp,ClientSession,MetalVideoRenderer}.swift`, `Shared/Session/SecureChannel.swift`, `docs/CHANGELOG.md`.

**SOAK (30 min, iPad Air 13″ cabled, Release iPad build, test pattern every 5 min on the WiredDisplay screen):**
- Host RSS 42–66 MB with no growth; 16–19 threads; CPU 2–4 % streaming, up to 13 % during motion. The log grew ~5 KB/min.
- 0 video frames dropped; control RTT ~1.1 ms; encode p50 11–13 ms. On the glass: 60 fps, enqueued→glass p50 ~29–31 ms during 60 fps motion.
- Some test-pattern runs were captured at only ~37 fps. Capture and encode counts match, so the test window drew fewer frames; the pipeline did not drop any.
- Audio: 1 underrun in 30 min (the buffer was at 1320 frames just before, so this was a delivery gap, not drift); 813 drift corrections.
- "sent->enqueued" climbed 1.2 ms per minute: the Mac and iPad clocks drift ~20 ppm apart, and the offset estimate never forgot old samples. A diagnostic artefact, fixed below.

**SUMMARY:**
- C-6: every pointer position the iPad sends is echoed locally (drags, trackpad clicks, touches), not only hover.
- C-7: the loopback echo server (port 9000) runs only with `-diagnosticEcho YES`.
- Clock offset for the latency diagnostics: max over the last 8 pings, cleared on every connection.
- Metal: 4:2:0 chroma is sampled at its real position (left-sited; VTPixelTransfer was probed and point-samples the even column), and the texture cache is flushed every 300 frames and on flush.
- SecureChannel: separate send and receive locks, so sealing a frame never waits for opening one.

**VERIFIED:** builds (host; iPad Release, installed); all unit tests pass (including SecureChannel). Not verified by eye yet: cursor during drag, colour edges in Pro. Bitrate scaling at 120 Hz is left open; it needs a ProMotion iPad to test.

**NOTE (future quality work):** the 4:2:0 conversion point-samples chroma, so the colour of a 1-pixel detail on an odd column is lost. A filtered (e.g. [1 2 1]) GPU conversion on the host could make Pro's coloured text edges cleaner.

## CHANGE ID: P1-030 — Filtered 4:2:0 chroma on the GPU (Pro and Balanced motion lane)

**FILES CHANGED:** `macOSHost/Host/ChromaConverter.swift` (new), `macOSHost/Host/{VideoEncoder,main}.swift`, `docs/CHANGELOG.md`.

**SUMMARY:** the 4:2:0 lanes convert BGRA with a Metal compute kernel instead of VTPixelTransferSession. A probe showed VTPixelTransfer point-samples chroma: a 1-pixel red line on an odd column lost its colour completely, and on an even column it kept all of it, so coloured text edges were ragged. The kernel uses a [1 2 1]/4 horizontal filter centred on the even column (left-sited, as the iPad renderer assumes) averaged over the two rows. Colour maths are unchanged: matrix only, sRGB-encoded values, BT.709 video range; the buffers are tagged 709 and Left. VideoToolbox remains the fallback if the GPU path fails. `--chroma-filter off` turns it off for A/B tests. The lane statistics now log the conversion time, which had not been measured before.

**VERIFIED:**
- Against VideoToolbox on 9 flat colours, 8- and 10-bit: at most 1 code apart.
- 1-pixel red line on an odd column: chroma Cr 28 / 28 (8-bit) where VideoToolbox gave 0.
- Live A/B, Pro, 60 fps test pattern: conversion p50 VideoToolbox 4.65–5.42 ms, GPU 3.87–4.11 ms (p95 5.3–6.6 vs 4.2–4.6). Encode p50 unchanged at ~12 ms; 60 fps.
- Not judged by eye yet: coloured text edges in Pro.

## CHANGE ID: P1-031 — Host panel: Liquid Glass, compact

**FILES CHANGED:** `macOSHost/Host/{StatusPanel,main}.swift`, `docs/CHANGELOG.md`.

**SUMMARY:** every panel element uses Liquid Glass on macOS 26+, all inside one `GlassEffectContainer`:
- Header, cards, quality chips, link row and footer buttons: glass surfaces.
- Tab bar: a glass capsule. The selected tab is a tinted glass capsule that morphs between tabs (`glassEffectID`).
- On/Off pills, shortcut key caps and the version badge: glass. The Grant and Forget buttons use the `.glass` button style.

Before macOS 26 the previous fills and hairlines remain. The panel is more compact: 320 pt wide instead of 360, tighter padding and smaller rows; the Display tab is 646 pt tall instead of 810. In dark mode the selected tab icon and the selected quality chip are white instead of accent blue, because blue blended into the dark glass (user feedback). New `--render-panel-live <dir>`: Liquid Glass does not render offscreen, so this shows each tab in a real window and captures it with ScreenCaptureKit. Launch it with `open -n … --args` so the app's own Screen Recording permission applies.

**Native controls (user request, same change):** the tab bar, the Quality picker, the switches and the brightness slider are AppKit's own controls: `NSSegmentedControl`, `NSSwitch` and `NSSlider` in `NativeControls.swift`. On macOS 26 they bring the system Liquid Glass behaviour themselves: the knob or thumb becomes a glass lens while held, and the segment selection slides as glass. A SwiftUI restyle does not reproduce that. The link and footer buttons use the native `.glass` button style. Quality is now one segmented control; the format is shown in the line below it.

**Reference layout (user request, same change):**
- Icon tabs in one rounded glass container. The selected tab sits on a tinted glass rounded square that slides to the tab you pick (`matchedGeometryEffect`, spring).
- The tab name is shown in capitals above the content.
- Quality is a row of four glass pills.
- The link and footer buttons are rounded-rectangle glass.
- Switches and the brightness slider stay native `NSSwitch` / `NSSlider`, for the system glass lens while held. The native segmented control was used briefly and is no longer used.

**VERIFIED:** builds; live renders of all 5 tabs, light and dark. The render window is inactive, so switches and glass tints appear grey. Not checked yet: tints, the tab slide and the press and drag glass lens in the real menu-bar popover.

## CHANGE ID: P1-032 — Host panel follows the macOS 27 UI kit (Figma community)

**FILES CHANGED:** `macOSHost/Host/StatusPanel.swift`, `docs/CHANGELOG.md`.

**SUMMARY:** every element follows the components in the macOS 27 community kit. The specs were read from its Segmented Controls, Group Boxes, Buttons, Toggles and Popovers pages.
- **Cards and header:** kit Group Box, a flat quaternary fill with 12 pt corners and no border. No glass surfaces.
- **Tab bar:** kit "Utility Panel Tab Bar" (Toolbars page). Each tab is a 44 × 30 pt button; the selected one stands on a small Liquid Glass plate with 9 pt corners, and the glyphs keep the label colour. The buttons are spread evenly across the panel width (user request: balanced layout). Switching is instant, with no animation (user request).
- **Quality:** the native NSSegmentedControl, which is the kit component.
- **Link, footer, Grant and Forget buttons:** native bordered push buttons.
- **Switches and the brightness slider:** native NSSwitch and NSSlider.
  - Kit Toggles page: when pressed, the 32 × 20 knob becomes a 50 × 31 glass lens that overflows the 54 × 24 track.
  - SwiftUI's representable host clipped it, so not every toggle showed the glass (user report).
  - Fix: the switch sits in an unclipped container with 14 pt of room, and clicks in that room fall through.
  - Kit Sliders page: the slider knob also becomes a larger glass lens when clicked (25 × 20 pt). The slider gets the same treatment, with 10 pt of room.
  - Layout: the first version took the room back with negative padding, which truncated the toggle descriptions to one line (user report). The switch and slider are now laid out at their own size, with the lens room drawn outside that frame, and the descriptions always wrap.
  - Self-check in the real popover (new `--self-check-panel <dir>`): it opens the popover, captures every tab, and presses a switch and the slider with real mouse events. The slider knob turned into a larger lens, unclipped. The hosted NSSwitch toggled without ever showing a lens, so the switches are SwiftUI's own `Toggle(.switch)` at the regular size: the system switch without a representable wrapper, no `.controlSize(.small)`. The lens has to be checked by hand, because synthetic clicks skip the press-and-hold phase.
  - Captions wrap to their full height (`fixedSize(vertical:)`); in the popover they were truncated to one line. A root-level `fixedSize` was tried first, but it broke the popover's size and position (it opened above the screen, user report), so it was reverted.
- **Quality:** the selected segment uses the accent colour (`selectedSegmentBezelColor`), as in the kit; AppKit's default in the popover was grey.
- **On/Off pills and key caps:** flat kit fills.

This replaces the glass and reference styling of P1-031.

**VERIFIED:** builds; live renders of all 5 tabs, light and dark. The render window is inactive, so the native controls draw their inactive (white or grey) look. Not checked yet in the real popover.

**Popover position (P1-032 follow-up):** the popover was placed for a 320 pt content size and then grew upward past the menu bar: its top at y 1697 on a 1440 pt screen (user report). It is now sized to its content before showing (`fittingSize`), and `sizingOptions = .preferredContentSize` keeps it in step when a tab changes height. Measured after the fix: top at y 1414, directly under the menu bar (visible area ends at 1410).

**Switch (P1-032 follow-up):** the system switch never showed its glass lens in the popover (user report), so the toggles are a SwiftUI `KitSwitch` drawn to the kit's "Toggles - Switches" spec:
- 54 × 24 track (accent when on, primary at 10 % when off) and a 32 × 20 white knob.
- While pressed, the knob becomes a 50 × 31 `.glassEffect(.clear.interactive())` lens that overflows the track and follows a drag.
- On release it toggles (tap) or settles on the side it was dragged to.
- Accessibility: it is announced as a toggle with an On/Off value.

**Quality picker:** 11 pt labels, each with an SF Symbol: Balanced `circle.lefthalf.filled`, Pro `bolt.fill`, Ultra `sparkles`, High Color `paintpalette.fill` (user request).

**Panel as clear Liquid Glass (user request, with the system menu bar menus as reference):** `GlassPopover.swift` replaces NSPopover, whose material was much more opaque. It is a borderless key panel at menu level, with an `NSGlassEffectView` (clear style, 18 pt corners) on macOS 26+ and the popover material before. It opens 6 pt under the status item, clamped to the screen, and follows the content’s preferred height with its top edge fixed. A click in another app or Escape closes it, and so does the status item. Not judged by eye yet; the window-only capture cannot show the glass over the desktop.

**Section backgrounds on the clear panel (user request):** each card and the header sit on a lighter layer: white at 45 % (10 % in dark mode) with a 0.5 pt white hairline and 12 pt corners, like the top section of the system display menu.

**Readability fix:** the clear glass and the 45 % section layers left the text unreadable over a busy wallpaper (user report). The panel now uses regular glass, and the sections the window background colour at 75 %.

## CHANGE ID: P1-033 — Native pixel mapping and freshest-frame presentation

**SUMMARY:** Default the virtual display to Native @2x. More and Most Space remain selectable. On the 13-inch iPad Air, Native renders 1366×1024 points at 2732×2048 pixels; More Space renders 1536×1152 points at 3072×2304 and ScreenCaptureKit scales that raster to 2732×2048. Metal sizes the drawable using the screen's native scale and uses direct texel reads for pixel-matched luma and full-resolution chroma. Scaled video retains aspect fit, and 4:2:0 chroma retains interpolation at the signalled sample position. The draw queue coalesces pending frames and takes the latest decoded frame after drawable acquisition.

**VERIFIED:** Host build and 146 Swift tests passed; host built, installed, and restarted. The Release iPad app installed and launched on the USB-connected iPad. The production shader preserved all 3,072 black/white pixels of an offscreen checkerboard on the Mac GPU.

**REAL DEVICE A/B:** Used the same moving pattern and HEVC 4:4:4 8-bit preset on the iPad. Screenshots were 2732×2048 in both modes. In a 32×32 crop of the one-pixel checkerboard, More Space produced only midtones (sRGB red channel 122–131). Native preserved all 1,024 positions with 512 dark (≤16) and 512 light (≥239) samples. In steady motion, Native presented 60.0 fps for three consecutive five-second windows; More Space presented 59.6–59.8 fps. Host encode p50 was 8.0–9.5 ms in Native, compared with 11.6 ms in the first full motion window in More Space. Conversion p50 was 2.1–2.3 ms versus 3.9 ms in that window.

**LATENCY LIMIT:** Native client enqueued-to-glass latency was p50 46.6–48.1 ms and p95 50.1–50.6 ms in the steady windows. More Space had p50 28.3–42.4 ms and p95 45.7–47.7 ms. There were zero pending-frame replacements during steady motion in either run, so these runs do not show the effect of coalescing under drawable contention. End-to-end input latency and a direct Studio Display match were not measured.

## CHANGE ID: P1-034 — Measure iPad presentation latency by stage

**SUMMARY:** The Metal renderer logs five-second p50/p95 windows for enqueue-to-decode completion, decode completion to submission, CPU time waiting for `nextDrawable()`, command-buffer GPU execution, and submission to actual drawable presentation. Drawable wait overlaps decode-to-submit, and GPU execution is part of submit-to-presentation. GPU samples are capped if presentation callbacks stop. Frame scheduling and pixel mapping are unchanged.

**REAL DEVICE:** Two USB runs on iPad Air 13-inch, Native @2x at 2732×2048, HEVC 4:4:4 8-bit, using scripted typing, scrolling 13 pt text, and moving a window. In the full steady windows below, the two runs showed:

| Workload | Presented fps | Enqueue to glass p50 / p95 | Submit to glass p50 | Drawable wait p50 |
| --- | ---: | ---: | ---: | ---: |
| Typing | 6.8–8.0 | 25.5–27.7 / 30.5–37.2 ms | 20.7–22.9 ms | 0.04–0.06 ms |
| Scrolling | 59.8–60.0 | 33.6–50.2 / 34.9–52.3 ms | 28.5–32.4 ms | 0.04–12.84 ms |
| Moving a window | 55.4–55.6 | 42.9–44.3 / 47.7–48.0 ms | 32.2–32.4 ms | 5.44–7.29 ms |

GPU execution p50 stayed below 1 ms and decode p50 was about 4–5 ms. The largest measured interval was submission to presentation; the metric includes command scheduling, GPU execution, and system presentation. Keypress-to-photon latency was not measured.

**VERIFIED:** Host build, all 146 Swift tests, host installation/restart, and Release iPad installation and launch. Both USB runs returned the new timing breakdown.

## CHANGE ID: P1-035 — Compare CAMetalDisplayLink with on-demand Metal presentation

**EXPERIMENT:** On the USB-connected 13-inch iPad Air, alternated A/B/A/B with Native @2x at 2732×2048 and HEVC 4:4:4 8-bit. A used the existing on-demand Metal renderer. B used `CAMetalDisplayLink` at 60 Hz and preferred frame latency 1, using the drawable supplied by each update and selecting the newest decoded frame. Each run used the same scripted typing, text scroll, and moving-window workload.

| Workload | A — displayed FPS | B — displayed FPS | A — enqueue-to-glass p95 | B — enqueue-to-glass p95 |
| --- | ---: | ---: | ---: | ---: |
| Typing | 6.7–8.0 | Sparse updates | 34.2–36.2 ms | 49.3–52.1 ms |
| Scrolling | 59.6–60.0 | 52.2–58.4 | 36.3–37.9 ms | 53.2–53.3 ms |
| Moving window | 54.2–55.0 | 52.0–55.2 | 45.2–47.9 ms | 50.3–52.6 ms |

Rows use complete or nearly complete five-second workload windows. B removed the explicit `nextDrawable()` wait, but decode-complete to submission p50 while scrolling rose from 0.33–0.69 ms to 14.30–15.37 ms. Submission to actual presentation remained around 32 ms in B. The two displayed checkerboard screenshots both preserved all 1,024 black/white positions in the sampled region.

**OUTCOME:** Kept the on-demand renderer and restored the exact pre-experiment source. Retained the Native @2x rendering and per-stage diagnostics. Host build, 146 Swift tests, host installation/restart, and iPad Release install/launch were verified after restoration.

## CHANGE ID: P1-036 — Recover text-edge contrast in More and Most Space

**SUMMARY:** Enable a contrast-gated four-neighbour luma filter in the iPad Metal renderer when the Mac renders an oversized HiDPI desktop and the video matches the iPad drawable pixel for pixel. Strength increases with the overscale ratio and is bounded, and output luma stays within the local input range. Chroma sampling and Native @2x keep their previous paths. The diagnostic launch argument `--disable-scaled-text-detail` provides the unfiltered comparison in the same build.

**REAL DEVICE:** Verified the actual backing sizes during each run on the 13-inch iPad Air (264 PPI, 2732×2048 at 60 Hz, HEVC 4:4:4 8-bit). Used fixed 9–19 pt black, red and blue text, plus black text scaled by the logical-width ratio for like-for-like physical size. RMS adjacent-pixel luminance gradient on the screenshot text crops increased as follows:

| Mode | Desktop backing raster | Same point sizes | Matched physical size | Displayed FPS with filter |
| --- | ---: | ---: | ---: | ---: |
| More Space, 1536×1152 | 3072×2304 | +7.5% | +8.2% | 59.6–59.8 |
| Most Space, 1708×1280 | 3416×2560 | +13.0% | +13.2% | 60.0 |

Median GPU work increased by about 0.5 ms. Enqueued-to-glass p95 was 42.5–42.9 ms in More Space and 41.5–43.7 ms in Most Space in the steady moving-pattern windows. RMS gradient measures local contrast, not glyph fidelity; detail removed by the host's downscale remains unrecoverable. Native preserved all 1,024 positions in the physical iPad checkerboard crop and all 3,072 pattern pixels in an offscreen GPU test. The Native control run had about 52 fps of host capture from this pattern, so it served as a pixel-fidelity check.

**VERIFIED:** Host build and all 146 Swift tests passed. Host installed and restarted. Release iPad build installed, launched, and tested in all three modes. The virtual display was returned to Native after the test.

## CHANGE ID: P1-037 — Display-space selector in the Mac host panel

**SUMMARY:** Added Default, More Space, and Most Space to the Display tab below “Looks like.” The selection reflects the resolution macOS reports, including a mode selected in System Settings. The action targets the focused iPad’s virtual display, matches the current refresh rate, and is unavailable for the main display or a mirrored arrangement. It applies the mode for the current display session and sends the updated logical size through the existing stream configuration path.

**VERIFIED:** Host build and all 146 Swift tests passed. The host was installed, restarted, and reconnected to the iPad. Rendered the Display tab in light and dark. A hardware harness using the same CoreGraphics mode-selection code switched the active iPad through 1366×1024, 1536×1152, and 1708×1280 at 60 Hz and restored 1366×1024. The live host observed the changes and sent the updated sizes without reconnecting. The menu-bar button interaction itself was not verified because desktop automation timed out.

## CHANGE ID: P1-038 — Measure host capture callback and compare queue depths

**SUMMARY:** Added five-second capture callback duration statistics (p50, p95, maximum, and count above a 16.67 ms frame period). Compared ScreenCaptureKit queue depths 4 and 2 on a USB-connected iPad at Native @2x, HEVC 4:4:4 10-bit, using an 18-second constant-speed window movement driven by the Mac display link. Retained queue depth 4 after the experiment.

**REAL DEVICE:** With depth 2, capture ran at 59.2–59.8 fps. The first run included an iPad window at 54.0 fps and enqueue-to-glass p95 64.8 ms. The repeat presented 59.2–59.4 fps with p95 46.5–46.6 ms. With depth 4 restored, the iPad presented 59.0–59.8 fps with p95 42.9–43.1 ms in steady windows. Capture callback p95 was 6.02–6.38 ms with depth 4; none of 897 sampled callbacks exceeded 16.67 ms. These runs do not demonstrate a consistent latency benefit from reducing capture depth.

**LIMITS:** The earlier sinusoidal movement workload still produced about 53 fps at capture and 52 fps on the iPad. The constant-speed workload is a different input, so its higher frame rate does not establish an application performance improvement. Keypress-to-photon measurement still requires optical recording.

**VERIFIED:** Host build and all 146 Swift tests passed after restoring depth 4. Host installed, restarted, and streamed the physical test successfully.

## CHANGE ID: P1-039 — Correlate capture delivery with actual iPad presentation

**SUMMARY:** Record the host-clock time when ScreenCaptureKit delivers a frame. Keep that time with the source through still-frame refinement. Sample encoded outputs and correlate their existing wire timestamps with iPad drawable presentation callbacks. Host samples report capture delivery to conversion, conversion, and encode/pack time. Client samples report wire submission to enqueue (including queueing, encryption, USB, decryption and parsing), decode, submission, and actual presentation. SessionFramer and FramedSocket accept an optional explicit timestamp, with existing clock-based behaviour retained for callers that omit it. The existing framing test now verifies both timestamp paths and independent stream sequences.

**REAL DEVICE:** USB iPad Air 13-inch, Native @2x, HEVC 4:4:4 10-bit. Used scripted typing, text scrolling, sinusoidal window movement, then constant-speed display-link-driven window movement.

| Workload | Matched displayed frames | Capture delivery → glass p50 / p95 |
| --- | ---: | ---: |
| Typing | 17 | 66.1 / 90.5 ms |
| Text scroll | 18 | 57.1 / 57.8 ms |
| Sinusoidal movement | 22 | 56.7 / 72.7 ms |
| Constant-speed movement | 35 | 56.4 / 89.7 ms |

During scrolling, sampled medians were 0.05 ms capture-delivery-to-conversion, 4.13 ms conversion, 10.66 ms encode/pack, 0.93 ms submission-to-enqueue, 4.53 ms decode, 3.75 ms decoded-to-submission, and 32.45 ms submission-to-glass. Stage medians are reported individually and do not sum to the median total. The largest sampled interval was submission-to-presentation. Constant-speed movement included a presentation stall with 28 superseded pending frames in one five-second window. The steady windows presented 59.0–59.6 fps; the sinusoidal workload included 55.4 fps.

**MEASUREMENT BOUNDARY:** Both ScreenCaptureKit presentation timestamps and displayTime metadata could lead the host callback clock on this machine. The final measurement therefore starts at callback delivery, not the original WindowServer update or physical input. Cross-device intervals use the existing recent-ping clock-offset estimate and have clock-sync uncertainty. Sparse per-frame samples and short workloads do not establish sustained latency. Physical keypress-to-photon measurement remains unverified.

**VERIFIED:** Host build and all 146 Swift tests passed. Host installed and restarted, iPad Release build installed and launched, and correlated samples were obtained for every workload.

## CHANGE ID: P1-040 — Bilingual WiredDisplay landing page

**SUMMARY:** Recreated the public Dinta landing-page styling for WiredDisplay using its base stylesheet, blue gradient headline, rounded download buttons, and product sections. Added Indonesian and English pages, a workspace-size demo, setup guidance, and FAQ. The hero and a dedicated audio section explain using the iPad speakers as Mac output and the iPad microphone as Mac input. Downloads point to existing v0.4.2 release assets. The development panel screenshot is labelled.

**DELIVERY:** Source is in the separate website directory of the current Mac host & iPad workspace. Published to Cloudflare Pages at https://wireddisplay.pages.dev/ and /en/. Registered the owner's custom domain. Custom-domain activation awaits a DNS CNAME to wireddisplay.pages.dev; the available Cloudflare session has Pages deployment access but no DNS write scope.

**VERIFIED:** Browser checks on the deployed Indonesian and English pages, mobile navigation and language switch, resolution-demo controls, FAQ expansion, internal assets/anchors, and JavaScript syntax. No browser-console errors were observed. No app binaries were changed for this website.


## CHANGE ID: P1-041 — Product-page redesign and bilingual inline CMS

**SUMMARY:** Rebuilt the website around the observed Apple product-page structure: sticky product navigation, large product imagery, horizontal highlight and detail galleries, plus-button dialogs, audio selection, and a scroll-driven USB explanation. Added family coverage for iPad, iPad mini, iPad Air and iPad Pro while retaining physical-testing limitations. Removed the interactive iPad-resolution demo at the owner's request.

**ASSETS:** Used the owner-supplied Mac mini photograph. Portrait and landscape mockups contain actual macOS TextEdit captures with a public sample document. Audio graphics use cropped native Sound settings rows for iPad Speaker and iPad Microphone, excluding account and personal device details. Apple bezel resources were used after explicit owner acceptance of the license. Standalone resources remain outside the deployment; website mockups are flattened PNGs. Inspected the Shakuro Figma reference for composition; no Figma assets were exported because export required login.

**CMS:** Added a Dinta-style inline editor with separate Indonesian/English content, D1 persistence, signed HttpOnly sessions, salted password hashes, login rate limits, same-origin writes, URL/field validation, JSON export, and revision-conflict detection. Fixed activation links opened in an existing admin tab by handling fragment changes. The owner activated the production administrator and opened the authenticated editor. Actual production content publishing remains untested; both language revisions were zero at verification.

**DELIVERY:** The custom domain and /en/ are live with HTTPS. CMS is at /admin/. Latest deployment: https://88e618b1.wireddisplay.pages.dev/. Website source, build scripts, tests and local source assets remain in the separate website directory of the Mac host & iPad workspace.

**VERIFIED:** Pass A: site build, JavaScript syntax, SQLite-backed Worker integration test covering setup/authentication/persistence/language isolation/conflicts and invalid requests, local links/assets and personal-identifier scan. Pass B: browser checks of public custom domain, native screenshot mockups, desktop/local 390 px layouts, ID/EN navigation, detail modal, keyboard audio selection and the authenticated inline CMS. No broken images or horizontal page overflow were observed in checked layouts. Physical portrait behavior on every iPad was NOT RUN. No app binaries changed; no Git commit, push, or GitHub release was made.


## CHANGE ID: P1-042 — Keep the hero composition inside desktop and mobile bounds

**SUMMARY:** Replaced independent rotated device layers with one bounded 2400×1680 product composition using the same actual macOS captures and owner-provided Mac mini photo. The iPad frames retain their image proportions, and the image scales as one unit. Desktop image width follows viewport height so every device is visible in the initial viewport. Mobile uses 92% of the page width. The following heading has a separate layout boundary and 28 px gap. The first highlight card also uses the bounded composition. Image/link CMS field keys now derive from their default URL to prevent unrelated image-order changes from reassigning keys. Both production language revisions were still zero before this schema update.

**VERIFIED:** Pass A: image export, site build and SQLite-backed Worker test passed. Pass B: browser checks at 1280×720 and 390×844 found the complete hero within the initial viewport, no horizontal page overflow and a 28 px gap before the following text. Verified the new image loaded at 2400 px natural width on the public custom domain. Deployment: https://cd560cae.wireddisplay.pages.dev/. No app binaries, commits, pushes or GitHub releases changed.

## CHANGE ID: P1-043 — "More/most space" downscaled with an area filter on the host (closer to native @2x)

**FILES CHANGED:** `macOSHost/Host/{ChromaConverter,VideoEncoder,HostController,main}.swift`, `docs/CHANGELOG.md`.

**SUMMARY:**
- In "more/most space" the virtual display renders at 2× a point size larger than half the panel (framebuffer 3072 × 2304 or 3416 × 2560 for a 2732 × 2048 panel). ScreenCaptureKit used to scale that to the panel with its own fixed scaler. The host now captures the full HiDPI framebuffer and does the downscale itself.
- 4:2:0 lanes: `ChromaConverter` resamples every output pixel with an area (box) filter, the coverage-weighted average of the source pixels it covers, in the same pass as the colour conversion. At scale 1 it reads the pixel as before.
- 4:4:4 lanes: VideoToolbox scales with `kVTDownsamplingMode_Average`.
- When it applies: only when the framebuffer is larger than the panel with the same aspect (not when mirroring another display) and every lane converts from BGRA (all presets).
- A "looks like" change during a session restarts the capture at the new framebuffer size.
- `--own-downscale off` restores ScreenCaptureKit scaling for A/B tests. The encoded size and bitrate are unchanged.

**VERIFIED:**
- Kernel tests (standalone harness):
  - Same-size flat colours: at most 1 code from VideoToolbox, unchanged; the 1-px red line keeps its chroma (Cr 28/28).
  - Downscales of 1.25× (most) and 1.125× (more): 0 codes from a CPU area-filter reference, and grey stays neutral.
- `swift test`: all suites pass. The host is built, installed and relaunched.
- **Live, iPad Air 13″ portrait in most space** (1280 × 1708 pt, framebuffer 2560 × 3416 → encode 2048 × 2732, Pro preset, 20 s test pattern, several runs):
  - Capture fps: own downscale on, 58.8–59.8 fps steady in two runs; off, 59.0–59.8 fps. No frame drops.
  - Conversion p50: on, 1.2–3.4 ms; off, 3.9–4.9 ms. The spread comes from the GPU's power state, not the downscale.
  - Encode p50: about 12 ms either way.
  - A "looks like" change restarts the capture at the right size in both directions (native to most, and back).
  - The first run saw only 35–44 fps; it was the test window, as in earlier soaks.
- Judged by eye on the iPad in most space: sharper than ScreenCaptureKit's scaling (user confirmed).
- The iPad's contrast filter for oversized desktops (P1-036) still runs on top of this host downscale. The user's judgement was made with both.

## CHANGE ID: P1-044 — Sleep, wake, lock and screensaver handling (audit PLW-01…07)

**FILES CHANGED:** `macOSHost/Host/{PowerMonitor (new),HostController,InputInjector,VideoEncoder,main}.swift`, `docs/POWER_LOCK_WAKE.md` (new), `docs/CHANGELOG.md`.

**SUMMARY:**
- `PowerMonitor` tracks system sleep, display sleep, lock, screensaver and user switching as independent states. It reconciles them every 2 s against the session dictionary and the running ScreenSaverEngine.
- Display sleep no longer ends the session or destroys the display. The iPad gets a black keyframe, and the capture restarts on wake or after a bounded backoff.
- System sleep closes the session cleanly and pauses reconnects until wake.
- iPad input while locked or in a screensaver: pointer moves only. Clicks and keys are dropped, and anything held is released.
- The "looks like" space is remembered per iPad.

**VERIFIED:** `swift test` 146/146. Physical:
- Display sleep 20/20: 0 sessions ended (21 before the fix); recovery p50 86 ms, p95 312 ms.
- Lock: the iPad showed the lock screen, no desktop.
- System sleep: picture back 2.4 s after wake.
- Screensaver: dismissed by a move on the iPad.
- Space remembered across display recreation.

**NOT RUN:** the 20-cycle lock/sleep/screensaver series and a 2-hour soak. Details are in `docs/POWER_LOCK_WAKE.md`.

## CHANGE ID: P1-045 — High-risk review of b6944b0: frame kept without a drawable, capture-restart loop guard

**FILES CHANGED:** `iPadOSClient/WiredDisplayClient/Sources/MetalVideoRenderer.swift`, `macOSHost/Host/HostController.swift`, `Shared/Session/QuickFailureCounter.swift` (new), `Tests/Unit/WDSessionTests/QuickFailureCounterTests.swift` (new), `docs/HIGH_RISK_REVIEW.md` (new), `docs/CHANGELOG.md`.

**SUMMARY:**
- HR-01: when there is no drawable, the iPad renderer keeps the decoded frame and retries, up to 10 × 50 ms. Before, it dropped the frame, so a still desktop could stay on an older picture.
- HR-02: a capture that stops again within 2 s of every recovery backs off (0.5, 1, 2 s), and the 4th time the session ends. Before, it restarted without end. Display-sleep stops are unaffected.
- HR-03: capture recovery is tied to its session; `stopVideo` clears the recovery state.

**VERIFIED:**
- `swift test` 152/152. Host build has no warnings; iPad Release build succeeded.
- Physical: 5/5 display-sleep cycles recovered on the first attempt, no session ended.

**NOT RUN:** the quick-stop loop on hardware (it needs TCC withdrawn), a nil drawable on the iPad, a 2-hour soak. Details are in `docs/HIGH_RISK_REVIEW.md`.


## CHANGE ID: P1-046 — Paired iPads show the device name and model

**FILES CHANGED:** `Shared/Usbmux/Lockdown.swift` (new), `Shared/Session/TrustStore.swift`, `macOSHost/Host/{HostController,StatusPanel,main}.swift`, `Tests/Unit/WDUsbmuxTests/LockdownTests.swift` (new), `docs/CHANGELOG.md`.

**SUMMARY:**
- Every paired iPad was listed as "iPad". Since iPadOS 16, `UIDevice.current.name` returns only the generic name.
- The host now reads `DeviceName`, `ProductType` and `DeviceClass` from the iPad's lockdownd over the same USB mux (port 62078, `GetValue`, no pairing session needed; measured on iPadOS 27.3). It shows "Alex’s iPad" with "iPad Air 13-inch (M2) · Key 0d7238ca".
- An unknown identifier shows as the identifier itself.
- The model is stored with the trusted peer (an optional field, so old entries still decode).
- A peer paired earlier keeps showing only its key until it connects again.
- The status line uses the same name.

**VERIFIED:**
- `swift test` 156/156 (4 new).
- Physical: the log shows "iPad identity: model iPad14,10 (iPad Air 13-inch (M2))".
- The live panel render shows the new row.

## CHANGE ID: P1-047 — Audit A–F: teardown audio race, open gestures, bounded capture query, parallel identity read

**FILES CHANGED:** `macOSHost/Host/{HostController,InputInjector,CaptureEngine}.swift`, `Shared/Session/GestureTracker.swift` (new), `Tests/Unit/WDSessionTests/GestureTrackerTests.swift` (new), `docs/AUDIT_A_F.md` (new), `docs/CHANGELOG.md`.

**SUMMARY:**
- AUD-01: session teardown closes the socket first, so a late audio route can no longer start the speaker or microphone after `stopAll`.
- AUD-02: `releaseAll` ends trackpad scroll, momentum, pinch and rotate gestures that were left open.
- AUD-03: the shareable-content query is bounded to 5 s, so it cannot hang the video queue.
- AUD-04: the lockdownd identity is read in parallel with the handshake, with at most 1 s of waiting.

**VERIFIED:**
- `swift test` 161/161.
- Host reinstalled: session up; 3/3 display-sleep cycles recovered.

**NOT RUN:** AUD-01 and AUD-02 on hardware, 2-hour soak. Details are in `docs/AUDIT_A_F.md`.

## CHANGE ID: P1-048 — Release 0.5.0 (build 9)

**FILES CHANGED:**
- `scripts/build-host-app.sh` and the iPad `project.pbxproj`: version 0.5.0, build 9.
- `docs/share/PANDUAN-INSTALASI.txt`: display space, paired iPad names, and a section on sleep, lock and screensaver.
- `AGENTS.md`: state.
- Personal identifiers removed from sample data, tests and docs before publishing.
- `scripts/build-host-app.sh` and `scripts/build-ipa.sh` now run `strip -S`. The shipped binaries had debug-map entries with absolute build paths, which included the builder's home folder; 0.4.2 contained them too.

**CONTENTS:** P1-043 to P1-047, together with the panel redesign (5a249cb).

**VERIFIED:**
- `swift test` passed.
- IPA and DMG built (the DMG ad-hoc signed).
- The identifier scan of the public tree and of both artifacts came back clean.


## CHANGE ID: P1-049 — "Keep the display on" / "Keep the Mac awake"; a tap or key on the iPad wakes the displays

**FILES CHANGED:** `macOSHost/Host/{HostController,HostFleet,InputInjector,StatusPanel,main}.swift`, `docs/CHANGELOG.md`.

**SUMMARY:**
- General tab, two new switches:
  - **Keep the display on** (default on, the earlier behaviour) holds `PreventUserIdleDisplaySleep` while an iPad is connected.
  - **Keep the Mac awake** (default off) holds `PreventUserIdleSystemSleep`, so the iPad can always wake the displays. A sleep the user asks for still happens.
- While the Mac is locked, in a screensaver or with its displays asleep, a tap, click, key or scroll start on the iPad wakes the displays (`IOPMAssertionDeclareUserActivity` and a one-point pointer nudge). The event itself is still dropped, so nothing is clicked or typed.

**VERIFIED:**
- `swift test` 161/161.
- `pmset -g assertions` shows both assertions with Mac awake on, and only the display one by default.
- The panel render shows both switches.

**NOT RUN:** waking the displays with a tap or key on the iPad (needs the user's hand on the iPad).

## CHANGE ID: P1-050: Golden protocol vectors (for a second client)

**FILES CHANGED:**
- `scripts/gen-protocol-vectors.py` (new): an independent implementation of the v6 wire format in Python (`cryptography`), written from the Swift sources. It writes `Tests/Vectors/protocol-v6.json`; `--check` fails if the file is stale.
- `Tests/Vectors/protocol-v6.json` (new): fixed keys derived from public labels (no secret), the handshake (transcript, direction keys, pairing code, proof messages, fingerprints), clear and encrypted frames both ways, every control message and input event, and the little-endian audio packets.
- `Tests/Unit/WDSessionTests/ProtocolVectorTests.swift` (new): the real `SessionCodec`, `AudioPacket`, `FrameParser` and `SecureChannel` (host and client) against the vectors, plus a tampered frame.
- `Shared/Session/SecureChannel.swift`: an internal initializer with a fixed ephemeral key, for the vectors only. The public initializer is unchanged and still creates a fresh key.
- `scripts/verify.sh`: checks that the vectors match the generator when `cryptography` is installed.
- `docs/ANDROID_COMPATIBILITY.md`: section 4.3 points to the vectors.

**WHY:** a Kotlin client is a second implementation of the protocol; the vectors are the contract both must meet. The pairing-code vector has its top bit set, so a signed 64-bit modulo (Kotlin `Long %`) gives a wrong code; session IDs and one sequence number also exceed the signed and 32-bit ranges.

**VERIFIED:** the generator's self-checks (every sealed frame opens with its key and header as AAD; every Ed25519 proof verifies; X25519 agrees both ways) and `--check` passed on Linux.

**VERIFIED ON THE MAC:** `swift test`: all 7 ProtocolVectorTests passed; 0 failures in every suite.

## CHANGE ID: P1-051 — GitHub issue #1: no capture stalls behind the encoder, bounded decode queue on the iPad

**REPORT:**
- Setup: Mac mini M1 with an iPad 10th gen (A14), running 0.4.0.
- With Balanced, the picture lagged about 5 s behind the Mac and stuttered while typing.
- The host captured at only 15–30 fps, with gaps up to 3 s. The largest gaps lined up with lane switches to 4:4:4.
- Encode time and the link were fine.

**ROOT CAUSES (from the source; reproduced only partly, since there is no M1 or A14 here):**
1. **Host.** The capture callback converted the frame on the GPU and submitted it to VideoToolbox synchronously. On this M6 the callback cost p50 2.5 ms (max 4.4 ms). Any slow submission, such as a 4:4:4 10-bit keyframe on an M1, held ScreenCaptureKit's callback, so capture itself fell behind. The capture and repeat queues could also submit at the same time.
2. **iPad.** The Metal renderer put every frame on the decode queue with no limit. A decoder slower than the stream (HEVC 4:4:4 10-bit on an A14) built a queue that never drains, which explains a picture seconds behind the Mac.

**FIX:**
- **Host (`VideoEncoder`).** Conversion and submission run on their own serial queue, one frame at a time. While one frame is being submitted, only the newest waiting frame is kept, and its keyframe flag is carried over. A lock keeps invalidation away from a running submission. The lane statistics now log "replaced before encode".
- **iPad (`DecodeBacklog`, `MetalVideoRenderer`, `ClientSession`).**
  - At most 6 frames (100 ms) wait for the decoder.
  - Beyond that, frames are dropped until the next keyframe, which is requested from the Mac. A P-frame without its reference would only decode into garbage.
  - The keyframe skips the older frames still queued.
  - Repeated stalls count as decode failures (D-031). After 3 stalls in 10 s, the Mac steps this iPad down: no 4:4:4, then 8-bit. The step-down is remembered and shown in the panel.

**VERIFIED (Mac18,5 M6 + iPad Air 13-inch M2):**
- `swift test`: all pass, with 6 new `DecodeBacklog` tests.
- Capture callback after the fix: p50 0.04 ms, max 0.35 ms (before: p50 2.5 ms, max 4.4 ms).
- 60 Hz full-screen animation:
  - Pro: capture, encode and the iPad's glass all at 59.8–60 fps, 0 gaps over 25 ms in steady state, decode p50 3.7 ms.
  - Balanced with 5 motion/still cycles and lane switches: steady 59.8 fps, 0 iPad stalls, 4:4:4 decode 5–11 ms.

**NOT RUN:**
- The reporter's hardware (M1, A14).
- A decoder actually slower than the stream (the drop path is covered by unit tests only).
- The A/B with the released 0.5.0 binary: an ad-hoc-signed copy has no Screen Recording permission here.

## CHANGE ID: P1-052 — Release 0.5.1 (build 10)

**FILES CHANGED:**
- `scripts/build-host-app.sh` and the iPad `project.pbxproj`: version 0.5.1, build 10.
- `docs/share/PANDUAN-INSTALASI.txt`: the two keep-awake switches, and a tap or key on the iPad waking the displays.
- `AGENTS.md`: state.

**CONTENTS:** P1-049 to P1-051 (keep-awake switches, protocol vectors, the issue #1 fix) and the Android compatibility audit (`docs/ANDROID_COMPATIBILITY.md`).

**VERIFIED:**
- `swift test` passed.
- IPA and DMG built (the DMG ad-hoc signed, binaries stripped of debug paths).
- The identifier scan of the public tree and of both artifacts came back clean.


## CHANGE ID: P1-053 — README brought up to 0.5.1, with screenshots

**FILES CHANGED:** `README.md`, `docs/images/` (new), `docs/CHANGELOG.md`.

**SUMMARY:**
- New feature entries: display size (Default / More / Most Space, remembered per iPad, area-filter downscale); following the Mac's sleep, lock and screensaver; the keep-awake switches; paired iPad names and models; the bounded decode queue.
- Corrected entries: the diagram now ends in the Metal renderer, not AVSampleBufferDisplayLayer; the panel is the Liquid Glass panel; a step-down also happens when an iPad decodes too slowly.
- New limitation: the iPad cannot wake a Mac from system sleep.
- Screenshots: the Mac menu bar panel (Display, Input, Audio and General tabs, rendered with sample data) and the iPad app's waiting screen (`docs/images/`). The Security tab is left out because its sample data carries real key prefixes.

## CHANGE ID: P1-054 — Landing page rebuilt as a scroll-told product page (website only)

**FILES CHANGED:** the separate website directory of the Mac host & iPad workspace (`build.py`, `cms_build.py`, `content.json`, `src/page.html`, `assets/`, `cms/content.js`, `cms/editor.js`, `cms/editor.css`), `docs/CHANGELOG.md`. The previous site is kept beside it as `website-backup-2026-11-23-v0.4.2`.

**SUMMARY:**
- Rebuilt from scratch for 0.5.1 in the style the owner chose from apple.com product pages: black stage, `#161617` tiles, Inter only (self-hosted variable subset, weights 300–800, OFL), weight that animates on headings.
- Opening scene pinned to scroll: a line drawing of an iPad, a USB‑C cable and a Mac mini. Scrolling seats the plug, lights the screen with the app's real waiting-screen text, shows the pairing code on both sides, then traces a desktop while video, audio and input flow along the cable.
- Chapters: by the numbers, new in 0.5.1, how it works (three lanes), display and the four quality presets (an interactive chroma/bit-depth illustration computed in BT.709), audio, input (gestures, shortcuts), the real menu bar panel captures, sleep/lock, security, an honest compatibility list (untested: other iPads, 120 Hz, two iPads, Sidecar/DisplayLink), install, FAQ.
- The Mac in the opening scene is a front render of the Mac mini supplied by the owner (transparent PNG, cropped to the body). It appears to be Apple's own product image; the owner chose to use it after being told it is not licensed for third-party sites.
- Mood photos supplied by the owner (Unsplash licence, credited in the footer). One photo carries the app's real waiting screen mapped onto the iPad with a 4-point perspective transform, labelled as inserted.
- All facts checked against `README.md`, the install guide, the v0.5.1 release notes and the preset text in `HostController.swift`. Downloads point to the latest GitHub release.
- CMS: keys are now explicit (`hero.title`, …) instead of positional, so moving sections never reassigns saved text; the build fails on a missing, unused or mismatched key between Indonesian and English. Sanitizer allows the `thin` class. Both production language revisions were still 0 (empty), so no saved content is affected.

**VERIFIED:** Pass A: build, `node --test cms/worker.test.mjs`, JavaScript syntax, every glyph on both pages present in the font subset, all external links return 200, personal-identifier scan (only the owner's own domain and public GitHub handle match). Pass B (local server, browser): ID and EN at 1440, 1024, 768, 390 and 320 px with no horizontal overflow, scroll scene states, tabs with keyboard, mobile menu with Escape, static layout used for reduced motion. The browser pane was hidden for part of the run, so some frames were checked through the DOM rather than screenshots. 

**DELIVERY:** Deployed on the owner's yes to Cloudflare Pages project `wireddisplay` (production branch `main`): https://bf007ef2.wireddisplay.pages.dev/, live at the custom domain and /en/. Checked after deploy: both pages, `/api/content` (id/en, revision 0, empty), `/api/session`, `/admin/`, images, font, `robots.txt`, `sitemap.xml` and the security headers all return 200; in the browser the CMS loaded, the scroll scene was active, Inter loaded and there was no horizontal overflow. NOT RUN: a real iPhone/iPad and Safari pass. No app binaries, commits, pushes or GitHub releases.

## CHANGE ID: P1-055 — Landing page: hero headline fix (website only)

**SUMMARY:**
- Bug: the hero headline broke into scattered words on the live site. The word-by-word animation marked the heading with the class `split`, which is also the two-column grid layout of the Audio and Security sections, so the heading became a grid. Renamed the class to `words-ready`. `build.py` now fails when a class that `site.js` adds is also a standalone rule in `site.css`.
- The headline is now two lines with one clear hierarchy, bold then light grey: "iPad‑mu jadi layar Mac. / Cukup satu kabel." and "Your iPad, as a Mac display. / Just one cable."
- Removed the "scroll to plug in" hint, which sat inside the drawn iPad screen.
- Menu bar panel section is now a gallery in the pattern of apple.com's MacBook Pro "Get the highlights": wide cards (87.5% of the viewport, at most 1260 × 612 px, measured on apple.com), headline top-left (tab name bold, description grey), the real panel capture on the right. When a card becomes active its capture rises in, then a pulsing ring outlines the key control and a callout names it (Display: sizes remembered per iPad; Input: off until allowed; Audio: headphone switching; General: new in 0.5.1). Ring positions come from pixel measurements of each capture.
- Gallery controls: timed dots in a pill (the active dot fills over 6 s, then the next card), round play/pause, swipe and trackpad, tab-pattern keyboard on the dots (arrows, Home, End). Autoplay pauses on hover, keyboard focus, when the gallery is off screen or the tab is hidden, and never runs with reduced motion.
- Icons: one line-icon set (same stroke, 44 px) on every point — new in 0.5.1, display, audio, input — and on the three lanes of "How it works", tinted with each lane's data colour.
- Gallery cards now show the panel in context: the right 62% of each card is a slice of desktop (a blurred wallpaper made from the monitor area of the owner's desk photo) with a generic menu bar strip, and the panel hangs right under the highlighted WiredDisplay icon. No fake menus or Apple marks.
- Bug fixed: the highlight ring could extend past the panel (reported on the General and Audio cards). The capture's wrapper sized itself to the image's natural width while the image was drawn smaller. The wrapper's width now follows each capture's aspect ratio; measured on all four cards: wrapper = image, ring inside the image, panel centred under its icon (0 px).
- Sleep, lock, screensaver is now one stage: three selectable states on the left (timed progress, auto-advance every 6 s, keyboard tab pattern) and a large line-drawn iPad that acts each one out — display sleep goes dark and returns; locked or screensaver shows a tap waking the lock screen, never the desktop; Mac sleep shows the app's waiting screen, then reconnects. Hover or focus only holds the auto-advance; the state animation keeps playing. Without JavaScript or with reduced motion every description is shown.
- Security: the code card now matches the height of the copy column, label above code, with a "match" check between the Mac and iPad codes.
- Phones at 320 px: a 6 px overflow from the keyboard-shortcut table is fixed (grid children may shrink; key combinations may wrap).
- Audio is now a bento: heading and lead across the page, then one grid with the waveform tile (2/3 wide, two rows tall) beside the two point tiles. Measured at 1440 px: tops and bottoms align (0 px); at 820 px the waveform spans the row and the two tiles share one height; at 390 px everything stacks at one width.
- Touch gestures are now guides in the manner of the macOS Trackpad previews, each showing the finger motion and its result: tap = press with water ripples; drag = finger trail while a striped page scrolls and keeps gliding after release (momentum); hold then drag = a ring locks on, then a blue selection grows; two-finger tap = two ripples and a context menu; pinch = an object grows and shrinks; two-finger rotate = the object turns; three fingers = pinch shows ⌘C, spread ⌘V, swipe left ⌘Z (as in the install guide). Checked frame by frame at 0.9 s and 2.15 s; every element stays inside its pad at 1440 and 390 px.
- Opening scene rebuilt in one material language instead of a line-drawn iPad beside a photographic Mac: an HTML/CSS iPad at iPad Air 13-inch proportions (aluminium bezel, glass, glare, floor reflection) and the Mac mini render on the same lit floor. A scroll-driven 3D camera swings from a low three-quarter view to the front; the plug slides in with a glow at the port; the screen lights the floor; the pairing code appears as one quiet readout whose digits arrive with the scroll; the screen then shows the owner's real capture of the Mac desktop on the iPad while the cable carries glowing data pulses; finally the camera moves into the screen until it covers the window (scale computed from the glass and window size; verified to cover at 1440 × 900 and 390 × 844).
- The "Mac on iPad" screen is the owner's iPad capture (2732 × 2048). Other apps' menu bar icons are blurred; the WiredDisplay icon, the macOS screen-capture indicator, the clock and the recording dot are kept. The caption says so. Captures that show the owner's Mac name and pairing ID were not used. `build.py` warns if the screen is still a placeholder.
- Share images per language (`og-id.jpg`, `og-en.jpg`, 1200 × 630, made by `scripts/make-og.py` from the real capture with Inter; the script checks the text keeps 32 px clear of the iPad).
- Downloads are specific: "Download for Mac" (WiredDisplay-0.5.1.dmg, 1.1 MB) and "Download the iPad app" (WiredDisplay-0.5.1.ipa, 581 KB) in the hero and as two cards in Install; sizes from `gh release view v0.5.1`; both links return 200. The header and closing buttons still open the latest release page.
- Language suggestion: when the browser's first language is the other one, a small pill offers the other page (written in that language, with its `lang`); never a redirect; dismissal is remembered.
- "And on the iPad": the owner's real capture of the iPad Controls panel (the one without the Mac's name or pairing ID) in the same iPad material, with the live stream details, the renderer choice and This iPad. Checked that these UI strings were in the code before the v0.5.1 release (added 17 November).
- Unused assets (old desk photos, old share image) moved out of the deploy to `references/unused-assets/`.
- Point icons are larger (60 px, from 44 px) with a thinner line (stroke 0.9 in a 24-unit box, from 1.7), the same set everywhere.
- New "Comparison" section before Install: WiredDisplay, OpenDisplay, Luna Display and Sidecar in one real table (10 rows: price, extra hardware, connection, which screens, requirements, Mac with no monitor, sound on the iPad, control from the iPad, encryption, install). Only facts from each product's own pages, as of 24 November 2026: the OpenDisplay README, issues #5 and #182, its privacy page and release 1.30.3; astropad.com/product/lunadisplay and the Astropad Help Center system-requirements article; Apple Support 102597. Where a source says nothing, the cell says "Not stated". WiredDisplay's own limits are in the table (iPad only, cable only, sideloaded, Mac app not notarized, tested on one iPad). On phones (≤ 700 px) each row becomes a stacked list; between 701 and 900 px the table scrolls sideways inside its card with a sticky first column.
- The keyboard-shortcut table now stacks by the width of its own card (container query), which fixes a 41 px page overflow at 768 px.
- iPad proportions (after deploy b686c259, reported by the owner: the iPad looked too square and the captures were cut off at the edges, e.g. "inder" instead of "Finder" and a cut-off clock). The capture files were complete; the CSS was at fault: the glass took its height from the body's `aspect-ratio` through `height:100%`, so it could end up squarer than the 2732 × 2048 capture and `object-fit:cover` cropped the sides. Now the glass itself has `aspect-ratio:2732/2048` and the body gets its size from the glass plus a bezel from the real iPad Air 13-inch (280.6 × 215.5 mm: about 8.2 mm at the sides, 8.7 mm top and bottom), so the body is 1.302:1. Measured in the browser: glass and image both 1.335:1 in the opening scene and 1.332:1 in "And on the iPad", so nothing is cropped. Corner radii follow the device (body 4.7 % / 6.1 %, screen 1.4 % / 1.85 %). The final zoom margin went from 1.04 to 1.08; the glass still covers the window at 1440 × 900, 1200 × 1270 and 390 × 844. Deployed with the owner's yes (Cloudflare Pages deployment b88c286f); the live page measures the same ratios.
- English is now the default language: English at `/`, Indonesian at `/id/` (owner's request). The Pages Worker answers `/en` and `/en/…` with a 301 to `/…`, so old links keep working (new Worker test). hreflang, sitemap, CMS admin links and the CMS editor's language switch follow the new paths. Not yet live.
- The ID/EN switch left the toolbar. Language now sits in the footer (globe icon, "English · Bahasa Indonesia", native names) and at the foot of the phone menu. The one-time language suggestion stays.
- Design audit (1440, 768 and 375 px, both languages), first fixes:
  - section padding 170 → 140 px at most (black gaps of about 300 px after footnotes);
  - chapters numbered 01–10 throughout (some had "—");
  - in the opening scene the waiting screen is gone before the desktop is a fifth of the way in, and the desktop wakes from dim and settles from 1.035× (no more double exposure of "WiredDisplay" over the wallpaper);
  - 0.5.1 cards 2 and 3 act out their change at the foot of the card (the app's two "Keep … " switches turn on in turn; a lock screen wakes on a tap with a ripple), so the three cards now end on one line;
  - the pairing code arrives digit by digit, Mac first, then the line, then the iPad's digits, then the check;
  - the numbers rise in turn per column;
  - the desk photo's iPad now shows the real desktop capture (caption updated in both languages);
  - bug: the desk-photo insert could be placed while still hidden (size 0, so the 3D matrix was NaN and the insert showed flat and full size); it now uses the image's declared size.
- Improvement plan for design, motion and animation written to the website folder (`IMPROVEMENT-PLAN.md`).
- Deployed with the owner's yes (deployments a96beb9c and 9be54d11). The first one served the English page at `/en/` with status 200: `_routes.json` only sent `/api/*` and `/admin*` to the Worker, so Pages' fallback answered `/en/`. `/en` and `/en/*` are now in `_routes.json`. Checked live: `/en`, `/en/`, `/en/?edit` and `/en/faq` return 301 to the same path under `/`, keeping the query string.
- Round A of the plan (local, not yet deployed):
  - hero: one meta line ("Free and open source · macOS 14+ · iPadOS 17+ · USB‑C data cable"); file sizes stay on the download cards in Install;
  - the opening scene now ends on a line over the full screen ("This is your Mac. On your iPad." / "Ini Mac‑mu. Di iPad‑mu.", CMS key `story.outro`), which rises out of a blur, under a soft vignette. The scene then dims to black and meets band 1 with no seam (a 1 px line at the sticky edge is gone because the scene itself fades out);
  - FAQ: the answer's height animates open and closed (`::details-content` with `interpolate-size`; measured 74 → 148 px over about 0.4 s and back). Browsers without support show the answer at once, with the previous fade.
  - Checked: 1440 × 900 and 390 × 844, EN and ID, no horizontal overflow; Worker tests pass; every character is in the font subset.
- Rounds B and C of the plan (local, not yet deployed):
  - one colour per lane, carried through the page: video blue `#2997ff`, audio purple `#bf5af2`, input green `#30d158` (cable pulses and chips in the opening scene, lane icons and packets, the Display, Audio and Input chapter numbers and icons, the audio waveform). Before, audio was white in one place and blue in another, and input was grey in the lanes but green in the opening scene;
  - packets on the lanes leave a short light trail;
  - Install is a timeline: three numbered nodes on a track above the cards, each over its card's text, with a line that fills blue as you scroll and nodes that light in turn. A first version drew the line through the cards and across the gaps; the owner found it broke out of the boxes, so it was moved to its own track. On screens up to 900 px the track is hidden and the cards keep their numbers;
  - tiles (cards, lanes, gestures, audio, pairing) get a soft light that follows a precise pointer and lift 2 px; reveal timing is kept;
  - Display: new "Coloured text, up close" slider comparing 4:2:0 and 4:4:4 on red text over blue. The 4:2:0 side is a real luminance/chroma split: the colour is drawn blurred and the sharp image is laid on top with `mix-blend-mode: luminosity`. The divider sweeps once on first view, the slider is a native range input with a label, and the illustration caption is shown;
  - "By the numbers": digits run through values and settle left to right;
  - menu-bar gallery rings draw themselves from left to right;
  - a 3.5 % film grain over the page (against banding in the large glows) and a small dot under the active section in the navigation;
  - Sleep, lock, screensaver (owner's request): the line drawing is replaced by the same iPad as the opening scene, with the real desktop capture (display sleep dims it to black and back), a lock screen on the blurred wallpaper with a tap ripple (locked or screensaver), and the app's real waiting screen (Mac sleep). The Mac mini stands beside it and dims while the Mac sleeps. A status pill copies the selected state's name (amber for sleep or lock, grey for Mac sleep).
  - Checked: no horizontal overflow at 320, 390, 768, 1024 and 1440 px in EN and ID; Worker tests pass. Not checked: `prefers-reduced-motion` in a real browser setting (the static rules are in place but were not switched on in the test browser).
- Rounds A, B and C deployed with the owner's yes (Cloudflare Pages deployment 6499dd41). Live: `/`, `/id/`, `/admin/` and the new insert image return 200; `/en/` returns 301 to `/`; the new sections are in the page; the Sleep stage shows its status; the desk-photo insert is placed; no horizontal overflow. The only console errors are the Cloudflare Web Analytics beacon blocked by a content blocker in the test browser.
- Quality pass and polish (owner's "group 1, then 2"; local, not yet deployed):
  - the website folder is now a local git repository (`main`, first commit 6bcbe06 = deployment 6499dd41; never pushed). `dist/`, `.wrangler/` and `references/captures/` (unredacted screenshots) are ignored;
  - `prefers-reduced-motion` checked for real on a test copy with the media queries switched on: the opening scene becomes the static stack, every reveal is visible, the state descriptions are all open, and after scrolling the whole page no animation is running;
  - performance at 1440 × 900 on the test Mac (144 Hz): LCP 84 ms (the headline), CLS 0.002, 607 KB transferred. The opening scene had dropped to 106 fps with 36 frames over 20 ms; the cause was `filter: brightness()` on the 2732 px desktop capture and a blur on the closing line, both re-rasterised every frame. They are now an opacity-only dim layer and a scale; the scene measures 143 fps (one frame over 20 ms) and the rest of the page 144 fps. A run in which the browser pane was not visible (1 fps, rAF every 2 s, no long tasks) was discarded;
  - the iPad under the hero is no longer black: the app's waiting screen shows dimmed (42 %) before the cable goes in and brightens when the Mac answers;
  - the closing section is a bookend: the photo is replaced by the same iPad showing the Mac, tilted as it enters and upright as it rises, under a blue glow (Samuel Angor's photo is no longer used; footer credit and README updated; files moved to `references/unused-assets/`);
  - Input: fingertips in the gesture guides carry the input lane's green;
  - comparison on phones: a "Compare with" switch (All, OpenDisplay, Luna, Sidecar) shows WiredDisplay next to one product at a time;
  - SoftwareApplication JSON-LD per language (version, date, OS, free, licence, download, repository); checked that it parses;
  - share images regenerated with the corrected iPad (2732:2048 glass, real bezel); the old rotated shading left two dark wedges in the bezel, replaced by a diagonal ramp.
  - Checked: no horizontal overflow at 320, 390, 768 and 1440 px in EN and ID; Worker tests pass.
  - Committed to the local website repository (45d4c44) and deployed with the owner's yes (Cloudflare Pages deployment 9b2824d5). Live: `/`, `/id/`, `/admin/` and both share images return 200 (the live `og-en.jpg` matches the new build byte for byte); `/en/` returns 301; JSON-LD, the closing iPad and the compare switch are in the page; the hero iPad starts at 42 % waiting screen; the footer credits Amanz and Mahmudul Hasan.
- "Push to the limit" pass (local, not yet deployed):
  - WebKit: no iPad simulator could run (every simulator is "unavailable": the iOS 27 runtime is not installed; installing it is about 8 GB and left to the owner), and Safari on the Mac can only be viewed, not navigated, by Claude. Instead every CSS feature in use was checked against current WebKit. All are supported except `interpolate-size`, which is behind `@supports`, so Safari shows FAQ answers at once. Every `backdrop-filter` has its `-webkit-` twin and every mask has `-webkit-mask`. Not verified on a real iPad or in Safari by eye;
  - navigation: "Compare" / "Perbandingan" added (fits at 920 px in Indonesian, the longest labels);
  - footer on phones: brand, then the links in one left-aligned flow, then the notes (before, the links were pushed right beside the brand);
  - language suggestion on phones: one compact bar with only the switch link and close, and it hides itself (without being dismissed for good) after one and a half screens of scrolling;
  - "Coloured text, up close." no longer breaks after "Coloured".
  - Checked: no horizontal overflow at 320 and 1440 px; Worker tests pass.
  - Committed to the local website repository (58ddaa2) and deployed with the owner's yes (Cloudflare Pages deployment 5c8ce9b4). Live: `/`, `/id/` and `/admin/` return 200, `/en/` returns 301, and the navigation shows "Compare" / "Perbandingan".
- Real screen recording (owner's iPad recording, 12.4 s, 2732 × 2048, ReplayKit; local, not yet deployed):
  - reviewed frame by frame first. It contains the iPad home screen with personal apps and notification badges (0–3 s), the Mac's name in "Connecting to …'s Mac mini…" (8.7–9.3 s), and other apps' menu-bar icons on the desktop (from 9.6 s);
  - only 7.8–10.2 s is used: "Waiting for your Mac" → "Connecting…" → the desktop. Made with AVFoundation (`scripts/make-ipad-clip.swift`; ffmpeg is not installed). The name is blurred with a feathered mask from 8.66 s (no hard box) and the menu-bar icons from 9.45 s, the same areas as the still capture. Audio and metadata are dropped. Every exported frame at 0.04 s steps was checked in both files; the name is unreadable in all of them;
  - HEVC 408 KB and H.264 535 KB, 1600 × 1200; the page offers HEVC first (`codecs="hvc1"`) and H.264 as fallback (this test Chromium picked H.264);
  - opening scene: when pairing ends (65 % of the scene) the clip plays once over the iPad's glass, then fades to the sharp 2732 px still for the zoom. Scrolling back before 60 % rewinds it. It loads only from 40 % of the scene (`preload` none until then). If the browser refuses to play it (for example Low Power Mode), the scroll crossfade from before takes over;
  - closing iPad: the same clip plays once when the iPad is upright, then fades to the still; it rewinds after scrolling well away;
  - reduced motion: the clips are hidden and never downloaded (checked on the test copy: zero video requests, no running animations);
  - performance with the clip: opening scene 142–143 fps at 1440 × 900 (one frame over 20 ms);
  - the caption now says the iPad screen is a real recording and captures, and that the Mac's name is blurred too (EN and ID).
  - Checked: desktop 1440 × 900 and phone 390 × 844 (plays, no horizontal overflow); Worker tests pass. Not checked: playback in Safari or on an iPad.
  - Committed to the local website repository (2606765) and deployed with the owner's yes (Cloudflare Pages deployment 1dc71d9d). Live: both clips return 200 with `video/mp4` and answer range requests with 206; the opening clip plays and hands over to the still.
  - Found while checking: the live CMS holds saved values `"<br>"` (saved 24 November, 10.19 WIB, revision 1, both languages) for `story.note`, `ui.photoNote` and `ui.photoNoteInsert`, so those three captions are empty on the live site and the new `story.note` text does not show there. Left as it is; asked the owner whether it was deliberate.
- Motion polish (owner's "oke kerjakan"; local, not yet deployed):
  - the screen's light takes the colour of what is on the glass: app blue while waiting, the wallpaper's sky (rgb 140 200 225) once the Mac is up, on the glass glow and the floor (`color-mix`); the closing iPad and other desktop screens use the sky colour;
  - while the recording plays, a burst of light runs along the cable (2.2 s, once);
  - before the camera moves, the iPad and Mac mini lean up to 2.5° toward a precise pointer, eased, fading out as the camera turns to the front;
  - switching language cross-fades the pages (`@view-transition`, same-origin; switched off for reduced motion);
  - buttons scale to 0.97 when pressed; large buttons lean up to 6 px toward a precise pointer;
  - chapter numbers rise into place as their heading scrolls in (`animation-timeline: view()`, behind `@supports`).
  - Performance re-measured: opening scene 140 fps and the rest 141 fps at 1440 × 900; with the colour mixing removed 141/142 fps, so the difference is within noise. One run at 19 fps was the browser pane throttling and was discarded. No horizontal overflow at 375 and 1440 px; Worker tests pass.
  - Committed to the local website repository (a64a204) and deployed with the owner's yes (Cloudflare Pages deployment 203c6a55). Live: pages and the clip return 200, `/en/` returns 301, the served CSS carries the new rules, and the pointer tilt responds; the only console errors are the analytics beacon blocked in the test browser.
- Sleep stage, "Locked or screensaver" (owner's real Mac lock screen, 2000 × 1125; local, not yet deployed): the CSS-built lock screen (blurred wallpaper, "9:41", drawn padlock) is replaced by the owner's capture, cropped to the iPad's 4:3 at the centre (1500 × 1125). The account photo and the account name are blurred out (strong blur, soft edge, stopping just above the password field); the date, the time, "Enter Password" and the wallpaper are kept. Checked at 3× that neither face nor name can be read. Saved as `assets/img/ipad-lockscreen.webp` (124 KB, no metadata); the redacted PNG is in `references/captures/` (git-ignored). Checked in the browser at 1440 × 900; Worker tests pass. Committed to the local website repository (1b4dace) and deployed with the owner's yes (Cloudflare Pages deployment 6fe0c384); the live image is byte-identical to the local file and the page references it.
- Phone hero (owner's screenshot from a real iPhone in Safari, the first real WebKit check): the iPad's top edge rose into the last hero line ("macOS 14+ · iPadOS 17+ · USB‑C data cable"). The scene's starting offset (`--drop`) was a fixed share of the screen height (50–58 svh), too little where the hero text wraps into many lines. `fitDrop()` now measures the hero text's bottom and the iPad's position (layout sizes, not transforms) and, only when the share is too small, pushes the scene down so the iPad starts 32 px below the text (plus 18 px for the tilt); it reruns on resize and when the font has loaded. Measured: iPad top 65–67 px below the text at 440 × 800, 390 × 844 and 375 × 667; at 1440 × 900 nothing changes (no override). While scrolling on a phone the hero text has faded out (opacity 0 at 8 % of the scene) before the iPad passes through its area. Worker tests pass. Deployed with the owner's yes (Cloudflare Pages deployment d29b17df; committed afterwards to the local website repository as 3392338). Live at 390 × 844: hero text ends at 635 px, iPad starts at 716 px, no horizontal overflow.
- Rotate icon redrawn (owner: the details were off): a portrait iPad with a curved arrow and a real arrowhead, in the same 0.9 line as the other icons; the old one was two loose arcs beside a rectangle and did not read as "rotate". Compared three drafts at 120, 60 and 30 px; the one with a dashed landscape ghost was too busy small. The iPad download card had borrowed the rotate icon and now has its own landscape iPad icon (with a camera dot), matching the Mac card's monitor. Committed (eeb7f66) and deployed with the owner's yes (Cloudflare Pages deployment 5a854826); the live page and CSS carry both icons.
- Rotate icon, second pass (owner: the arrow must stay outside the iPad, not touching it): the arc's start ran close above the iPad's top-right corner. The iPad is now 8 × 11 (was 10 × 13) and the arc wider (radius 12), so a clear gap shows on every side down to 30 px; compared two drafts at 160, 60 and 30 px. Committed (160d50a) and deployed (Cloudflare Pages deployment c1c23470); the live CSS (`site.css?v=c11204144142`) carries the new path.
- Rotate icon, third pass (owner sent a stock "rotate tablet" icon as a reference; it carries a watermark, so it was not copied, only its idea): a portrait iPad behind a landscape iPad, each with a camera dot, and a two-way curved arrow in the free top-right corner, touching neither. The back iPad's outline breaks where the front one covers it (an SVG mask inside the icon), so the two read as layered in a line icon. Compared with the plain version at 160, 60 and 30 px; checked on the page at 1440 × 900. Then the arrow's proportions (owner: fix them): the arc was short (radius 5) and the heads heavy (about 26 % of the arc). The arc is now longer (radius 5.8, a quarter circle) and the heads smaller and symmetric (about 18 %, arms 1.15 × 0.95), still 1.5 units clear of both iPads; compared two drafts at 200, 60 and 30 px. Committed to the local website repository (a9d6371) with the owner's yes, then deployed on the owner's "Publish" (Cloudflare Pages deployment 36d19992); the live CSS (`site.css?v=4ff65b50bf1a`, same as the build) carries the new icon.
- Audio panel (owner: add speaker and mic icons, and make the motion match): each wave now has a head row with an icon chip in the audio lane's purple, a speaker for "Mac → iPad speakers" and a microphone for "iPad microphone → Mac". The icons move on the waves' own beat: the speaker's three arcs ripple outward (1.7 s, staggered 0.14 s), the microphone's level rises inside the capsule (2 s), and a ring pulses out of each chip. Both waves now travel left to right, source to destination, as their labels read (the speaker wave used to travel right to left; measured: its peak moves from bar 18 to bar 22 in 150 ms). Each bar has its own peak (`--a`, a fixed speech-like envelope set by `build.py`, so builds stay identical) instead of one uniform lens shape. Reduced motion: no running animations (checked on the test copy), arcs shown at 0.9 and the level at 60 %. 144 fps through the section at 1440 × 900; no horizontal overflow at 390 px; Worker tests pass. Local, not yet deployed.
  - Then (owner: put the icon in the middle of the animation so it reads clearly): the chip moved from beside the label into the middle of its wave, 56 px (44 px on phones), with 14 bars on each side; the labels sit centred above. Bars are tallest beside the icon and fall away outward. The motion now says what each device does: the speaker's wave radiates outward from the icon (measured peak distance 7 → 8 → 9 → 11 → 12 → 13 over 0.5 s) and the microphone's wave flows inward into it (9 → 8 → 6 → 5), and the microphone's ring contracts instead of expanding. `build.py` builds the two halves (`waveL`, `waveR`) with each bar's distance from the icon (`--d`). No horizontal overflow at 375 and 1440 px; Worker tests pass.
  - Then (owner: the icons are too small, and speaker and mic need to be separated): chips grow to 88 px on desktop (72 px at the smallest desktop width, 60 px on phones) with the icon at 56 % of the chip (49 px), a soft radial fill and a faint glow in each lane colour; the two parts are split by a hairline divider that fades at both ends, with even space above and below it; labels are a step larger and lighter. Checked at 1440 × 900 and 375 × 812 (no horizontal overflow). Deployed on the owner's "Deploy" (Cloudflare Pages deployment 8f188e9d; the live CSS `site.css?v=21254b80fafe` matches the build and the page carries the centred-icon waves). Committed afterwards to the local website repository (6cfb279).
- Measured: page assets 1.38 MB before this change; text contrast at least 4.65:1 everywhere; scroll at 134 fps in the 3D scene and 143 fps elsewhere on the test Mac (144 Hz).

**VERIFIED:** build and CMS Worker test pass; gallery in a visible browser at 1440 px: card 1260 × 612 px aligned to the edge, autoplay advanced every 6 s and wrapped from the last card to the first, dots, play/pause and arrow keys worked, rings landed on the intended controls; at 390 px the card, callout and capture fit with no overflow. Hero: local browser at 1440 px (EN) and 390 px (ID): the heading is a block with the expected lines, the drawing starts below the hero text, no horizontal overflow. Comparison and icons: no horizontal overflow at 320, 414, 768, 834, 1024 and 1440 px (ID and EN); every character on the page is in the font subset; identifier scan of `dist/` matches only the site's domain. Deployed with the owner's yes on 24 November 2026 (Cloudflare Pages deployment b686c259): `/`, `/en/`, `/admin/` and the assets return 200; live hero heading is a block, the comparison table shows 10 rows, both download links return 200.

## CHANGE ID: P1-056 — Landing page: antislop audit and fixes (website only)

**FILES CHANGED:** the separate website directory (`content.json`, `src/page.html`, `assets/site.css`, `assets/site.js`, `IMPROVEMENT-PLAN.md` section 5), `docs/CHANGELOG.md`.

**SUMMARY:**
- Audit with the antislop skills (core, UI, copywriting, human/accessibility, mobile layout); findings A1–A8, B1–B7 and C1–C6 are in `IMPROVEMENT-PLAN.md` section 5. All were fixed on the owner's "kerjakan semuanya".
- Copy: no em dash left in either language (13 keys). The opening-scene alt text now describes the 3D scene, not a line drawing. The FAQ on Sidecar states only WiredDisplay's own facts, and the Input headline no longer compares to Sidecar. The "~1 ms" figure is now described as the pointer position crossing the cable, measured on the test setup (DECISIONS: Mac→iPad transfer ~1 ms). Formula headlines were rewritten. Indonesian strings that were left in English were translated. The panel lead now uses the app's own "Connection code" label.
- Layout: "New in 0.5.1" moved after Install (the hero version line links to it). "By the numbers" went from six facts, four of them repeated elsewhere, to three: ~1 ms, 4:4:4 10-bit, and 60 Hz tested. Display's four equal cards became one list of three; "can be the main display" is already told by the Mac mini band. On phones, the gestures are one swipeable row and the comparison opens on WiredDisplay vs Sidecar. Page height at 375 px went from 31,586 to 28,719 px.
- Accessibility:
  - The gallery callout is on #0071e3 (4.70:1, was 3.02:1).
  - All controls have 44 px targets: header Download, quality tabs, comparison picker, gallery dots, language-hint close, and sources as a list.
  - Text is at least 12 px.
  - The shortcut arrows use the muted grey (4.99:1).
  - The phone menu fills the screen.
  - Spec labels are no longer upper case, so "MAC/IPAD" no longer appears.
- Motion:
  - Every infinite CSS animation now plays about 5 s (whole cycles), then rests. Scrolling back, hover or tap replays it (WCAG 2.2.2).
  - Sleep/lock auto-advance runs one round, then stops.
  - font-weight is no longer animated outside the hero headline, so text no longer re-wraps.
  - The opening-scene caption and pairing readout no longer overlap on phones: they now appear one after the other, and the caption has side margins.
- Identity: three hairlines in the lane colours open every chapter label (one cable, three lanes). The apple.com tokens and the blue button stay (owner's choice).

**VERIFIED:**
- `python3 build.py`: 0 em dashes in `dist/` (EN and ID).
- `node --test cms/worker.test.mjs`: 2/2 pass.
- `node --check assets/site.js`.
- In the browser:
  - No horizontal overflow at 320, 375, 768 and 1280 px.
  - No text below WCAG AA (automatic scan).
  - No infinite animation left after load and after the gallery activates.
  - Hover replay works.
  - Caption and pairing readout opacities never overlap during the scroll.
  - Console: only the expected local 404 for `/api/content`.
- NOT RUN: Safari or a real iPhone/iPad; reduced-motion re-check after these edits.

**DELIVERY:** Website commit `0dabd0e` (local repo, never pushed). Deployed on the owner's "deploy" to Cloudflare Pages `wireddisplay` (branch `main`): https://d2f8b706.wireddisplay.pages.dev, live at the custom domain and /id/. Before deploying: D1 holds only the three `"<br>"` captions per language (revision 1), so no saved key overrode the changed copy and D1 was not written. The identifier scan of `dist/` matched only the site's own domain and public GitHub handle. After deploying: /, /id/ and /api/content return 200 and /en/ returns 301. Both pages contain the new markup and no em dash. At 375 px the ID page shows no horizontal overflow, the callout is on #0071e3, and the CMS overlay loaded.

## CHANGE ID: P1-057 — Display size can be changed when the iPad is the Mac's only screen; comment cleanup

**FILES CHANGED:** `macOSHost/Host/VirtualDisplayController.swift`, `docs/DECISIONS.md` (D-043), and comments only in `DecodeBacklog`, `VideoEncoder`, `HostController`, `InputInjector`, `ClientSession`, `MetalVideoRenderer`.

**BUG:** with the Mi Monitor disconnected, macOS made the WiredDisplay virtual display the main display (`bounds (0, 0, …)` in the log). `canChangeSpace` refused any main display (D-015), so the panel's Default / More / Most Space control was disabled.

**FIX:** the guard now refuses only a mirrored display. It is only ever called with WiredDisplay's own display, so another display or the arrangement is never touched (D-043).

**COMMENTS:** over-long comments from P1-045 to P1-051 were cut to one or two lines, dropping issue history and reasoning chains. No code changed with them.

**VERIFIED:**
- `swift test` 174/174.
- Host reinstalled. With WiredDisplay as the only and main display, the same CoreGraphics calls as the panel switched it to More Space and back: the host followed each change, captured at 3072×2304 with its own downscale, and remembered the choice.
- Left at Default afterwards.

**NOT RUN:** clicking the panel control itself (the user tries it).

## CHANGE ID: P1-058 — IMP-01–03: no silent listener in the background, an honest status, logs that keep their history

**FILES CHANGED:** `iPadOSClient/WiredDisplayClient/Sources/{ClientApp,ClientLog,ClientSession}.swift` (ClientApp: background lifecycle and audio retry), `macOSHost/Host/{HostController,VideoEncoder}.swift`, `docs/IMPROVEMENTS.md` (new), `docs/CHANGELOG.md`.

**SUMMARY:**
- **IMP-01.** In the background the iPad session now lives only as long as audio does. When audio stops or is interrupted there, the session and listener close. When the interruption ends, the listener reopens in audio-only mode. Before, a suspended app kept its port open: the Mac's connection was accepted but never answered (24 Nov: four timeouts in 35 s).
- **Audio after returning.** If the audio could not restart in the background (iPadOS refuses while another app holds the audio session, "Session activation failed"), the app retries the user's audio choice when it comes back to the front. Before, a failed start also switched the speaker off for good.
- **IMP-02.** The host reports that case as "iPad app not answering (in the background?)" instead of "old app version?".
- **IMP-03.**
  - The per-frame latency lines ("frame host", "frame glass") are sampled about every 5 s instead of every 0.5 s. They had made up 56–61 % of each log.
  - Past 2 MB, the iPad log moves to `client.old.log` instead of being deleted.

**VERIFIED:**
- `swift test` 174/174.
- Host and iPad Release builds succeeded; both were installed, and the session streams.

**VERIFIED ON HARDWARE (two runs with the user):**
- App in the background with the speaker on, then music started in another app: the iPad closed the session cleanly ("client said bye: audio interrupted in the background").
- The host made no connection attempts during the 74 s in the background, and no "not answering".
- Back in the app: audio restarted after the failed background attempt, and the speaker bridge ran 600 IO cycles with 0 overflows in 3 s.

## CHANGE ID: P1-059 — IMP-06, 07, 10, 12, 13: CI, a publish script, a Paused status, the switcher snapshot, diskutil

**FILES CHANGED:** `.github/workflows/tests.yml` (new), `scripts/publish-public.sh` (new), `scripts/next-change-id.sh` (new), `scripts/build-dmg.sh`, `macOSHost/Host/{HostController,main}.swift`, `iPadOSClient/WiredDisplayClient/Sources/ClientApp.swift`, `AGENTS.md`, `docs/IMPROVEMENTS.md`, `docs/CHANGELOG.md`.

**SUMMARY:**
- **IMP-06, CI.** On every push to the public repo, GitHub's `macos-26` runner (Xcode 26.6) runs `swift build`, `swift test` and the protocol-vector check. The host only uses macOS 26 APIs behind `#available`.
- **IMP-07, scripts.**
  - `publish-public.sh` builds the scrubbed tree, scans it with the list from `LOCAL-HANDOVER.md`, shows the diff and pushes after a confirmation. Text files are checked after removing only the allowed words (`sibawono`, `memanggil`), and images byte for byte.
  - `next-change-id.sh` prints the next free CHANGELOG ID.
- **IMP-10, Paused status.** While the capture waits for the Mac's displays to wake, the panel says "Paused: Mac displays asleep", and "Streaming" comes back once it recovers. It is rarely seen, since the panel is on a sleeping display then, but the state is now honest.
- **IMP-12, switcher snapshot.** When the app enters the background, the video view is hidden before iPadOS takes the app-switcher snapshot, and shown again on return.
- **IMP-13, diskutil.** `build-dmg.sh` uses `diskutil image attach` and `diskutil eject` instead of the deprecated `hdiutil attach` and `hdiutil detach`.

**VERIFIED:**
- `swift test` 174/174. Host and iPad apps installed and streaming.
- `publish-public.sh` dry run: "GitHub already has this tree". The scan filter flags a real name and an e-mail on lines that also hold allowed words.
- The DMG built without deprecation warnings, with its full contents and the custom volume icon flag. The 0.5.1 release files in `dist/` were restored afterwards.

**NOT RUN:**
- The CI workflow itself: it runs on the next push to GitHub.
- The switcher snapshot on the iPad (open the app switcher after leaving the app).
- The Paused text in the panel: the panel sits on a sleeping display at that moment. The code path is the one that logs "capture recovery waits for the displays to wake".

## CHANGE ID: P1-060 — GPU 4:4:4 conversion, a bounded display-layer renderer, host decisions in a tested module

**FILES CHANGED:** `macOSHost/Host/{ChromaConverter,VideoEncoder,HostController,InputInjector,PowerMonitor,VirtualDisplayController,StatusPanel,main}.swift`, `iPadOSClient/WiredDisplayClient/Sources/MetalVideoRenderer.swift`, `Shared/HostCore/` (new module `WDHostCore`), `Tests/Unit/WDHostCoreTests/` (new), `Package.swift`, `AGENTS.md`, `docs/IMPROVEMENTS.md`, `docs/CHANGELOG.md`.

**SUMMARY:**
- **4:4:4 conversion on the GPU** (Ultra, High Color, and Balanced's still lane). It uses a `convert444` kernel in `ChromaConverter` with the same BT.709 maths and the same area-filter downscale as the 4:2:0 lanes, so both Balanced lanes now share one downscale filter. `--chroma-filter off` still selects VideoToolbox.
- The encoder log now names the real rate control: standard for 4:4:4, where it used to say "low-latency".
- **IMP-09.** The system display-layer renderer skips to the next keyframe when its queue is full, and flushes stale frames when that keyframe arrives. It requests a keyframe but does not count toward the format step-down.
- **IMP-08.** The new `WDHostCore` module holds `PowerState`, `InputGate` (what iPad input does while locked, asleep or in another session), `DisplaySpace` and `CaptureSizing`, with 10 unit tests. The host uses them; its behaviour is unchanged.

**VERIFIED:**
- `swift test` 184/184 (10 new). Host build with no new warnings; the iPad Release build succeeded.
- GPU against VideoToolbox, 4:4:4 at 2732×2048: 10-bit Y and CbCr within 1 code, 1.21 ms vs 2.39 ms; 8-bit within 1 code. Downscaled from 3072×2304: 2.63 ms vs 4.64 ms, with values that differ on purpose because the filter is the area filter.
- On the stream (Ultra, More Space, 60 Hz animation): conversion p50 8.0 ms before and 3.6 ms after; capture at 59.8 fps with 0 gaps.
- Display-layer renderer on the iPad (one launch with `-metalRenderer <false/>`) under a 60 Hz animation: 59.8 fps and no false skips. The setting was put back to Metal afterwards.
- Host reinstalled: the remembered More Space is applied, the capture is 3072×2304 through `CaptureSizing`, and it streams.

**NOT RUN:** a visual check of Ultra on the iPad by the user (the codes are verified; the eye test is not).

## CHANGE ID: P1-061 — UI audit (antislop, during): readable captions, no em dashes, no decorative motion

**FILES CHANGED:** `macOSHost/Host/{StatusPanel,HostController}.swift`, `iPadOSClient/WiredDisplayClient/Sources/ClientUI.swift`, `docs/images/host-*.png`, `docs/CHANGELOG.md`.

**Mac menu bar panel:**
- **Contrast (R-25).** Captions used the system tertiary and secondary styles, which on the glass panel measured 1.6–2.1:1 (tertiary) and 3.1–4.0:1 (secondary). They now use one caption colour (`Color.caption`, primary at 82 %) that measures 5.1–6.0:1 on the section cards in light and dark.
- The version label sat straight on the glass at 1.6:1. It moved into the last card.
- **Tab title (R-06).** The uppercase, letter-spaced "DISPLAY" became a sentence-case bold 15 pt title. On the glass it measures 3.7:1, which passes as large text.
- **Copy (R-02).** The preset titles lost their em dashes ("Ultra — 4:4:4 10-bit" is now "Ultra"); the format line already carries the details.
- **Icon (R-04).** Ultra's sparkles became a 3×3 grid, for "every pixel keeps its colour". Pro keeps the bolt, for lowest latency.

**iPad app:**
- **Copy (R-02).** Em dashes removed from "Wired only. Wi‑Fi is never used." and "Live: choose “iPad Microphone” on the Mac".
- **Backdrop (R-01, R-13).** The blue radial glow behind the waiting screen is gone. The app icon's shadow is the one accent.
- **Motion (R-19, R-39).** The waiting dot marks a real state, but it pulsed forever. It is now static.
- **Controls panel (R-06, R-25, R-29).**
  - Section headers are in sentence case.
  - Gesture and shortcut actions use the primary text colour instead of the blue accent, which measured 4.3:1 as small text. The accent stays on the switches and the Reconnect button.

**VERIFIED:**
- Host and iPad Release builds succeeded; both apps installed and streaming.
- Panel renders measured in light and dark: every caption 5.1–6.0:1, the tab title 3.7:1 (large text).
- iPad waiting screen captured from the device: step details 8.0–8.3:1, status 17:1.
- No em dash left in UI strings of either app. README screenshots replaced with the new renders (sample data, scanned clean).

**NOT RUN:**
- A click-through of the panel controls: only text styles changed, no behaviour.
- The iPad Controls and pairing screens seen on the device: the Controls panel needs a tap on the iPad; the pairing screen needs an unknown Mac.

## CHANGE ID: P1-062 — iPad Controls panel readable on any desktop; a movable controls button that fades when idle

**FILES CHANGED:** `iPadOSClient/WiredDisplayClient/Sources/{ClientApp,ClientUI}.swift`, `docs/share/PANDUAN-INSTALASI.txt`, `docs/CHANGELOG.md`.

**SUMMARY:**
- **Controls panel contrast (R-25).** Measured on the device over a bright Mac desktop, the iPadOS 27 glass popover left every line at 1.9–2.2:1.
  - The panel now has a solid dark background (`presentationBackground`).
  - Secondary text uses white at 70 %, since the system secondary style measured 3.6:1 there.
  - Measured after the change: primary text 14.8:1, secondary text and headers 8.5–11.8:1, the red "Forget Paired Macs…" 5.9:1.
- **Filled buttons.** Reconnect and Pair had white text on Brand.blue at 3.2:1. They now use `Brand.action`, a darker blue: about 6.7:1 by sRGB calculation (not measured on the device).
- **Controls panel replaces the system popover.** At every button position, the popover's glass arrow stayed grey against the solid panel and its edge clipped at the screen border. The panel is now its own view:
  - It opens beside the button, on the button's side, and always fits on screen with a 16 pt margin.
  - It has rounded corners, one solid colour, a hairline border and no arrow.
  - It closes on a tap outside (the dimmed area, which never passes touches to the Mac), a second tap on the button, Escape on a keyboard, or the VoiceOver escape gesture.
- **Controls button (user request: it should not distract).**
  - It can be dragged anywhere and settles on the nearer side edge at the height where it is dropped. The position is remembered.
  - While streaming it fades to 12 % opacity 4 s after the last touch, and it stays tappable in place.
  - Dragging is never sent to the Mac.
  - Accessibility: there is a VoiceOver action "Move to the other side". It does not fade while VoiceOver runs, and there is no animation under Reduce Motion.

**VERIFIED:**
- iPad Release build succeeded and was installed.
- Contrast measured from device screenshots before and after.
- Tested by the user on the iPad: dragging, snapping to an edge, fading after 4 s, tapping the faded button to open the panel, and the position kept after relaunching the app.

## CHANGE ID: P1-063 — CI green: the real-encoder test requires the hardware encoder

**FILES CHANGED:** `Tests/Unit/WDVideoTests/VideoTests.swift`, `.github/workflows/tests.yml`, `docs/CHANGELOG.md`.

**CAUSE:** the first CI run (GitHub `macos-26`, a virtual machine) built everything and passed every test but one. `HEVCSPSTests.testReadsChromaAndDepthFromRealEncoderOutput` asked VideoToolbox for any HEVC encoder. The VM has only a software encoder, which wrote 8-bit 4:4:4 where the media engine writes 10-bit, so the test expected 10 and read 8.

**FIX:**
- The test requires the hardware encoder, like the app does, and skips with a reason when there is none.
- **Second run:** the VM's paravirtual encoder counts as hardware and still writes 8-bit. So the test now compares the parsed depth with the depth the encoder itself reports (\`BitsPerComponent\` in the format description). It stays strict everywhere instead of assuming 10-bit.
- `actions/checkout` moves to v5, because v4 runs on the deprecated Node 20.

**VERIFIED:**
- Locally the test still runs and passes on the hardware encoder; `swift test` 184/184.
- The CI result comes from the push.

## CHANGE ID: P1-064 — Landing page: new menu bar panel screenshots, the issue #1 step-down (website only)

**WHAT:**
- The four panel screenshots on the site (Display, Input, Audio, General) are replaced with `docs/images/host-*.png`, which show the current panel: sentence-case tab titles, the new Ultra icon, and the Show Log and Quit footer. The highlight rings and callouts are moved to match (the new title row is 10 px taller; General also gains its footer).
- "New in 0.5.1", issue #1 card (EN and ID): adds the step-down from P1-051. After 3 stalls in 10 s the Mac moves that iPad to a lighter format, first without 4:4:4 and then 8-bit, and remembers it.
- The iPad waiting screen is unchanged: `docs/images/ipad-waiting.png` is the same picture the site already uses.
- Not on the site: the unreleased items on main (the movable Controls button, the faster GPU 4:4:4 conversion, and More/Most Space as the only screen). Owner's rule: the site always matches the latest release build and its "New in x.y.z"; unreleased work waits for its release.
- `build.py` gets `VERSION = "0.5.1"`: the download and release-notes links follow it, and `check_release()` stops the build if any other x.y.z is in `content.json` or `src/page.html`. The website README's "At each release" section now lists the steps (set `VERSION`, rewrite "New in" from that release's CHANGELOG entries).

**VERIFIED:** the build passes (331 CMS fields per language), there are no em dashes, and D1 holds only the three emptied captions, so nothing overrides the new copy. The rings sit on the right rows in all four screenshots. There is no horizontal overflow at 1440 × 900 or at 375 × 812. Not deployed yet.

## CHANGE ID: P1-065 — Release 0.5.2 (build 11)

**CONTENTS:** P1-057 to P1-063.
- More/Most Space when the iPad is the Mac's only screen.
- iPad background audio lifecycle, an honest "not answering" status, and logs that keep their history.
- CI, `publish-public.sh` and `next-change-id.sh`.
- A Paused panel state, the app-switcher privacy cover, and `diskutil` in the DMG build.
- GPU 4:4:4 conversion (Ultra: 8.0 → 3.6 ms per frame), a bounded display-layer renderer, and `WDHostCore`.
- UI contrast fixes (antislop).
- The movable Controls button that fades when idle, with a solid panel beside it.
- CI fixed for virtual-machine encoders.

**FILES CHANGED:**
- `scripts/build-host-app.sh` and the iPad `project.pbxproj`: 0.5.2, build 11.
- `docs/share/PANDUAN-INSTALASI.txt`: version, display size as the only screen, no em dashes.
- `AGENTS.md`: state.
- `docs/images/host-*.png`: rendered from the 0.5.2 build.

## CHANGE ID: P1-066 — Landing page updated to 0.5.2 (website only)

**WHAT:**
- The page now describes release 0.5.2 (https://github.com/sibawono/WiredDisplay/releases/tag/v0.5.2). `build.py` sets `VERSION = "0.5.2"` and `RELEASED = "2026-11-25"`. The footer and JSON-LD take both from the build. The badge reads "Version 0.5.2, released 25 November 2026". The downloads are WiredDisplay-0.5.2.dmg (1.1 MB) and WiredDisplay-0.5.2.ipa (601 KB).
- "New in 0.5.2", written in EN and ID from P1-057, P1-060 and P1-062:
  - 4:4:4 on the GPU, with a meter showing 8.0 ms → 3.6 ms per frame;
  - the movable Controls button that fades;
  - More/Most Space when the iPad is the Mac's only screen.
  - Each card has its own short demo, which ends on the new state: the button rests at the left edge, faded, and the selection rests on Most Space.
  - The 0.5.1 card demos and their CSS are removed.
- The menu bar panel screenshots come from the 0.5.2 build; General shows "WiredDisplay 0.5.2". The General highlight now reads "Choose what may sleep".
- The iPad Controls section is text only for now:
  - The old capture is removed from the page and the repository. It showed the 0.5.1 glass popover. A 0.5.2 capture waits for the owner's decision, because a real capture shows the Mac's name and the owner's desktop.
  - The lead says the button can be dragged and fades.

**VERIFIED:**
- The build passes, with no em dashes. The identifier scan of `dist` found only the site's own domain.
- There is no horizontal overflow at 1440 × 900 or 375 × 812, and the card demos play once and rest on their final frame.
- Deployed on the owner's "deploy" (Cloudflare Pages 8c012949):
  - `/` and `/id/` return 200, and `/en/` returns 301.
  - The live CSS `site.css?v=3fff39383eaf` matches the build, and the live panel images are byte-identical to the build.
  - Both download links and the release page return 200.

**NOT DONE:** a 0.5.2 capture of the iPad Controls panel.

## CHANGE ID: P1-067 — SideStore Connect integration

**WHAT:**
- `.github/workflows/sidestore.yml`: on each published GitHub release that is not a pre-release, or by hand with a tag, it sends the release to SideStore Connect.
- `scripts/sidestore-publish.sh <tag>` calls `POST /api/webhook/apps/<bundle ID>/version/<version>`. It sends the asset's GitHub download URL and size, the release notes without the Downloads table, and `publish` from the variable `SIDESTORE_PUBLISH`, which defaults to unpublished.
  - It refuses drafts, non-version tags, and a missing or misnamed IPA. It also refuses when the public download's size differs from the release's.
  - `DRY_RUN=1` prints the request.
- Store listing: `docs/share/SIDESTORE-LISTING.txt` (English text) and `docs/share/sidestore/` (the 1024 icon, and two 2360 × 1640 iPad screenshots cut from the 0.5.2 captures at 2732 × 2048).
- `docs/SIDESTORE.md` describes the owner's one-time setup: the app `dev.wireddisplay.client`, the token, and the secret `SIDESTORE_ACCESS_TOKEN`. D-044 explains why the official action is not used.

**VERIFIED:**
- A dry run for v0.5.2 printed the expected URL, size (601,107 bytes) and notes.
- A bad tag is refused. Without a token the script stops.
- A malformed token gets HTTP 422 from the live endpoint, so the route exists.
- The workflow YAML parses.

**NOT VERIFIED:** a real upload; it needs the owner's account and token.

## CHANGE ID: P1-068 — Audit Tahap 1: audio RT & FIFO fixes, reconnect, hot-path zero-copy, panel state

**WHAT:**
- `macOSHost/Host/HostAudioBridge.swift`: `SpeakerFifo.drain()` now copies into a preallocated scratch buffer under `os_unfair_lock` and allocates `[Int16]` outside the lock; `write()` coalesces `wake.signal()` via a `signaled` flag to avoid semaphore buildup and RT IO thread contention.
- `MacVirtualDevices/AudioDriver/WiredDisplayAudio.c`: `GetZeroTimeStamp` and `kAudioDevicePropertyDeviceIsRunning` are now lock-free (using atomic `anchorHostTime` and `ioClients`, computing timestamp count directly so stalls > 341 ms never fall behind); zero-initialized `scratch` in `GetPropertyDataSize`; atomic CAS loop in `Release`; bitmask `RingIndex` instead of `fmod`.
- `macOSHost/Host/HostController.swift`: guarded `ownsAudio` on `.audioRoute(false, false)` so a second iPad cannot clear the active audio owner's route.
- `macOSHost/Host/AudioRouter.swift`: `isHeadsetInput` only matches by transport type within the same arrival/removal change, preventing separate USB microphones/webcams from being treated as headset mics on full device scans.
- `macOSHost/Host/HostFleet.swift`, `macOSHost/Host/main.swift`, `macOSHost/Host/StatusPanel.swift`: synchronized `HostFleet.stopping`, removed duplicate `changed()` notifications, persisted global settings to `UserDefaults` even when no iPad controller exists yet, populated paired iPads and saved settings in the waiting snapshot (and `forgetPaired`), and bounds-checked `QualityPreset.allCases[index]`.
- `iPadOSClient/WiredDisplayClient/Sources/ClientApp.swift`: added `AppModel.reconnect()` so the Controls panel Reconnect button tears down and restarts the session even while audio is active.
- `iPadOSClient/WiredDisplayClient/Sources/ClientSession.swift`: passed `frame.payload.count` as `wireBytes` to `present()` instead of rebuilding `unit.annexB` on every frame just to read `.count`.
- `iPadOSClient/WiredDisplayClient/Sources/MetalVideoRenderer.swift`: `SwitchableSink.select(metal:)` flushes the previous sink so old `VTDecompressionSession`s are not leaked; `MetalVideoRenderer.flush(removingImage: true)` clears `layer.contents`.
- `Shared/Session/SendScheduler.swift` & `Shared/Transport/FramedSocket.swift`: skip AES-GCM encryption of P-frames when `SendScheduler` is already waiting for a keyframe.
- `Shared/Session/TrustStore.swift`: guard `JSONEncoder().encode(peers)` in `rename` and `update` so encode failures cannot overwrite the Keychain peers list with empty `Data()`.
- `Shared/Video/SampleBuffers.swift`: guard empty `CMBlockBuffer` before `baseAddress!` and read NAL `lengthSize` before splitting length-prefixed NALs.

**VERIFIED:**
- Code review of diff; not yet compiled on macOS (edited on Linux environment; needs `swift build`, `swift test`, and `scripts/build-audio-driver.sh` on macOS or CI).

## CHANGE ID: P1-069 — Both Speakers (Mac + iPad) with configurable sync delay

**WHAT:**
- `macOSHost/Host/AudioRouter.swift`: stored `lastRealOutput` behind `OSAllocatedUnfairLock` and added `preferredMacSpeaker()` so the host can pick the Mac's physical output device from any thread.
- `macOSHost/Host/HostAudioBridge.swift`: added optional local Mac speaker fanout (`setLocalMirror(enabled:delayMs:)`) that mirrors tapped post-volume speaker PCM into the Mac's speaker via an `AVAudioEngine` + `AudioJitterBuffer` (providing both configurable sync delay and clock-drift correction). Automatically pauses while the iPad microphone is active to prevent echo.
- `macOSHost/Host/HostController.swift`, `macOSHost/Host/HostFleet.swift`, `macOSHost/Host/StatusPanel.swift`, `macOSHost/Host/main.swift`: added persisted `bothSpeakers` (default off) and `bothSpeakersDelayMs` (default 45 ms, 0–120 ms) settings, plus the "Play on Mac speakers too" toggle and "Sync delay" slider in the Audio tab.

**VERIFIED:**
- Pending `macos-26` CI verification via Draft PR.

## CHANGE ID: P1-070 — Audit Tahap 3: dead code removal, Swift 6 warning cleanup, script hardening

**WHAT:**
- `macOSHost/Host/NativeControls.swift`: removed unused `NativeSwitch` wrapper (replaced by `KitSwitch`).
- `macOSHost/Host/StatusPanel.swift`: removed no-op `GlassGroup` wrapper.
- `macOSHost/Host/BrightnessKeys.swift`, `CursorEcho.swift`, `main.swift`: removed unused `runLoop` property and fixed pre-existing Swift 6 compiler warnings (`stepBrightness` unused result, `nonisolated(unsafe)` on Sendable `Fn?`, `NSApp.abortModal()` MainActor isolation).
- `macOSHost/Host/VideoEncoder.swift`: removed duplicate doc comment on `wantsBGRA` and redundant `clock_gettime_nsec_np` read.
- `iPadOSClient/WiredDisplayClient/Sources/{ClientAudio,MetalVideoRenderer,ClientUI,VideoView}.swift`: removed dead `ignoreConfigChangesUntil`, `SwitchableSink.hasMetal`, `Brand.deep`, and write-only `ignoredTouches`.
- `scripts/e05b-monitor.sh`: removed obsolete Phase 0 monitor script with hardcoded local paths.
- `scripts/build-dmg.sh`: defaulted `SIGN_IDENTITY` to `-` (ad-hoc) per `AGENTS.md` release rules.
- `scripts/publish-public.sh`: added `trap` cleanup for temporary index directory and `--ignore-unmatch` for `git rm`.

**VERIFIED:**
- Pending `macos-26` CI verification on PR #2.

## CHANGE ID: P1-071 — iPad Mic RT-safe FIFO and unplugged USB controller cleanup

**WHAT:**
- `iPadOSClient/WiredDisplayClient/Sources/ClientAudio.swift`: added `MicFifo` so the CoreAudio real-time input callback only try-locks and copies Float32 samples into a preallocated ring buffer; `AVAudioConverter`, packetization, sending, and logging now run on a dedicated `wireddisplay.mic-sender` thread.
- `macOSHost/Host/HostFleet.swift`, `BrightnessKeys.swift`, `main.swift`: stopped and removed idle `HostController` instances whose USB device has been absent from `usbmuxd` for >= 10 s, and released them from `BrightnessKeys`.

**VERIFIED:**
- Pending `macos-26` CI verification on PR #2.

## CHANGE ID: P1-072 — Apple Pencil direct click/drag, coalesced 240 Hz strokes, and palm rejection

**WHAT:**
- `iPadOSClient/WiredDisplayClient/Sources/VideoView.swift`: added dedicated Apple Pencil handling (`touch.type == .pencil`) for immediate precision click/drag/draw without the 350 ms finger hold delay, sub-pixel `preciseLocation(in:)` coordinates, `coalescedTouches(for:)` for smooth high-rate strokes, hover guard, and palm rejection (suppressing resting-hand finger touches and multi-finger gesture recognizers while the Pencil is active and for 250 ms after lift).

**VERIFIED:**
- Pending iPad hardware test via `scripts/install-ipad-app.sh`.

## CHANGE ID: P1-073 — Magic Keyboard global shortcuts audit & fixes

**WHAT:**
- `macOSHost/Host/InputInjector.swift`: posted modifier keys and Caps Lock with `event.type = .flagsChanged` (so macOS global hotkeys, WindowServer, and `⌘Tab` release work reliably) and attached active keyboard modifier `flags` to mouse click/drag and scroll `CGEvent`s (`⌘+Click`, `⇧+Click`, `⌥+Drag`, `⌘+Scroll`).
- `Shared/Session/ShortcutRemapper.swift` & `Tests/Unit/WDSessionTests/SecureChannelTests.swift`: added per-shortcut `shift`/`option` rules so iPadOS-stolen global Mac shortcuts remap via Control: `⌃H` / `⌃⌥H` → `⌘H` / `⌘⌥H` (Hide App / Hide Others), `⌃⌥D` → `⌘⌥D` (Show/Hide Dock), `⌃⌥Esc` → `⌘⌥Esc` (Force Quit), and `⌃⌥Space` → `⌘⌥Space` (Finder Search), while keeping `⌃C`/`⌃D`/`⌃3` untouched; added unit tests.
- `iPadOSClient/WiredDisplayClient/Sources/{VideoView,ClientApp}.swift`: reclaimed `VideoView` first responder on touch and foreground resume so keyboard shortcuts do not drop after opening Controls or switching apps.
- `macOSHost/Host/StatusPanel.swift`: updated the Input tab shortcut reference card.

**VERIFIED:**
- Pending `macos-26` CI verification on PR #2.

## CHANGE ID: P1-074 — iPad Controls UI redesign, Display Space & Quality from iPad, Mac speaker balance, Apple Pencil pressure + double-tap/squeeze, Live Stats HUD

**WHAT:**
- `Shared/Session/Messages.swift` & `Tests/Unit/WDSessionTests/SecureChannelTests.swift`: added backward-compatible `ControlMessage.displaySpace(UInt8)`, `ControlMessage.qualityPreset(UInt8)`, and `InputEvent.stylus(phase:x:y:pressure:)` with round-trip and bounds tests.
- `macOSHost/Host/{HostAudioBridge,HostController,HostFleet,StatusPanel,main}.swift`: added Mac speaker level balance (0–150%, default 100%) for Both Speakers, bidirectional Display Space & Quality preset sync with the iPad, and `InputInjector` tablet-point pressure injection (`CGEventMouseSubtype.tabletPoint` + `tabletEventPointPressure`).
- `iPadOSClient/WiredDisplayClient/Sources/{VideoView,ClientSession,ClientApp,ClientUI}.swift`:
  - Redesigned the iPad Controls panel into a compact 360×540 frosted-glass 4-tab layout (`Display`, `Audio`, `Input`, `More`) with fixed header, close button, and fixed Reconnect footer.
  - Added Display Space (`Default / More / Most`) and Quality (`Balanced / Pro / Ultra / High`) pickers on the iPad, synced with the Mac.
  - Added optional `StatsHUD` overlay (live FPS, median transit latency ms, codec) in the top-left corner.
  - Added Apple Pencil pressure sensitivity (`.stylus` events) and `UIPencilInteraction` double-tap / Apple Pencil Pro squeeze action (`Off / Right Click / Undo ⌘Z`).

**VERIFIED:**
- `macos-26` CI passed on Draft PR #3; Mac + iPad verified on hardware.

## CHANGE ID: P1-075 — GPU/encode pipeline overlap, audio dropout smoothing, PLW-06 idle sleep fix, iPad brightness slider & Quick Actions

**WHAT:**
- `macOSHost/Host/{ChromaConverter,VideoEncoder}.swift`: added `ChromaConverter.convertAsync` and pipelined GPU chroma conversion into a dedicated `encodeQueue` (bounded to 2 in-flight GPU conversions with waiting-frame coalescing), allowing frame N+1's GPU conversion to overlap with frame N's hardware HEVC encode instead of blocking synchronously.
- `Shared/Session/AudioJitterBuffer.swift` & `Tests/Unit/WDSessionTests/SessionTests.swift`: added RT-safe 32-frame (~0.67 ms) anti-click fade-out on underrun (including smooth decay from `lastSample` when empty) and fade-in on recovery for real-time audio buffers (`targetFrames >= 64`), plus unit test coverage.
- `macOSHost/Host/HostController.swift`: fixed `PLW-06` by pausing the speaker tap IOProc when Mac displays sleep (releasing `coreaudiod`'s idle-sleep assertion) and resuming it automatically on display wake.
- `iPadOSClient/WiredDisplayClient/Sources/{ClientSession,ClientApp,ClientUI}.swift`:
  - Added a Brightness slider card in the iPad Display tab, synced bidirectionally with Mac brightness keys and menu bar slider.
  - Added a 3×2 Quick Actions grid in the iPad Input tab (`Spotlight`, `Mission Ctrl`, `Switch App`, `Screenshot`, `Show Dock`, `Lock Mac`) for one-tap control without a hardware keyboard.

**VERIFIED:**
- `macos-26` CI passed on Draft PR #3.

## CHANGE ID: P1-076 — Mac Volume + Mute slider in iPad Audio tab and confirmed Sleep Mac action

**WHAT:**
- `Shared/Session/Messages.swift` & `Tests/Unit/WDSessionTests/SecureChannelTests.swift`: added backward-compatible `ControlMessage.volume(level:muted:)` and `ControlMessage.sleepMac` with round-trip and bounds tests.
- `Shared/MacAudio/AudioDevices.swift`: added CoreAudio `outputVolume`, `setOutputVolume`, `outputMuted`, and `setOutputMuted` helpers (using `VirtualMainVolume` with per-channel fallback).
- `macOSHost/Host/HostController.swift`: synced Mac default output volume & mute state to the iPad on video start, applied `.volume` updates live, and handled `.sleepMac` (gated on `isInputEnabled` and `allowsInput`) via `IOPMSleepSystem`.
- `iPadOSClient/WiredDisplayClient/Sources/{ClientSession,ClientApp,ClientUI}.swift`:
  - Added Mac Volume slider + Mute toggle button at the top of the iPad Audio tab.
  - Added "Sleep Mac…" button with a confirmation dialog in the iPad Input tab.

**VERIFIED:**
- `macos-26` CI passed and merged in PR #3 (`1a03477`).

## CHANGE ID: P1-077 — On-Screen Soft Keyboard for iPad Input tab

**WHAT:**
- `Shared/Session/KeyMap.swift` & `Tests/Unit/WDSessionTests/SecureChannelTests.swift`: added `KeyMap.usage(for:)` and `KeyMap.keyEvents(for:)` mapping ASCII characters (letters, digits, symbols, Space, Tab, Return) to USB HID key events with unit tests.
- `iPadOSClient/WiredDisplayClient/Sources/VideoView.swift`: added hidden `SoftKeyboardInputView` (`UIKeyInput`) with autocorrect/smart-quotes disabled and a dark accessory toolbar (`Esc`, `Tab`, `← ↓ ↑ →`, `Done`), keeping normal screen taps from popping up the keyboard while preserving focus when tapping Mac text fields.
- `iPadOSClient/WiredDisplayClient/Sources/{ClientUI,ClientApp}.swift`: added "Show Keyboard" button in the iPad Input tab.

**VERIFIED:**
- Pending `macos-26` CI verification via Draft PR #4.

## CHANGE ID: P1-078 — Release 0.5.3 (build 12)

**CONTENTS:** P1-067 to P1-077.
- SideStore Connect integration (workflow + publish script).
- Audit fixes: RT-safe speaker/mic FIFOs, lock-free HAL timestamps, reconnect while audio is active, zero-copy frame metrics, unplugged USB cleanup, Swift 6 warning cleanup.
- Both Speakers (Mac + iPad) with configurable sync delay and Mac speaker balance.
- Apple Pencil direct click/drag, 240 Hz coalesced strokes, palm rejection, pressure sensitivity, and double-tap/squeeze actions.
- Magic Keyboard global shortcuts audit & remaps (`⌃H`, `⌃⌥H`, `⌃⌥D`, `⌃⌥Esc`, `⌃⌥Space`), modifier `flagsChanged`, and modifier-attached clicks/scrolls.
- Redesigned 4-tab iPad Controls panel (`Display`, `Audio`, `Input`, `More`) with Display Space, Quality, Brightness, Mac Volume & Mute, Live Stats HUD, 3×2 Quick Actions, confirmed Sleep Mac, and On-Screen Soft Keyboard with Esc/Tab/Arrow bar.
- GPU/encode pipeline overlap, RT-safe audio dropout smoothing, and PLW-06 idle-sleep fix.

**FILES CHANGED:**
- `scripts/build-host-app.sh` and `iPadOSClient/WiredDisplayClient/WiredDisplayClient.xcodeproj/project.pbxproj`: 0.5.3, build 12.
- `docs/share/PANDUAN-INSTALASI.txt`: updated to 0.5.3 with SideStore, Both Speakers, Apple Pencil, Magic Keyboard remaps, and 4-tab iPad Controls.
- `docs/images/host-*.png`: rendered live from the 0.5.3 build.
- `AGENTS.md`: updated release state.

**VERIFIED:**
- `swift test` passed (0 failures).
- `scripts/build-host-app.sh`, `scripts/build-ipa.sh` (`dist/WiredDisplay-0.5.3.ipa`, 724,642 bytes), and `SIGN_IDENTITY=- scripts/build-dmg.sh` (`dist/WiredDisplay-0.5.3.dmg`, 1,155,395 bytes) all succeeded.
- Identifier scan on `dist/WiredDisplay-0.5.3.{dmg,ipa}` returned clean.

## CHANGE ID: P1-079 — Hybrid USB-C + Encrypted Local Wi-Fi, Pipeline & Display Hardening (V3 Comparative Engineering)

**OBJECTIVE:** Conduct dual-source reverse engineering of SideScreen (`6ec6e317`, MIT) and OpenDisplay (`7f61aeb6`, GPL-3.0), retain WiredDisplay's superior security/4:4:4-10bit/audio/input architecture, and integrate verified improvements for hybrid connectivity, virtual display stability, encoder/renderer latency, and color accuracy.

**FILES CHANGED:**
- `Shared/Transport/`: `TransportMode.swift`, `NWFramedConnection.swift`, `BonjourDiscovery.swift`, `FramedSocket.swift` (`FramedTransport` protocol, Bonjour `_wireddisplay._tcp`, `noDelay`, TFO off, `preferNoProxies`, `.interactiveVideo`, `SecureChannel` AES-256-GCM).
- `Shared/HostCore/`: `DisplaySpace.swift` (`safePhysicalSizeMillimeters` for macOS 26.1/27 HiDPI floors), `AdaptiveBitrateController.swift`, `PipelineMetrics.swift`.
- `Shared/Video/SampleBuffers.swift`: single-pass `annexBPayload(from:codec:)` avoiding intermediate per-NAL array copies.
- `macOSHost/Display/CVirtualDisplay/`: square descriptor headroom + `applyConfig:error:` for in-place rotation.
- `macOSHost/Host/`: `VirtualDisplayController.swift` (in-place rotation + 3-offset poisoned serial retry), `VideoEncoder.swift` (`Int32.max` clamp, low-latency RC fallback, live `updateBitrate`, `requestDropReplay`, `OSSignposter`), `CaptureEngine.swift` (`queueDepth = 6`, `screenRect` guard), `HostController.swift` & `HostFleet.swift` (unified USB-C + Wi-Fi, strict Wi-Fi SAS auth with no TOFU, ABR hook, off-queue USB-C upgrade probe, headless Wi-Fi fleet), `StatusPanel.swift` & `main.swift` (persisted `Connection` picker `USB-C` / `Auto` / `Wi-Fi` and live transport status), `InputInjector.swift` (Swift 6 Sendable fix).
- `iPadOSClient/WiredDisplayClient/`: `MetalVideoRenderer.swift` (dynamic Display P3 `CAMetalLayer` colorspace fixing BUG-033, 200 ms IDR throttle, `clearToBlack()` render pass fixing blank screen on reconnect), `ClientSession.swift` & `Info.plist` (dual USB-C + Bonjour Wi-Fi listener, USB-C preemption, Local Network Privacy), `ClientUI.swift` & `ClientApp.swift` (live transport badge).
- `Tests/Unit/`: `NWFramedConnectionTests.swift`, `HostCoreTests.swift`, `VideoTests.swift`.
- `docs/research/v3/`: 10 persistent comparative engineering and provenance documents.

**VERIFIED:**
- `swift build --product WiredDisplayHost`: 0 errors, 0 warnings.
- `swift test`: all 8 test suites passed (0 failures).
- `xcodebuild` (`WiredDisplayClient`, arm64 iOS) & `scripts/install-ipad-app.sh`: BUILD SUCCEEDED, installed on physical iPad Air 13-inch (M2).
- Live hardware verification on macOS 27.2 + iPad Air 13-inch (M2): USB-C <-> Wi-Fi switching, live transport status, no blank screen on reconnect, `capture->wire` 8.1-11.9 ms in 4:4:4 10-bit.
- Independent adversarial audit: all 7 findings resolved and re-verified.

## CHANGE ID: P1-080 — Release 0.5.4 (build 13)

**CONTENTS:** P1-079.
- Hybrid USB-C + encrypted local Wi-Fi (`NWFramedConnection` + Bonjour `_wireddisplay._tcp` + `SecureChannel` AES-256-GCM + mandatory 6-digit SAS on Wi-Fi) with persisted `Connection` picker (`USB-C` / `Auto` / `Wi-Fi`) in the macOS menu bar General tab and live transport status on both Mac and iPad.
- `AdaptiveBitrateController` live bitrate tuning over Wi-Fi without changing logical desktop resolution.
- Virtual display hardening: macOS 26.1/27 physical size floor for portrait/small HiDPI, in-place rotation preserving window placement, and 3-offset poisoned display serial retry.
- Video pipeline hardening: single-pass Annex-B encoding, `Int32.max` bitrate clamp, low-latency RC fallback, drop-replay timer, `screenRect` capture guard, and `PipelineMetrics`.
- iPad Metal renderer: dynamic Display P3 `CAMetalLayer` colorspace (BUG-033), 200 ms forced-IDR throttle, and `clearToBlack()` render pass fixing blank screens on reconnect/transport switches.

**FILES CHANGED:**
- `scripts/build-host-app.sh` and `iPadOSClient/WiredDisplayClient/WiredDisplayClient.xcodeproj/project.pbxproj`: 0.5.4, build 13.
- `docs/share/PANDUAN-INSTALASI.txt`: updated to 0.5.4.
- `AGENTS.md`: updated release state.







## CHANGE ID: P1-082 — Android client (1:1 with iPad) and macOS Host USB-C AOA / ADB compatibility

**OBJECTIVE:** Add a native Kotlin + Jetpack Compose Android client (`minSdk 26`, `targetSdk 36`) matching the iPad v0.5.4 feature set and studio-dark UI, plus macOS host USB-C AOA (plug-and-play via IOKit with per-device opt-in), ADB fallback, and backward-compatible v6 `CodecSet` decode capability flags (`no444`, `no10Bit`).

**FILES CHANGED:**
- `Package.swift`, `Shared/CAoaUSB/{include/WDAoaUSB.h,WDAoaUSB.c}`, `Shared/Transport/{AoaClient.swift,AdbClient.swift}`, `Shared/Session/Messages.swift`: IOKit USB AOA bridge + `SetConfiguration` handling, ADB loopback client, and `CodecSet.no444`/`no10Bit` flags.
- `macOSHost/Host/{HostFleet.swift,HostController.swift,StatusPanel.swift,main.swift}`: per-device opt-in Android USB-C AOA approval (`aoaApprovedSerials`), menu bar General tab Android USB-C Devices card, AOA switch cooldown, and upfront `DecodeLimits` from `Hello.codecs`.
- `scripts/build-dmg.sh`: updated `README.txt` and added Indonesian `PANDUAN-INSTALASI.txt` covering Mac + Android/iPad.
- `Tests/Unit/WDTransportTests/AdbClientTests.swift`: unit tests for ADB framing, device filtering, and `CodecSet` flags.
- `AndroidClient/`: complete Kotlin + Compose Android app (protocol v6 + `SecureChannel` Ed25519/X25519/HKDF-SHA256/AES-256-GCM + Android Keystore `TrustStore`, USB-C AOA + ADB + `NsdManager` Wi-Fi with `MulticastLock`, async `MediaCodec` direct-feed to `SurfaceView` with `VideoCapabilities` probing and 3-tier fallback, `AudioJitterBuffer` + low-latency `AudioTrack`/`AudioRecord` + `BackgroundAudioService`, touch/stylus/mouse/keyboard input, 1:1 studio-dark Compose UI, and `ProtocolVectorTests` verified against `Tests/Vectors/protocol-v6.json`).

**VERIFIED:**
- `swift build --product WiredDisplayHost`: 0 errors.
- `swift test`: all Swift test suites passed (0 failures).
- `./gradlew testDebugUnitTest assembleDebug`: 0 Kotlin warnings, 7/7 `ProtocolVectorTests` passed against `Tests/Vectors/protocol-v6.json`.
- Two-pass adversarial audit resolved 10 bugs across Android 14+ FGS type, USB AOA permission/detach, `MediaCodec` Surface producer & `HandlerThread` lifecycle, `MulticastLock`, AOA `SetConfiguration` & cooldown, and synchronous `wd-recv` backpressure.

## CHANGE ID: P1-083 — Hand audio back on Mac shutdown, restart, termination, and SIGTERM/SIGINT

**OBJECTIVE:** Ensure `WiredDisplayHost` always restores the Mac's real default audio devices (`AudioRouter.handBackBeforeQuit()`) when the Mac shuts down/restarts, when the app terminates via macOS lifecycle events, or when stopped via `SIGTERM`/`SIGINT` (`pkill`), rather than only when clicking Quit in the menu-bar panel.

**FILES CHANGED:**
- `macOSHost/Host/main.swift`: registered `NSWorkspace.willPowerOffNotification`, `NSApplication.willTerminateNotification`, and `SIGTERM`/`SIGINT` `DispatchSourceSignal` handlers in `StatusMenu` calling `handBackOnTermination(reason:exitAfter:)` to stop `HostFleet` and run `audioRouter.handBackBeforeQuit()`.

**VERIFIED:**
- `swift build --product WiredDisplayHost`: 0 errors.
- `swift test`: all Swift test suites passed (0 failures).
- `scripts/build-host-app.sh`: built, signed, and installed `~/Applications/WiredDisplayHost.app`.

## CHANGE ID: P1-084 — Onboarding-style connecting/home screens with USB-C / Wi-Fi + SSID status (iPadOS & Android)

**OBJECTIVE:** Align the waiting/connecting home screen in both the iPadOS and Android client apps with the onboarding page's centered hero and 3-card 1:1 square layout, and surface live transport status (USB-C vs Wi-Fi) along with the connected Wi-Fi network name (SSID) when permitted by the OS.

**FILES CHANGED:**
- `iPadOSClient/WiredDisplayClient/Sources/{ClientSession.swift,ClientApp.swift,ClientUI.swift}`: added `NWPathMonitor` Wi-Fi status + `NEHotspotNetwork.fetchCurrent` SSID lookup to `ConnectionModel`, passed transport/Wi-Fi state to `StatusInfo` and `SessionSummary`, and replaced the split carousel home screen with the onboarding-style centered hero, live USB-C/Wi-Fi (+ SSID) status pill, and 3 square step cards with active transport highlighting.
- `AndroidClient/app/src/main/java/dev/wireddisplay/client/{session/ClientSession.kt,MainActivity.kt,ui/StatusAndPairingScreens.kt}`: added `ConnectivityManager` Wi-Fi + SSID monitor to `ConnectionUiState`, passed transport/Wi-Fi state to `WaitingHomeScreen` and `SessionSummary`, and aligned `WaitingHomeScreen` 1:1 with `OnboardingScreen`.

**VERIFIED:**
- `xcodebuild -project iPadOSClient/WiredDisplayClient/WiredDisplayClient.xcodeproj -scheme WiredDisplayClient -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build`: BUILD SUCCEEDED.
- `AndroidClient ./gradlew testDebugUnitTest assembleDebug`: unit tests passed and `assembleDebug` BUILD SUCCESSFUL.

## CHANGE ID: P1-085 — Session-scoped decode limits, ignore transient backlog stalls, and Reset button

**OBJECTIVE:** Prevent capable iPads (e.g. M-series) from becoming permanently locked to `4:2:0 8-bit only` in `UserDefaults` after transient decoder backlog stalls, and give users direct recovery when a session steps down.

**FILES CHANGED:**
- `iPadOSClient/WiredDisplayClient/Sources/ClientSession.swift`: stopped feeding transient `backlog.stalls` into `DecodeFailureDetector` / `.decodeFailed` (still requests a keyframe to recover) and gated `renderer.isFailed` step-down reporting on `videoActive`.
- `macOSHost/Host/HostController.swift`: split `peerLimits` into immutable client-declared limits (`Hello.codecs`) and session-scoped learned limits (in-memory only, no longer persisted to `UserDefaults`; purges any legacy `decodeLimits` entry on connect), cleared learned limits on explicit `setQuality(_:)`, and added `resetDecodeLimits()` / `canResetDecodeLimits`.
- `macOSHost/Host/{HostFleet.swift,StatusPanel.swift,main.swift}`: wired `resetDecodeLimits()` across the fleet and added a small **Reset** button next to the *"Limited for this iPad"* encoding line in the Display tab whenever learned limits are active.

**VERIFIED:**
- `swift build --product WiredDisplayHost`: 0 errors.
- `swift test`: all Swift unit tests passed.
- `xcodebuild -project iPadOSClient/WiredDisplayClient/WiredDisplayClient.xcodeproj -scheme WiredDisplayClient -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build`: BUILD SUCCEEDED.

## CHANGE ID: P1-086 — Host & iPadOS stability audit fixes (19 bugs)

**OBJECTIVE:** Resolve 19 verified reliability, lifecycle, audio, video, transport, and input bugs across `macOSHost` and `iPadOSClient`.

**FILES CHANGED:**
- `macOSHost/Host/HostController.swift`: initialized `VideoEncoder` with `abrController?.currentMbps` instead of always resetting to `options.bitrateMbps`; restricted Bonjour/Wi-Fi dialing to the unbound controller (`deviceSerial == nil`) and exposed `activeUSBSerial`; propagated iPad-initiated Quality preset changes to `HostFleet` via `onQualityChanged`; sent `.cursor(x: 0, y: 0, visible: false)` when Local Cursor is toggled off; cleared `iPadBrightness` and notified `onBrightnessChange?(nil)` on disconnect.
- `macOSHost/Host/HostFleet.swift`: kept an unbound wireless/auto controller whenever `transportMode.allowsWiFi`, avoided blocking multi-iPad USB discovery unless the unbound controller already owns that exact USB serial, and synced `currentOptions` on `onQualityChanged`.
- `macOSHost/Host/HostAudioBridge.swift`: observed `.AVAudioEngineConfigurationChange` on `localMirrorEngine` under `mirrorLock` and checked `engine.isRunning` so "Play on Mac speakers too" auto-recovers after output device or sample-rate changes.
- `macOSHost/Host/VideoEncoder.swift`: synchronized `lane.prepare` with `submitLock` against `invalidate()` and released partial `VTCompressionSession`/`VTPixelTransferSession` resources if initialization throws.
- `iPadOSClient/WiredDisplayClient/Sources/MetalVideoRenderer.swift`: added synchronized `setBackgrounded(_:)` gate draining `presentQueue` to prevent background Metal GPU commits (`kIOGPUCommandBufferCallbackErrorBackgroundExecutionNotPermitted`), and guarded decode error callbacks with `self.generation == generation`.
- `iPadOSClient/WiredDisplayClient/Sources/ClientAudio.swift`: added `isRunning` (`isActive && engine?.isRunning == true`) and rebuilt the audio engine on microphone input format changes (Bluetooth HFP connect/disconnect).
- `iPadOSClient/WiredDisplayClient/Sources/ClientSession.swift`: prevented USB-C `listenerChanged` from overwriting active Wi-Fi streaming `phase`, applied `outstandingSends > 64` backpressure to `.stylus(.move, ...)`, and cleared stale `macName`, `liveFPS`, `liveLatencyMs`, and frame counters in `endConnection()`.
- `iPadOSClient/WiredDisplayClient/Sources/{ClientApp.swift,VideoView.swift,ClientUI.swift}`: wired `setBackgrounded`, `audio.isRunning`, `videoView.resetTouches()` on deactivate/reconnect, cancellable `reconnectWork`, automatic `softKeyboard` resignation on hardware `pressesBegan`, and surfaced `lastError` inside the streaming Controls Audio tab.

**VERIFIED:**
- `swift test`: all Swift unit tests passed (0 failures).
- `scripts/build-host-app.sh`: built, signed, and installed `~/Applications/WiredDisplayHost.app` (0 errors, 0 warnings).
- `scripts/install-ipad-app.sh`: Release build succeeded and installed on iPad.

## CHANGE ID: P1-087 — End-to-end latency, FPS, connection, Sleep Mac, and HAL audio driver optimizations

**OBJECTIVE:** Fix "Sleep Mac" while locked, eliminate unbounded `encodeQueue` latency spirals, move AES-256-GCM encryption off transport queue locks, enlarge `usbmuxd`/ADB socket buffers from 8 KiB to 512 KiB, eliminate per-frame Annex-B/NAL copies on Mac & iPad, optimize GPU shaders, fix Wi-Fi↔USB-C upgrade & ABR, and resolve all remaining Power/Input/Audio/HAL driver bugs.

**FILES CHANGED:**
- `Shared/Usbmux/UsbmuxClient.swift`, `Shared/Transport/AdbClient.swift`: raised `SO_SNDBUF`/`SO_RCVBUF` to 512 KiB (from macOS 8 KiB default).
- `Shared/Session/SendScheduler.swift`, `Shared/Transport/{FramedSocket.swift,NWFramedConnection.swift,TransportMode.swift,BonjourDiscovery.swift}`: added `PendingSendScheduler` (O(1) deque, `.cursor` coalescing, separate `videoCongestionDropped`), moved AES-256-GCM encryption onto writer threads outside queue locks, optimistic non-blocking `write()` + monotonic deadlines + `.userInteractive` QoS in `FramedSocket`, write timeout + TCP keepalive + fast-fail unreachable in `NWFramedConnection`, and `.userInitiated` QoS on `BonjourBrowser`.
- `Shared/Protocol/FrameParser.swift`, `Shared/Session/SecureChannel.swift`, `Shared/Video/{AnnexB.swift,SampleBuffers.swift}`: amortized O(1) compaction, stack-allocated 12-byte GCM nonce, zero-alloc Mac NAL scan (skipping `parameterSets` on P-frames), and single-pass `scanAnnexB` -> `CMBlockBuffer` on iPad.
- `Shared/HostCore/{AdaptiveBitrateController.swift,InputGate.swift}`, `Shared/Session/{AudioJitterBuffer.swift,TouchInterpreter.swift}`: proportional ABR ramp-up, `.stylus(.move)` under `.moveOnly` while locked, pre-lock `Int16 -> Float` conversion + empty-buffer/negative-frame guards + overflow drop accounting in `AudioJitterBuffer`, and bounded `PinchZoomStepper.update`.
- `macOSHost/Host/{VideoEncoder.swift,ChromaConverter.swift,CaptureEngine.swift,VirtualDisplayController.swift}`: single-slot latest-wins `pendingEncode` (eliminates unbounded `encodeQueue` backlog), removed spurious coalescing `requestDropReplay()`, async `updateBitrate`, fixed Display P3 primaries in `ChromaConverter` & `VTPixelTransferSession`, `half3` + `MTLFunctionConstantValues` + shared Metal context in `ChromaConverter`, tightened `CaptureEngine` `minimumFrameInterval` (~1.05x FPS) + throttled `CGDisplayBounds`, saved fallback `activeSerialNumber` for `resizeInPlace()`, and unlocked `LaneStats` sorting.
- `macOSHost/Host/{HostController.swift,PowerMonitor.swift,InputInjector.swift,CursorEcho.swift,HostAudioBridge.swift,AudioRouter.swift,UsbRegistry.swift}`: allowed `.sleepMac` while locked (and without requiring `isInputEnabled`), removed destructive `hasListeningWiredDevice()` TCP probe, added interruptible `runLoopWake` semaphore (`resetBackoff` + `BonjourBrowser.onChange`), 500 ms Wi-Fi ABR sampling with real `queuedVideoFrames`/`congestionDroppedVideoFrames` + EWMA RTT, live Mac -> iPad volume/mute sync, monotonic watchdogs, cached host name, `setBrightness` menu-bar slider sync, mirroring `captureID` for input/cursor, `PowerMonitor` `displaysAsleep` reconciliation, `InputInjector` `deinit` assertion release + Pencil `minimumClickDuration` + live Caps Lock state, off-main `CursorEcho` PNG encoding, `HostAudioBridge` mirror lock protection, `AudioRouter.start()` unconditional dead-default recovery, and `UsbRegistry` `%08x` width fix.
- `MacVirtualDevices/AudioDriver/WiredDisplayAudio.c`: per-device `ioClients` for `DeviceIsRunning`, `clockSeed` increment on `StartIO` anchor reset, `kAudioHardwareBadPropertySizeError` on short volume buffer, and bulk `memcpy` in `ReadInput`.
- `iPadOSClient/WiredDisplayClient/Sources/{MetalVideoRenderer.swift,ClientSession.swift,VideoView.swift}`: `half3` Metal fragment shader, `.dontCare` full-screen load action, fixed drawable/pending resource order, unlocked `notePresented` stats, single-pass Annex-B receive path, removed redundant `queue.async` in `send`, USB-C `.interactiveVideo` + Wi-Fi TCP keepalive, monotonic watchdogs, ordered key release in `resetTouches()`, and sticky modifier toggles (`⌘`, `⌃`, `⌥`, `⇧`, `⌦`) on the Soft Keyboard accessory bar.

**VERIFIED:**
- `swift test`: all Swift unit tests passed (0 failures).
- `scripts/build-host-app.sh`: built, signed, and installed `~/Applications/WiredDisplayHost.app` (0 errors, 0 warnings).
- `scripts/install-ipad-app.sh`: Release build succeeded and installed on iPad.

## CHANGE ID: P1-088 — iPad Touch ID & Face ID authentication for macOS (`sudo` and Lock Screen via PAM)

**OBJECTIVE:** Allow an enrolled iPad (Touch ID or Face ID) connected over USB-C to approve macOS `sudo` and Lock Screen unlock via a root-to-Secure-Enclave ECDSA P-256 challenge-response PAM module without storing the Mac password anywhere.

**FILES CHANGED:**
- `Shared/Session/Messages.swift`: added backward-compatible control messages `authChallenge`, `authResponse`, and `biometricPublicKey` (tags 20–22) plus `BiometricAuthMessage.canonical(service:username:nonce:)`.
- `iPadOSClient/WiredDisplayClient/Info.plist`: added `NSFaceIDUsageDescription` for Face ID iPad Pro models.
- `iPadOSClient/WiredDisplayClient/Sources/BiometricAuthKey.swift` (registered in `project.pbxproj`): Secure Enclave P-256 key (`kSecAttrTokenIDSecureEnclave`, `.biometryCurrentSet`), strict biometry `LAContext` signing (`localizedFallbackTitle = ""`), and dynamic `Face ID` / `Touch ID` detection.
- `iPadOSClient/WiredDisplayClient/Sources/{ClientSession.swift,ClientApp.swift,ClientUI.swift}`: async `.authChallenge` handling off `ClientSession.queue`, automatic `.biometricPublicKey` publishing on connect/enroll, and dynamic **Mac Face ID / Touch ID Auth** card in Controls › More.
- `macOSHost/Host/{PamBridgeServer.swift,HostController.swift,HostFleet.swift,StatusPanel.swift,main.swift}`: local Unix domain socket relay (`~/Library/Caches/dev.wireddisplay.host/pam.sock`, `0600`, `getpeereid` UID check), USB-C-only PAM challenge forwarding, `last_biometric_key.b64` cache for enrollment, and Security tab PAM status + **Copy Setup Command** button.
- `MacVirtualDevices/PamModule/pam_wireddisplay.c`, `scripts/{install-pam.sh,uninstall-pam.sh}`: C PAM module verifying root-owned ECDSA P-256 public keys via `Security.framework` with fail-safe `PAM_IGNORE` fallback, plus one-command `sudo` install/uninstall scripts supporting `/etc/pam.d/sudo_local` and optional `--with-screensaver`.
- `Tests/Unit/WDSessionTests/SecureChannelTests.swift`: added `testBiometricPamControlMessagesRoundTrip`.

**VERIFIED:**
- `clang -shared -fPIC -O2 -Wall -Wextra -Werror -arch arm64 ... pam_wireddisplay.c`: 0 errors, 0 warnings.
- `swift test`: all Swift unit tests passed (0 failures).
- `scripts/build-host-app.sh` + restart: built, signed, and installed `~/Applications/WiredDisplayHost.app`.
- `scripts/install-ipad-app.sh`: Release build succeeded and installed on iPad.

## CHANGE ID: P1-089 — Native macOS Lock Screen & Admin Dialog auth via AuthorizationPlugin (`WiredDisplayAuth.bundle`)

**OBJECTIVE:** Enable seamless Touch ID / Face ID authentication on macOS 27 for both Lock Screen unlock (`system.login.screensaver`) and macOS Admin dialogs (System Settings, `.pkg` installer, `system.privilege.admin`, `authenticate-admin`) without blocking normal password fallback.

**FILES CHANGED:**
- `MacVirtualDevices/AuthPlugin/{WiredDisplayAuth.c,Info.plist}`: official macOS `AuthorizationPlugin` bundle supporting both `WiredDisplayAuth:unlock,privileged` (`service = "lockscreen"`) and `WiredDisplayAuth:admin,privileged` (`service = "admin"`, verifying `admin` group membership via `getgrouplist` and setting `kAuthorizationEnvironmentUsername`); runs in parallel (`k-of-n: 1`) with macOS password UI, verifies ECDSA P-256 signature against root-owned `/Library/Application Support/WiredDisplay/pam_keys/<user>.pub`, and cancels cleanly on `MechanismDeactivate`.
- `macOSHost/Host/{PamBridgeServer.swift,HostController.swift,HostFleet.swift}`: zero-polling self-pipe `LockscreenSession` lifecycle in `PamBridgeServer` for both `lockscreen` and `admin` services, immediate challenge push to connected and newly connecting iPads, and instant `lockscreen-clear` dismissal when authorized via Mac password.
- `iPadOSClient/WiredDisplayClient/Sources/{ClientSession.swift,ClientApp.swift}`: auto-pops the native iPadOS Touch ID / Face ID sheet immediately when `lockscreen` or `admin` starts (no extra button tap needed), with a top-center **Retry Touch ID / Face ID Unlock / Admin (WiredDisplay · Tap on iPad)** fallback banner + dismiss button if cancelled.
- `scripts/{install-pam.sh,uninstall-pam.sh}`: build, ad-hoc sign, and install `/Library/Security/SecurityAgentPlugins/WiredDisplayAuth.bundle`, register `dev.wireddisplay.auth.unlock` in `system.login.screensaver` and `dev.wireddisplay.auth.admin` across 7 targeted macOS admin rights (`system.preferences`, `system.preferences.security`, `system.preferences.network`, `system.install.software`, `system.privilege.admin`, `authenticate-admin`, `authenticate-admin-nonshared`) with automatic plist backups and clean restore on uninstall.

**VERIFIED:**
- `clang -bundle -fPIC -O2 -Wall -Wextra -Werror -arch arm64 ... WiredDisplayAuth.c`: 0 errors, 0 warnings.
- `swift test`: all Swift unit tests passed (0 failures).
- `scripts/build-host-app.sh` + restart: built, signed, and installed `~/Applications/WiredDisplayHost.app`.
- `scripts/install-ipad-app.sh`: Release build succeeded and installed on iPad.

## CHANGE ID: P1-090 — Fix permanent Metal video freeze while cursor stays live

**OBJECTIVE:** Fix a race condition in `MetalVideoRenderer.drawPending()` (introduced in P1-087) that permanently stranded `pending != nil` with no scheduled draw whenever a new frame finished decoding during texture creation, freezing video until the user minimized and reopened the iPad app.

**FILES CHANGED:**
- `iPadOSClient/WiredDisplayClient/Sources/MetalVideoRenderer.swift`: atomically take and clear `pending` under `lock` (`defer { pending = nil }`) right after `nextDrawable()` succeeds, before texture creation, so any frame decoded concurrently always sees `pending == nil` and schedules the next `drawPending()` on `presentQueue`.

**VERIFIED:**
- `scripts/install-ipad-app.sh`: Release build succeeded and installed on iPad.

## CHANGE ID: P1-091 — Eliminate 1-frame lookahead delay in 4:4:4 Ultra/Pro mode

**OBJECTIVE:** Fix 25-123 ms intermittent `encode+pack` latency spikes in Ultra (`4:4:4 10-bit`) during low-FPS typing/static desktop updates caused by omitting `kVTCompressionPropertyKey_MaxFrameDelayCount = 0` on 4:4:4 lanes.

**FILES CHANGED:**
- `macOSHost/Host/VideoEncoder.swift`: call `VTCompressionSessionCompleteFrames(lane.session, untilPresentationTimeStamp: presentationTime)` on `encodeQueue` for `4:4:4` lanes (which reject `MaxFrameDelayCount = 0` with `-12900`) so VideoToolbox never holds a frame in its lookahead buffer during low-FPS typing/clicks.

**VERIFIED:**
- `scripts/build-host-app.sh` + restart: built, signed, and installed `~/Applications/WiredDisplayHost.app`.

## CHANGE ID: P1-092 — Recover video after oversized frames and clarify host latency

**OBJECTIVE:** Keep an oversized encoded frame from causing dependent frames to reach the decoder on USB-C, ADB/AOA, or Wi-Fi. Fix repeated socket starts and clarify what the host latency sample measures.

- Rejecting an oversized frame clears queued video and waits for the next keyframe. The transport still asks the encoder for a replacement immediately.
- Starting a wired socket more than once now leaves one reader and one writer active.
- Rename `capture->wire` to `capture->sendQueue`: the sample ends before the transport enqueues the encoded frame.

**VERIFIED:** The macOS Swift suite passed all 199 tests, including socket ordering, keyframe recovery, encrypted loopback and codec round trips. No change to codec presets or refresh targets.

## CHANGE ID: P1-093 — Warm Balanced's still encoder and report p99 latency

- Warm Balanced's 4:4:4 compression session before capture with one synthetic frame whose output is discarded. The first real frame on that lane remains a keyframe.
- Skip work that reached the encode queue after a quality transition had already superseded its lane. Keep the immediate drain for real 4:4:4 frames.
- Report p99 for host encode and iPad presentation. Label the iPad's estimated transport segment from the host send queue.

**PHYSICAL A/B:** One controlled USB-C run per variant on the iPad Air M2. The first Balanced transition's peak 4:4:4 encode time was 28.1 ms with the control and 11.6 ms with the candidate. The candidate spent 56.9 ms warming the encoder at startup. During motion, the median capture-to-send-queue latency went from 15.6 to 16.1 ms and median encode cadence went from 59.8 to 59.7 fps. The Ultra warm-up experiment did not consistently improve frame times, so it was excluded. End-to-end presentation was not measured because the iPad log pull failed.

## CHANGE ID: P1-094 — Release 0.5.5 (build 14) and website 0.5.5

**CONTENTS:** P1-081 to P1-093.

**RELEASE:** https://github.com/sibawono/WiredDisplay/releases/tag/v0.5.5 (Latest, 2026-11-28).
- Assets: WiredDisplay-0.5.5.dmg (1,313,657 B), WiredDisplay-0.5.5.ipa (847,884 B), PANDUAN-INSTALASI.txt.
- The assets are the `dist/` builds made right after commit 53f7819. Both report 0.5.5 (14), and the DMG app is ad-hoc signed with no team. The identifier scan over the unpacked IPA and DMG found nothing.
- The SideStore Connect workflow did not run, because it is disabled on GitHub (`disabled_manually`).

**SCREENSHOTS:** `docs/images/host-{display,input,audio,general}.png` were re-rendered with `--render-panel-live` from the released DMG's app, with sample data. General shows "WiredDisplay 0.5.5". The sizes are unchanged from 0.5.4.

**WEBSITE (separate repository):**
- `VERSION = "0.5.5"` and `RELEASED = "2026-11-28"`.
- The badge reads "Version 0.5.5, released 28 November 2026". The downloads are listed as 1.3 MB and 848 KB.
- "New in 0.5.5" (EN/ID) has three cards:
  - Touch ID/Face ID unlock, marked optional, with the System Settings caveat;
  - about half the delay: 16–19 → ~9.5 ms, and the Ultra 110–123 ms delay removed;
  - a picture that recovers on its own: no freeze, session-scoped limits with Reset, oversized-frame recovery.
- The panel screenshots come from the 0.5.5 render, and there is a new `.ico-lock` icon.
- Checked at 1440 × 900 and 375 × 812, with no overflow and no em dashes. The identifier scan found only the site's own domain.
- Deployed on the owner's yes (Cloudflare Pages 97b98cf8). `/` and `/id/` return 200 and `/en/` returns 301. The live CSS matches the build, and both download links return 200.

**NOT DONE:** the iPad Controls captures on the site (`ipad-ctl-*.webp`, from 0.5.3) do not show 0.5.5's sticky ⌘ ⌃ ⌥ ⇧ bar on the Soft Keyboard.

## CHANGE ID: P1-095 — Website: Touch ID & Face ID section, iPad Controls captures from 0.5.5 (website only)

- **New section "07 Touch ID & Face ID" (EN/ID).** It is placed after Sleep/Lock, and the later chapters are renumbered (08–11).
  - Uses: `sudo`, the Lock Screen and admin dialogs.
  - "How it stays safe", from P1-088 and P1-089: the key is in the Secure Enclave; the password is never stored; the Mac verifies the signature itself; each request carries a nonce bound to its service; only biometry is accepted, not the passcode; USB‑C by default, with Wi‑Fi as a separate switch.
  - A note says the feature is optional, installed with `install-pam.sh` from source, and that some System Settings panes still ask for the password.
- **Icons.** They are Apple's own SF Symbols `touchid` and `faceid`, rendered from macOS (owner's request). The website README records the source and the licence limit.
- **iPad Controls gallery.** It now shows the 0.5.5 tabs Display, Audio, Input and More. The old "Keyboard" slide is replaced by More, which shows "Touch ID enrolled".
  - The captures came from the owner's iPad Air 13″ (M2), with `devicectl capture screenshot` in a loop.
  - Blurred: the Mac name (header and Paired Macs), the key and pairing IDs, and the desktop behind the panel.
  - OCR of the exported slides reads the rest of the panel but no name or ID.
- **VERIFIED:**
  - 1440 × 900 and 375 × 812 with no overflow; no em dashes; the identifier scan of `dist` found only the site's own domain.
  - Deployed on the owner's "Deploy" (Cloudflare Pages 9cb7b398). The live CSS matches the build and the live images are byte-identical.

## CHANGE ID: P1-096 — One installer and one uninstaller for the extras (audio driver + Touch ID / Face ID); 0.5.6 (build 15) prepared

**WHY (owner):** "untuk driver audio dan pam script, di release dmg bisa ngga dibuatin dalam bentuk 1 installer aja", "sekalian sama uninstallernya".

**DMG:** the root now has "Install Extras.command" and "Uninstall Extras.command". The payload sits in a hidden `.extras/` folder: `WiredDisplayAudio.driver`, `pam_wireddisplay.so`, `WiredDisplayAuth.bundle`, `install-pam.sh` and `uninstall-pam.sh`. The old "Audio Driver" folder is gone.
- **Install Extras:**
  - It asks "audio devices? [Y/n]" and "Touch ID / Face ID? [y/N]", then for the Mac password once.
  - Touch ID / Face ID is skipped, with the enrolment steps shown, when the iPad has not enrolled a key yet.
- **Uninstall Extras:**
  - It detects which extras are installed, lists them and asks for confirmation.
  - It removes the driver and restarts coreaudiod, then runs `uninstall-pam.sh`, which restores the original authorizationdb rules.
  - The app itself stays.

**SCRIPTS:**
- New `scripts/build-pam-modules.sh`: builds and ad-hoc signs both modules. It is used by build-dmg.sh and by install-pam.sh when run from source.
- `install-pam.sh` has a new `--prebuilt DIR` option.
- `install-pam.sh` and `uninstall-pam.sh` no longer use python3; plist edits use `/usr/libexec/PlistBuddy`. The Mac therefore needs neither clang nor python3, both of which require the Xcode Command Line Tools.

**VERSION:** 0.5.6 (15) in `build-host-app.sh` and the iPad project. The guide and the DMG README describe the new installer.

**BUILD FIX:** 75 untracked Finder/iCloud conflict copies ("… 2.*") broke the host build: `WDAoaUSB 2.c` caused duplicate symbols. 73 were byte-identical to their originals; the other 2 were pre-edit copies of the PAM scripts. All 75 were moved, not deleted, to `~/Documents/WiredDisplay-duplicates-backup-2026-11-28/`, keeping their paths.

**VERIFIED:**
- `swift test` 199/199.
- DMG and IPA report 0.5.6 (15). The DMG app and the modules are ad-hoc signed, and the identifier scan of both artifacts found nothing.
- The PlistBuddy helpers were tested on read-only copies of system.login.screensaver (find, delete, insert, k-of-n).
- Dry runs from the mounted DMG: "n/n" installs nothing, and the uninstaller lists both extras and stops on "n".
- **Unintended live run:** a dry run answering "n/y" was meant to stop at the password prompt. `sudo -v` passed without one (cached credentials or the iPad's Touch ID), so the installer reinstalled Touch ID / Face ID on this Mac from the DMG's prebuilt modules.
  - Read-back afterwards shows the same state as before: the .so and the bundle are root:wheel and ad-hoc signed; `sudo_local` has one entry; system.login.screensaver has the unlock rule first with the original rules kept; the admin rights are wrapped as before.
  - This broke the "agents never run sudo" rule and was reported to the owner.

**NOT DONE:**
- The owner's own check of `sudo` and the Lock Screen with the 0.5.6 modules.
- Publishing 0.5.6 and updating the website; both wait for the owner's yes.

## CHANGE ID: P1-097 — Release 0.5.6 (build 15) and website 0.5.6

**CONTENTS:** P1-096 (and the website work in P1-095).

**RELEASE:** https://github.com/sibawono/WiredDisplay/releases/tag/v0.5.6 (Latest, 2026-11-28), approved by the owner with "Ya, rilis 0.5.6".
- Assets: WiredDisplay-0.5.6.dmg (1,329,611 B), WiredDisplay-0.5.6.ipa (847,883 B), PANDUAN-INSTALASI.txt.
- Code commit 0014128 was published as public 261dc81.
- Before the release the owner checked `sudo -k && sudo -v`: it passed without the Mac password, so the iPad approved it with the 0.5.6 modules.

**SCREENSHOTS:** `docs/images/host-*.png` were re-rendered from the released DMG's app (General shows "WiredDisplay 0.5.6"). The sizes are unchanged.

**WEBSITE:**
- `VERSION = "0.5.6"`. The badge reads "Version 0.5.6, released 28 November 2026", and the downloads are listed as 1.3 MB and 848 KB.
- "New in 0.5.6" (EN/ID): one installer for the extras, one uninstaller, and no developer tools needed.
- The Touch ID note, `install.mac.4` and `audio.note` now point to Install Extras. The iPad Controls caption no longer names a version.
- Checked at 1440 × 900 and 375 × 812 with no overflow. The identifier scan found only the site's domain.
- Deployed as Cloudflare Pages 94e7d429. The live CSS matches the build, and both download links return 200.

## CHANGE ID: P1-098 — Audit 2026-11-28 (report only, no code change)

- New `docs/AUDIT_2026-11-28.md`: prioritised findings for v0.5.6 with file and line, evidence from the host and iPad logs, the proposed fix and its risk; an antislop UI audit (contrast computed); a verification rule for every fix; a ranked feature list.
- Top items: PERF-01 (Ultra 4:4:4 10-bit holds 25-32 fps in motion; capture to send queue p50 27-35 ms), BUG-01 (an unknown control tag ends the session, seen as a 6-session loop on version skew), SEC-01 (the iPad accepts first-time pairing over Wi-Fi), SEC-02 (any user process can raise the iPad's Touch ID sheet).
- **VERIFIED:** `swift test` 199/199 (no code changed). **NOT RUN:** A/B measurements of the proposed fixes; Android client audit.

## CHANGE ID: P1-099 — A newer peer's control message no longer ends the session (audit BUG-01)

- `SessionCodec.hasUnknownControlTag`; `SecureChannel` passes an unknown control tag on once the peer is verified (still refused before). The host and the iPad ignore it and log the tag once per session. Unknown input tags stay fatal.
- Android client (`SecureChannel.kt`, `ClientSession.kt`) and the protocol vector notes (`gen-protocol-vectors.py`, `protocol-v6.json`) follow the same rule.
- **WHY:** 28 Nov 13:17, six sessions in 27 s ended with `unknownTag(22)` when the iPad was newer than the host.
- **VERIFIED:** 2 new tests (pass after verification, refused before). `swift test` 204/204. Android `testDebugUnitTest` passed (offline, Studio JBR). **NOT RUN:** a live old/new pair (needs an old build on one side).

## CHANGE ID: P1-100 — New pairing only over USB-C; generic Bonjour name (audit SEC-01)

- Host: an unknown iPad over Wi-Fi is refused ("a new iPad must pair over USB-C first") instead of raising a pairing alert. iPad: an unknown Mac over Wi-Fi is refused with the same advice. Paired devices connect over Wi-Fi as before.
- The iPad advertises `_wireddisplay._tcp` as "WiredDisplay" instead of its device name. The TXT `id` is unchanged (the host keys per-iPad settings on it).
- Onboarding step 03 and the guide say to pair over the cable once.
- **VERIFIED:** builds; USB-C pairing and reconnect unchanged on hardware. **NOT RUN:** a second, unpaired Mac or iPad on Wi-Fi.

## CHANGE ID: P1-101 — The Touch ID bridge answers root only (audit SEC-02)

- `PamBridgeServer` accepted the user's own processes, so any app could raise the iPad's Touch ID / Face ID sheet with its own text. Now only euid 0 (the PAM module and the privileged AuthPlugin) is served.
- **VERIFIED:** a request from a user process (uid 502) was refused and logged; the iPad showed nothing. **NOT RUN:** `sudo`, the Lock Screen and an admin dialog with the iPad (the owner's check; the password always remains as fallback).

## CHANGE ID: P1-102 — PAM module and AuthPlugin hardening (audit SEC-03, SEC-04)

- `pam_wireddisplay.so`: a remote login (`PAM_RHOST`, or `SSH_CONNECTION` / `SSH_CLIENT`) keeps the password; the iPad sheet names the terminal ("… on Mac (ttys003)" or "(no terminal)").
- `WiredDisplayAuth.bundle`: admin approvals only for the console user; one atomic state decides between `SetResult` and deactivation/destroy, so no result reaches a deactivated mechanism.
- **VERIFIED:** both build with `-Wall -Wextra -Werror` clean and ad-hoc sign. The owner installed them with `install-pam.sh --prebuilt` (installed binaries hash-identical to the build) and reported `sudo`, the Lock Screen and an admin dialog all working with the iPad. The host log shows no refused request; it has no `lockscreen`/`admin` session line after 17:22, so those two rest on the owner's report.

## CHANGE ID: P1-103 — Touch ID status and setup text match Install Extras (audit BUG-02)

- New `TouchIDSetup` (WDHostCore): the Security tab reports the sudo module, the Lock Screen plugin and this user's key, names what is missing, and says when the iPad's key changed since installing.
- The stale "Copy Setup Command" (`sudo scripts/install-pam.sh`, which exists only in a source checkout) is gone; the Mac and the iPad point to Install Extras.
- **VERIFIED:** 2 new tests; on this Mac the installed key equals the iPad's key, so the panel reads "Installed".

## CHANGE ID: P1-104 — No duplicate controllers from two threads (audit BUG-03)

- `HostFleet.add` checks and appends under one lock; the watcher thread and the menu could each add an unbound Wi-Fi controller.
- **VERIFIED:** build; one controller per device after five host restarts and two preset changes.

## CHANGE ID: P1-105 — Ultra (4:4:4 10-bit) from ~36 to ~50 fps in motion (audit PERF-01)

- `kVTCompressionPropertyKey_PrioritizeEncodingSpeedOverQuality` on the 4:4:4 lane only.
- **A/B on this Mac and iPad** (90 s of scripted scrolling text and a moving gradient on the iPad display, Ultra, 80 Mbit/s, USB-C):

  | Variant | Encode p50 / p99 | Encoded fps | Replaced before encode | iPad presented | Capture to send queue p50 |
  |---|---|---|---|---|---|
  | A: 0.5.6 | 28.9 / 30.1 ms | 36.1 | 39 % | 36.1 fps | 40.1 ms |
  | B0: other fixes only | 29.3 / 30.4 ms | 35.3 | 41 % | 35.0 fps | 39.2 ms |
  | B1: flush only at burst end | 29.1 / 56.2 ms | 35.7 | 40 % | 36.0 fps | 43.4 ms (rejected) |
  | B2: speed priority | 19.3 / 20.7 ms | 52.0 | 12 % | 52.0 fps | 27.5 ms |
  | B2, repeat | 20.0 / 21.0 ms | 49.7 | 16 % | 49.7 fps | 29.7 ms |

- **Picture:** a still text frame captured on the iPad matches the Mac reference equally (PSNR 35.66 dB with and without), and B0 vs B2 on the iPad differ by PSNR 52.2 dB. In motion the 80 Mbit/s budget is shared by ~47 % more frames (avg 275 → 184 KB per frame).
- iPad enqueued-to-glass is unchanged (p50 ~30 ms): the iPad keeps up at 50 fps.

## CHANGE ID: P1-106 — Encoder warning and log sampling (audit PERF-03, LOG-01)

- `MaxFrameDelayCount` is no longer set on lanes using low-latency rate control, which reject it (-12900) and hold no frames. Pro and Balanced after the change: 57-59 fps, encode p50 13.7-14.1 ms, no warning.
- `FrameSampling` (WDSession) replaces `nanos % 300`, which sampled 1 frame in 36 on Apple silicon's clock: per-frame latency lines are now ~1 in 300 on both sides, still on the same frames. The iPad's speaker-packet line is every ~30 s instead of 2.5 s.
- **VERIFIED:** 1 new test (rate on a simulated 24 MHz clock).

## CHANGE ID: P1-107 — UI and copy (audit UI-01 to UI-06, CMT-01, BUG-04)

- Mac panel: the "On" pill uses primary text with a green dot (was 1.9:1 in light mode); the off switch has a 3:1 edge; "Follows the iPad's refresh rate" and "The pointer moves at once" replace unmeasured numbers; the default state reads "Waiting for the iPad"; above 100 % the Mac speaker level notes that loud sound can distort.
- iPad: text up to 17 pt follows Dynamic Type, capped at 125 % (identical at the default size); "High Color" named in the preset detail; Overview icon without sparkles; "Metal (experimental)" and stale comments corrected.
- **BUG-04 corrected:** measured offline, `outputVolume` 1.5 does raise the level (peak 0.25 → 0.375), so the 150 % setting works; only the caption was added.
- **VERIFIED:** live panel render in light and dark; iPad Release build. **NOT RUN:** the iPad Controls panel at large text sizes.

## CHANGE ID: P1-108 — 0.5.6 build 16: the audit fixes join release 0.5.6

**WHY (owner):** "jadikan satu dengan build 0.5.6 saja"; chosen: keep 0.5.6, build 16, replace the v0.5.6 assets.

- `CFBundleVersion` 16 in `build-host-app.sh`, `CURRENT_PROJECT_VERSION` 16 in the iPad project. Contents: P1-099 to P1-107.
- The guide (`docs/share/PANDUAN-INSTALASI.txt`) and the DMG's README and guide (`build-dmg.sh`) now say a new device pairs over USB-C first, and that Touch ID users rerun Install Extras for the new modules.
- **VERIFIED:** `swift test` 204/204; DMG and IPA report 0.5.6 (16); the DMG app and modules are ad-hoc signed (no team); the DMG carries the new PAM module and AuthPlugin; the identifier scan of the unpacked DMG and IPA found nothing. The build-15 artifacts are kept in `dist/old-0.5.6-build15/`.
