# Bug Log

## BUG-001 — Echo probe deadlocks on frames larger than the path's buffering
- **Severity:** S1 (the transport experiment would hang, then time out, and could be misread as "USB path does not work")
- **Found:** 2026-11-16, Pass B self-review, before any hardware run
- **Affected:** `wd-usbmux-probe echo`, all builds before the fix; macOS 27.2
- **Steps:** send a 256 KiB frame with `writeAll`, then `readExactly` the echo, against a peer that echoes with backpressure (reads a chunk, writes it back, then reads again — exactly what `EchoServer` does).
- **Expected:** frame echoed. **Actual:** once the return path's buffers fill, the peer stops reading, the sender's blocking write never completes, and neither side progresses until the 5 s socket timeout.
- **Root cause:** half-duplex use of a full-duplex echo: the sender did not drain the socket while writing.
- **Fix:** `UsbmuxConnection.exchange(_:expecting:timeoutMilliseconds:)` services both directions from one `poll` loop on a temporarily non-blocking descriptor; the probe uses it.
- **Regression tests:** `UsbmuxExchangeTests` — 4 MiB through a local AF_UNIX backpressure echo peer succeeds; the naive write-then-read pattern is shown to time out against the same peer; peer close and no-answer cases return `.closedByPeer` / `.timedOut` instead of hanging.
- **Verification:** `swift test` — 60 tests, 0 failures, stable across 5 serial and 3 parallel runs (see `evidence/phase0-probes.txt`). Not yet exercised over the real cable (E-05 not run).
- **Closed:** 2026-11-16 for the reproduced local case; hardware confirmation pending E-05.

## BUG-002 — Wrong error for header/payload length mismatch
- **Severity:** S4
- **Found:** 2026-11-16, Pass B self-review
- `Frame.encoded()` reported `.payloadTooLarge` when the payload was *shorter* than the header claimed. Now `.payloadLengthMismatch(header:actual:)`; asserted in `testEncodeRejectsHeaderPayloadLengthMismatch`.
- **Closed:** 2026-11-16.

## BUG-003 — Force unwrap on port construction in the iPad listener
- **Severity:** S4 (constant input, could not fail in practice; violated the no-force-unwrap rule)
- **Found:** 2026-11-16, Pass B self-review. Replaced with a guarded failure that surfaces in the UI.
- **Closed:** 2026-11-16 (build-verified only).

---
BUG-004 to BUG-010 were found by the independent Pass B reviewer (a separate agent with read-only access), after the first self-review pass had already been declared complete. None had been seen at runtime because none of the affected paths had been exercised.

## BUG-004 — Display shim leaked every private object; removing a display could never work
- **Severity:** S1 (the display could not be removed, error paths left orphan displays behind, and the shim's documented recovery contract was false)
- **Affected:** `macOSHost/Display/CVirtualDisplay/WDVirtualDisplayShim.m`, all builds before the fix
- **Root cause:** `alloc`/`init` were called through casted `objc_msgSend` function pointers. ARC treats such a call as an ordinary +0 return, so it retained the already-+1 result again and never saw `init` consuming its receiver. `invalidate()` dropped one of several references and the `CGVirtualDisplay` was never deallocated.
- **Would have shown as:** `wd-vdisplay-probe create --confirm` exits 4 ("did not return to the initial state"), with the display persisting until the process exits; a long-running host gains one permanent display per create/destroy cycle.
- **Fix:** the private selectors are declared as `@protocol`s, and calls go through normal message syntax on classes obtained from `objc_getClass`, so ARC sees the method families. Still no private symbol is linked. Also added: `@try/@catch` so an exception from private code cannot unwind into Swift; nil checks on every intermediate object; `@synchronized` on `invalidate` and `displayID`.
- **Regression tests:** `ShimTests.testSupportObjectsAreDeallocatedWhenDropped` (builds the descriptor, mode and settings under `__weak` references and asserts all three are freed; creates no display); `testInvalidConfigsAreRejectedWithoutCreatingADisplay` (10 invalid configs, online display count unchanged).
- **Not verified:** that releasing a real `CGVirtualDisplay` removes it from WindowServer. That is exactly what E-03 measures.
- **Closed:** 2026-11-16 for object ownership; display removal pending E-03.

## BUG-005 — Frame parser memory bound was not enforced
- **Severity:** S2. `append` accepted any amount of data; the bound held only if the caller drained with `next()` after every read.
- **Fix:** `append` now throws `.bufferOverflow` and poisons the parser once `maxBufferedBytes` (header + largest stream cap + 1 MiB) would be exceeded.
- **Regression tests:** `testAppendWithoutDrainingIsBoundedAndPoisons`, `testAppendExactlyAtBoundIsAccepted`.
- **Closed:** 2026-11-16.

## BUG-006 — Socket timeouts were per syscall, so a trickling peer could stall forever
- **Severity:** S2. A peer sending one byte every 4.9 s kept `readExactly`/`exchange` alive indefinitely. Also: `timeoutSeconds <= 0` disabled timeouts, and a failed `SO_NOSIGPIPE` was ignored (SIGPIPE would kill the process).
- **Fix:** all I/O goes through one `poll` loop on a non-blocking socket against a single deadline per operation; the timeout must be in 1...3600 s; `setsockopt` and `fcntl` failures are errors.
- **Regression tests:** `testTricklingPeerCannotExtendTheDeadline`, `testTruncatedReplyTimesOutWithinTheOperationDeadline`, `testNonPositiveTimeoutIsRejected`.
- **Closed:** 2026-11-16.

## BUG-007 — usbmux connection had no lifecycle; requests could be written into the iPad byte stream
- **Severity:** S2. After a successful `connect`, `listDevices()` could still write a plist into the tunnel; after a timeout mid-message the stream was desynchronised but still usable. `errno` was also read after other calls could overwrite it, and `ECONNRESET` was not mapped consistently.
- **Fix:** an explicit `.mux` → `.tunnel` → `.dead` state; any I/O or protocol error closes the socket and moves to `.dead`; entry points check the state. `errno` is captured right after each syscall, and one mapping function translates `EPIPE`/`ECONNRESET`/`ENOTCONN` to `.closedByPeer`. A usbmuxd error result for `ListDevices` is now reported as `.refused(code)`.
- **Regression tests:** 11 new `UsbmuxConnectionTests` against a scripted fake usbmuxd: the port actually sent on the wire, tag mismatch, an oversize length in the reply header, peer close mid-reply, refusal, a request issued in tunnel state, raw I/O before connect, and the Wired Only refusal sending no bytes at all.
- **Closed:** 2026-11-16.

## BUG-008 — Coordinate mapper could return NaN or distort the far edge
- **Severity:** S3. A denormal view size made the content rect 0x0, and a touch at (0,0) then mapped to `(NaN, NaN)`. Clamping to `maxX - 1` collapsed everything in the last point to one value.
- **Fix:** `init?` rejects geometry whose arithmetic degenerates; both directions return nil for non-finite results; the clamp is `maxX.nextDown`.
- **Regression tests:** extra cases in `testDegenerateGeometryFailsInit`; the corner and negative-origin tests now assert containment and that points near the edge are not distorted.
- **Closed:** 2026-11-16.

## BUG-009 — Test peer could accept on a recycled file descriptor
- **Severity:** S3 (latent order-dependent test failure). The helper closed its listening socket while its thread could still be blocked in `accept` on that number, so a later test's socket could be accepted by the stale thread.
- **Fix:** `UnixPeer` polls with a short timeout and a stop flag, and `deinit` waits for its thread to finish before closing descriptors.
- **Verification:** 27/27 socket tests stable across 5 serial runs; the full 60-test suite passed 3 times in parallel with 8 workers.
- **Closed:** 2026-11-16.

## BUG-010 — iPad listener: stale callbacks, IPv4 only, overstated "Wired Only"
- **Severity:** S3. After stop then start (background, then foreground), a late `.cancelled` or `.failed` from the old listener could overwrite or cancel the new one. The bind was IPv4 only, although which address family the device-side tunnel dials is undocumented. The comment claimed "Wired Only", but other apps on the iPad can also connect to loopback.
- **Fix:** callbacks carry the listener's identity and are ignored when stale; the listener is restricted to the loopback interface type for both address families; the comment states the real guarantee and points to D-006.
- **Verification:** compiles for the iOS device SDK only. **Not run on the iPad.**
- **Open (by design until authentication):** a local app can hold the single connection slot. Fine for an echo probe; must be solved by authentication before input or video use this path.

## BUG-011 — iPad listener bound "to the loopback interface" never received usbmuxd connections
- **Severity:** S1 (transport unusable)
- **Found:** 2026-11-16, on hardware during E-05. This is a regression from the BUG-010 review fix.
- **Affected:** TransportProbe built after BUG-010; iPad Air 13-inch (M2), iPadOS as installed on 2026-11-16
- **Steps:** launch the probe in the foreground (UI: "listening on loopback:9000"), then run `wd-usbmux-probe echo` on the Mac.
- **Expected:** connection accepted. **Actual:** the Mac gets usbmuxd result 3 (refused); the iPad shows 0 accepted, 0 rejected (`evidence/e05-bug011-zero-connections.png`).
- **Root cause (confirmed by the fix, not by inspecting Network.framework):** with `requiredInterfaceType = .loopback` and no local address, the listener did not accept on IPv4 `127.0.0.1`, where usbmuxd's device-side relay connects. The BUG-010 rationale ("which address family the tunnel dials is undocumented") was answered on hardware: IPv4 loopback.
- **Fix:** `requiredLocalEndpoint = 127.0.0.1:9000` again; the UI shows the exact bound address. Kept from BUG-010: stale-callback guards and the corrected comment.
- **Verification:** E-05, 5 runs, 548 MiB echoed byte-exact; the iPad shows peer `127.0.0.1`, interface `lo0` (`evidence/e05-ipad-midrun.png`).
- **Lesson:** a review fix touching platform behaviour was accepted on a compile check alone. Fixes to transport binding are now marked "unverified until hardware" in the change report.
- **Closed:** 2026-11-16.

## BUG-012 — Probe event log overwritten by the next app launch (E-05b evidence lost)
- **Severity:** S2 (lost hardware evidence)
- **Found:** 2026-11-16 19:11 while pulling the iPad log after E-05b run 1. The file held a later launch (18:10), not the 15:18–15:21 test.
- **Root cause:** one fixed file name, rewritten whole from the in-memory buffer of the current process.
- **Fix:** one file per launch (`probe-events-<yyyyMMdd-HHmmss>.log`), append-only through a FileHandle; the ring buffer only feeds the screen. Timestamps are taken under the same lock that orders lines.
- **Verification:** builds for the device and installs. Not yet exercised in a full run.
- **Consequence:** E-05b run 1 part A ("echo works with Wi-Fi off") has no iPad-side proof; repeat in `TEST_SESSION.md` §6.

## BUG-013 — E-05b monitor could declare the test finished mid-test; no Sidecar recovery on kill; overwrote logs
- **Severity:** S1 (could end evidence collection early; could leave the user without a screen)
- **Found:** 2026-11-16, independent Pass B review of the E-05b tooling. The run 1 log shows 3 of the 5 "refused" needed for a false END at 15:19:34–37.
- **Fix:** END only on an explicit marker the iPad writes when "Selesai" is tapped (fetched over the cable); Sidecar restore with 90 s of retries in an EXIT trap (normal end, timeout, Ctrl-C, kill); refuses to overwrite an existing log; keeps 8-character serial prefixes so Network entries can be attributed.
- **Verification:** syntax check; run 2 was started and stopped by the user; the trap restored the Sidecar check (`sidecar connected` logged on interrupt).

## BUG-014 — Wrong claim: "nothing on Wi-Fi can reach the iPad listener"
- **Severity:** S2 (documentation/security reasoning)
- **Found:** Pass B review. usbmuxd also reaches the device loopback over Wi-Fi when the iPad is listed as a Network-type device, so `via=[lo0]` looks identical for both paths.
- **Fix:** comments and docs corrected. Wired Only rests on the Mac refusing Network-type devices (D-003). Added a clearly named negative-control entry point (`connectIgnoringWiredOnlyPolicyForNegativeControl`) and probe flag to demonstrate it in E-05b part C; unit test shows `connect` still refuses.

## BUG-015 — `CodecSet.contains(VideoCodec)` recursed forever
- **Severity:** S1 (stack overflow during codec negotiation)
- **Found:** 2026-11-16, compiler warning on first build of the session module, before any caller existed.
- **Root cause:** inside the overload, `.h264` resolved to `VideoCodec.h264` and called the overload itself.
- **Fix:** explicit `CodecSet.h264` / `CodecSet.hevc`. **Regression test:** `testCodecSetContainsCodec`.

---
BUG-016 to BUG-022 come from the independent Pass B review of the end-to-end pipeline (2026-11-16, before any hardware run). All are fixed; none has been reproduced on hardware because the pipeline has not run there yet.

## BUG-016 — Host crashed on any failure before streaming started (S1)
Keepalive `DispatchSource` was created inactive and released by the teardown `defer` on every early throw (no hello, missing Screen Recording, encoder/display failure). libdispatch traps on releasing an inactive source, killing the host while the virtual display might be the only display. **Fix:** the source is resumed right after creation (scheduled at `.distantFuture`), configured later.

## BUG-017 — Input could stay enabled after the user turned it off (S2)
Race between reading the toggle and installing the injector. **Fix:** the injector reads the controller's lock on every event; turning input off also releases held buttons.

## BUG-018 — Two-finger scroll went to the window under the Mac's real cursor (S2)
Possibly on the main (Sidecar) display. **Fix:** the client moves the pointer to the finger centroid when a scroll starts, and the host moves the cursor onto the virtual display before posting a scroll if it is elsewhere. Regression test `testScrollStartMovesPointerToCentroidOnce`.

## BUG-019 — Video could freeze permanently after a decoder hiccup (S2)
`requiresFlushToResumeDecoding` was only answered with keyframe requests; the flag clears only after a flush. **Fix:** flush, then resume at the next keyframe.

## BUG-020 — Stale picture after dropped frames on a still screen (S2)
ScreenCaptureKit sends nothing while the screen is unchanged, so a requested keyframe never came. **Fix:** the encoder keeps the last frame and re-encodes it as a keyframe if no new frame arrives within 100 ms.

## BUG-021 — Input edge cases (S3)
Rate limiter could drop a button release (now only moves/scrolls are limited); slow scrolls rounded to zero (now accumulated); scroll jumped when a finger lifted (re-based; test `testLiftingOneFingerRebasesScroll`); partial touch cancel miscounted fingers (cancel resets all); input on a vanished display fell to (0,0) of the main display (now dropped with buttons released).

## BUG-022 — Connection lifecycle edge cases (S3/S4)
No backoff after sessions that ended without error (display created/destroyed every second); old connection's send completions could kill the new one; frames could hit the wire out of sequence order with concurrent senders (now numbered and queued under one lock; test `testConcurrentSendersNeverReorderOnTheWire`); frames from a replaced socket were still handled; `stop()` ignored during the handshake; oversize video frame dropped without a keyframe request; HEVC had no H.264 fallback; stream point size read before the HiDPI mode applied.

**Known, not fixed (documented):** a host crash or `kill -9` cannot release a held synthetic button (R-16); BT.709 transfer tag vs sRGB capture is a small colour difference (R-VID-04 pending measurement).

---
BUG-023 to BUG-031 were found during the first hardware session (2026-11-16/17). All were reproduced on hardware, fixed, and re-verified on hardware unless stated.

## BUG-023 — Host hung creating the video encoder (S1)
`VTCompressionSessionCreate` walks the folders around the app bundle; inside `~/Documents` that blocked on a TCC "access Documents" prompt hidden behind the iPad app. **Fix:** the host is built outside the project and installed to `~/Applications` (`scripts/build-host-app.sh`). Also: iCloud Drive's `com.apple.fileprovider` attributes made `codesign` refuse the bundle, so staging moved to a temp folder. **Verified:** encoder ready in < 1 s on every session since.

## BUG-024 — A TCC prompt froze the whole session (S1)
Starting the speaker bridge on the session queue blocked it on the Microphone prompt; video and input stalled. **Fix:** audio starts on its own queue; the host asks for Microphone permission at launch.

## BUG-025 — Touch: second finger never reached the view; long press became a drag; zero-length clicks (S2)
From host input traces. **Fix:** system two-finger pan recognizer, 12 pt slop, 25 ms minimum click. **Open:** taps land ~5 % below the touched point (E-07 offset, parked by the user).

## BUG-026 — iPad crashed restarting audio on a 0 Hz microphone format (S1)
**Fix:** validate the input format, retry with back-off.

## BUG-027 — Host crashed on the first audio packet (S0-adjacent: host death; S1)
`SendScheduler.enqueue(urgent:)` had a `precondition` limiting it to control/input. **Fix:** dedicated bounded audio queue, order control > input > audio > video. **Regression tests:** `SendSchedulerAudioTests`, `FramedSocketAudioTests`.

## BUG-028 — Second reader of a loopback device got silence (S2)
Driver zeroed the ring after the first read. **Fix:** readers validate against the writer's high-water mark. **Verified:** two simultaneous readers both receive the tone (`wd-audio-probe`).

## BUG-029 — Engine stopped by a config change within 1.5 s was never restarted (S1)
Speaker and microphone both went dead when the mic was enabled.

## BUG-030 — Rebuilding the engine re-engaged voice processing, stopping it again every ~120 ms (S1)
Seen directly in `client.log`. **Fix:** resume the same engine after the voice-processing configuration change; rebuild only if that fails.

## BUG-031 — iPad crashed on the first microphone buffer (S1)
The tap closure was main-actor isolated (defined inside a `@MainActor` class); Swift 6 trapped when AVAudioEngine called it on its own thread. **Fix:** tap built in a `nonisolated static` function. **Verified:** 800+ microphone packets with speech levels received on the Mac (`evidence/audio-host.log`).

## BUG-032 — Wrong link-speed conclusion: usbmuxd "480 Mbit/s" and a CPU-bound echo probe (S2, documentation)
- **Wrong claims made:** "the link is USB 2 (480 Mbit/s)", "≥119 Mbit/s one way", "80–150 Mbit/s is unsafe", "the cable is probably a charging cable". All false.
- **Root causes:** (1) usbmuxd's `ConnectionSpeed` property reads 480 Mbit/s even on a 10 Gb/s link — it is not the negotiated speed; IORegistry `Device Speed = 4` (SuperSpeedPlus) and System Information "Link Speed: 10 Gb/s" are. (2) `wd-usbmux-probe echo` generated random data byte by byte per frame and divided by total time, so ~85 % of the measured time was the probe's own CPU work.
- **Fix:** payload generated once and rotated; throughput computed from on-wire time only and reported per direction.
- **Corrected measurement (2026-11-17, both cables are 10 Gb/s):** up to 1,386 Mbit/s per direction simultaneously (4 MiB frames), 409 Mbit/s at 64 KiB frames, with video streaming (`evidence/cable-new-corrected.txt`).
- **Lesson:** cross-check a single metadata field against an independent source before drawing a hardware conclusion.

## BUG-033 — Colours looked faded with Display P3 enabled (S2)
- **Report (user):** Dock icon colours on the iPad looked paler than on the Mac after step 4 enabled Display P3.
- **Measured:** iPad screenshot vs Mac capture of the same (mirrored) screen, both converted to sRGB; mean chroma of saturated pixels (`evidence/color-chroma-ab.swift`). P3 capture + P3 tags: iPad 71 % of the Mac's chroma. sRGB capture + BT.709 tags: 88.5 % (the remainder is 4:2:0 chroma subsampling and resampling).
- **Root cause:** the iPad presents the P3-tagged stream as if it were sRGB (P3 code values without the gamut mapping), so every colour is desaturated. The tags do reach the decoder (unit test `testDisplayP3TagsSurviveTheWire`), so the loss is at presentation.
- **Fix:** sRGB / BT.709 end to end is the default again; the virtual display is no longer created wide-gamut. `--color p3` keeps the P3 path as an experiment.
- **Verified (Pass B):** default launch without flags, ratio 0.886; log shows "sRGB tags" and "Display P3 off (sRGB)".

## BUG-034 — Colours slightly washed out and blurry/artefacted around coloured UI (S2)
- **Report (user):** after BUG-033, some effects looked colour-blurry or artefacted when clicking buttons in System Settings.
- **Method:** static colourful test page (60 coloured buttons, coloured text, gradient), switched while streaming; Mac capture vs iPad screenshot at equal resolution, sRGB; PSNR split into luma/chroma and flat/edge (`evidence/quality-tools/`).
- **Finding 1 — transfer tag:** the encoder tagged the sRGB transfer function; the iPad then rendered every tone ~10 levels brighter (mid-grey 148 → 158; gradient 29 dB). With the BT.709 transfer tag it matches within 1 level (gradient 48.6 dB). **Fix:** BT.709 tag (default).
- **Finding 2 — 4:2:0 chroma:** flat colour areas were accurate (44 dB) but edges of coloured buttons and coloured text were poor (23.5 dB; chroma 31 dB while luma 43–48 dB): colour bleed from 4:2:0 subsampling. A frame-QP cap did not change it. **Fix (opt-in):** `--chroma 444` — BGRA capture, GPU matrix-only conversion to 8-bit 4:4:4 (no gamma change), hardware HEVC RExt 4:4:4 (`chroma_format_idc 3`, verified by SPS parse). The iPad Air M2 decodes it. Edges 23.5 → 39.5 dB, flat 44 → 46 dB, colour within ±1 level.
- **Cost of 4:4:4:** needs standard rate control (low-latency RC only produces 4:2:0, measured); output cadence slightly less even (encoded max gap 47–77 ms vs ~40 ms); host CPU unchanged (~4–7 %). `MaxFrameDelayCount` is not supported by this encoder (-12900).
- **Also added:** idle refinement — the last frame is re-encoded at +0.1/+0.35/+0.95 s when the screen stops changing, so a still frame never stays at mid-motion quality.
- **Pending:** user visual judgement of `--chroma 444` before it becomes the default.
- **User test (2026-11-17):** with `--chroma 444` the cursor felt laggy; log showed encoded frame gaps p95 212 ms, max 278 ms. 4:4:4 stays opt-in only; 4:2:0 low-latency remains the default. Next idea: 4:4:4 only for still frames (refinement), 4:2:0 low-latency during motion.
- **Hybrid mode (`--chroma hybrid`, 2026-11-17):** two hardware sessions — 4:2:0 low-latency for motion, 4:4:4 (standard RC) for a quiet screen. Motion = >10 % of the frame dirty (ScreenCaptureKit dirty rects) or the cursor moved within 300 ms; after 0.1 s without motion the 4:4:4 lane takes over with a keyframe, and the next motion frame returns to 4:2:0 with a keyframe. A lane epoch, checked and sent under one lock, stops late frames of the old lane from following the new keyframe. BGRA capture, GPU matrix-only conversion for both lanes. **Measured:** still page edges 39.5 dB (= full 4:4:4), colours ±1; moving test pattern stays on 4:2:0 at 59.8 fps, encode p95 18.8 ms, 0 gaps; small updates on the 4:4:4 lane p50 ~16 ms, p95 ~24 ms (spikes to ~90 ms only at lane-switch keyframes). The client needed no change (it rebuilds the format when parameter sets change). **Pending:** user check of cursor feel and click effects; cursor-triggered switching not verified automatically (synthetic events did not move the cursor).

## BUG-035 — Gradients banded on the iPad; Sidecar smooth (S2)
- **Report (user, photos IMG_5220/5221):** the blue radial gradient of a Google Meet tile showed concentric rings through WiredDisplay, smooth through Sidecar.
- **Measured** (radial gradient page, blue channel along a 620 px line, `evidence/quality-tools/band.swift`): the Mac's framebuffer is 8-bit with fine dithering (949 level changes, longest flat run 4 px, no full-level jumps). 8-bit HEVC flattened the dither into bands on the iPad: 225–231 changes, flat runs up to 25 px, 143–184 full-level jumps.
- **Not the cause:** capture precision — a 10-bit (`l10r`) ScreenCaptureKit capture holds the same 8-bit values (`cap10.swift`), so the framebuffer itself is 8-bit + dither.
- **Fix:** encode in 10 bits (HEVC Main10 on the low-latency 4:2:0 lane, RExt 4:4:4 10-bit on the still lane; BGRA capture, GPU matrix-only conversion to `x420`/`x444`). The encoder's smoothing keeps fractional levels instead of rounding to 8-bit steps. `--depth 8|10`, default 10. The iPad Air M2 decodes both.
- **Verified (two runs on a stable mirror arrangement):** iPad 838–859 level changes, flat runs ≤ 8 px, 4–6 full-level jumps (vs 184 at 8-bit); colours ±1; flat areas 49.6 dB (8-bit: 46.6). Motion-lane encode p50 17–18 ms (8-bit ~16 ms).
- **Measurement note:** a host relaunch recreates the virtual display and macOS needs a few seconds to re-apply the mirror; screenshots taken in that window compare different displays.
- **Follow-up (user: "still banding" in Meet):** the Meet background animates (85–97 % of the screen dirty every frame), so it always uses the 4:2:0/10 low-latency lane, which spends only 2–4 KB per frame on it. Offline lab (`bandlab.swift`: dithered moving radial gradient, same encoder settings, VT decode in float): staircase RMS 8-bit 0.57 → 10-bit 0.24; `MaxAllowedFrameQP` ≤ 22 → 0.16 (floor; lower QP only spends bits on noise); more bitrate alone changes nothing. A QP cap is **not usable live**: at QP 24 the low-latency encoder emitted only 37 of 300 frames in 5 s. iPad screenshots of the moving gradient look as smooth as the Mac capture by these metrics, so the remaining visible banding is not yet reproduced objectively. Candidates: iPad presentation rounding the smooth 10-bit decode to 8-bit without dithering (fix: decode to 10-bit buffers and present via Metal with a dither shader), or Sidecar using a higher-quality motion encode.
- **Root cause found (2026-11-17):** iPad screenshots of both Sidecar and WiredDisplay were smooth even at 4× contrast (16-bit screenshots, `band16.swift`/`stretch16.swift`), yet the user saw rings in a static gradient on the 4:4:4/10 lane. A full-screen opaque `AVSampleBufferDisplayLayer` is promoted to a hardware overlay plane; that path reached the panel without dithering, and screenshots do not show it. **Fix:** video layer opacity 0.999, so the GPU compositor (dithered) renders it; iPad control panel toggle "Smooth gradients (GPU dithering)", on by default. **Verified by user:** rings gone with the toggle on. Cost: 0.1 % darker (≈0.25 of an 8-bit level).
- **Final state:** 10-bit HEVC (Main10 / RExt 4:4:4 10) + GPU-composited presentation. Both are needed: 8-bit streams arrive banded (staircase 0.47 vs 0.17 at 10-bit), and the overlay plane removes dithering.

## BUG-036 — Typing felt delayed: keystrokes were encoded on the slow 4:4:4 lane (S3)
**Symptom:** the user noticed a delay of a few milliseconds while typing.

**Root cause, measured in the host's lane stats while the user typed:**
- A keystroke redraws only about 0.5 % of the screen and does not move the cursor, so the hybrid policy (D-022) treated it as a still screen and encoded it on the 4:4:4 lane.
- That lane uses standard rate control. It took p50 23–41 ms, p95 52–83 ms and max 116 ms per frame, against 16.7 ms p50 and 24 ms p95 on the 4:2:0 lane.
- The lane also flipped 12–26 times per 5 s, and every flip forced a keyframe.

**Fix:**
- Recent keyboard activity counts as motion for 0.5 s. This covers the Mac's own keyboard (`CGEventSource.secondsSinceLastEventType`, `keyDown`) and every input event from the iPad (`VideoEncoder.noteInput`).
- Idle refinement waits until that window and the cursor window have passed before it switches to 4:4:4. Typing bursts now stay on the low-latency lane, and the text sharpens about 0.5 s after typing stops.

**Follow-up (first verification run):**
- The keyDown recency read from the event system works: `secondsSinceLastEventType` reported 26.6 s on this Mac's Bluetooth keyboard.
- But an animation at about 10 fps covering 17 % of the screen flipped lanes 23–46 times per 5 s and dropped the stream to about 10 fps. Its 100 ms gaps matched the 0.1 s first refinement step.
- Fix: the first refinement step is now 0.5 s (0.5 / 0.75 / 1.2 s), and the lane stats log why each frame counted as motion (`dirty`, `cursor`, `typing`, `ipad-input`, `still`).
- First run after the fix: 9 switches per 5 s with cursor movement, 0 while scrolling.

**Verification (09:18, user typing):**
- 0–4 lane switches per 5 s, down from 23–46.
- Nearly all frames went through 4:2:0 at encode p50 17 ms and p95 18 ms, down from a p95 of up to 83 ms.
- Each keystroke in the user's app redrew 17–19 % of the screen, so those frames counted as motion by dirty area alone.
- The estimated keystroke-to-iPad path is now about 40–55 ms: capture ≤16 ms, encode about 17 ms, USB about 1 ms, then decode and display.

## BUG-037 — After a Mac reboot the iPad does not reconnect until the cable is re-plugged (S2, platform; mitigated)
**Symptom (user, 09:28–09:30):** the user shut the Mac down and turned it back on, with automatic login. The iPad app stayed open and the cable stayed in. The host started at login (09:29:28) but connected only at 09:30:13, after the cable was unplugged for 10–20 s and plugged back in.

**Evidence:**
- The host logged nothing between start and connect. Its wait loop retried silently, whether the cause was usbmuxd being unreachable, no USB device being listed, or port 9100 refusing the connection.
- usbmuxd gave the iPad a new device ID after the reboot (230 → 4).
- The iPad log shows the app active again at 09:29:55, 18 s before the connection, and nothing about the old session ending.
- The macOS unified log kept nothing for that window.

**Working hypothesis:** usbmuxd did not see the iPad as an attached USB device until a new USB attach (the re-plug). Not proven.

**Diagnostics added:**
- Host: the wait loop logs each change of state, with how long the previous state lasted: usbmuxd unreachable, no device listed, only non-USB devices, iPad on USB but port 9100 refused, or the iPad found.
- iPad (`client.log`): the app becoming active or leaving the foreground (with audio state), listener state, incoming connections (and refusals because a session is still open), and every connection end with its reason.

**Second reboot (09:36, with the new diagnostics):**
- The host started at 09:36:33. Until 09:37:07, usbmuxd listed the iPad only as network devices ("1 network", then "2 network, 1 network"), never on USB.
- The user re-plugged the cable at about 09:37. The iPad appeared on USB (device 3) and the session was up 20 ms later.
- Both apps were ready throughout; the iPad's last log line was the old session ending at 09:36:07.
- So without a new USB attach, the iPad does not come back as a usbmux USB device after a Mac reboot. It is not merely slow.

**Third diagnostic:**
- While waiting, the host also logs whether an Apple iPad or iPhone is on the USB bus (IORegistry `IOUSBHostDevice`, read-only), with its USB configuration and speed.
- In normal operation the iPad shows as `iPad@00200000 product 4779 config 5 speed 4`; configuration 5 is the usbmux data configuration.

**Third reboot (09:40), decisive:**
- From host start at 09:40:27 until the re-plug at 09:41:32 (64 s), the host logged `usbmuxd lists only non-USB devices: 2 network, 1 network; USB bus: no iPad`.
- The iPad was not on the Mac's USB bus at all. No `IOUSBHostDevice` existed for it until the USB-C link was re-established by the re-plug.
- So this is a USB-C link problem between the Mac mini port and an iPad that stayed attached through the power cycle. It is below usbmuxd and outside what an unprivileged app can fix: a port reset needs root or private API.

**Mitigation:**
- After 20 s in "Waiting for your Mac", the iPad's waiting screen shows a hint: "Mac restarted? Unplug the cable and plug it back in."
- The diagnostics stay: the host logs the wait state and the USB bus state on every change.

**Not done:**
- Falling back to the network-listed iPad. The Wi-Fi path is forbidden unless the user opts in explicitly.

**Worth trying (user):**
- another Mac mini port or another cable;
- the iPad's wired-accessories setting.

The previous plan, for reference:
- iPad absent from the bus means a USB-C link or role problem outside the app's reach.
- iPad present in another configuration means a software re-enumeration may be possible.
