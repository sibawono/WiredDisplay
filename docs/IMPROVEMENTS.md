# Improvement audit (2026-11-25)

Done: IMP-01, IMP-02 and IMP-03 (P1-058); IMP-06, IMP-07, IMP-10, IMP-12 and IMP-13 (P1-059).
Also done (P1-060): GPU 4:4:4 conversion (replaces IMP-04), IMP-08 and IMP-09.

Revised after measuring:
- **IMP-04 as written would not lower latency.** Encoding needs the converted frame anyway, so not waiting for the GPU only frees the submit queue. The real cost was the 4:4:4 conversion through VTPixelTransfer: Ultra with More Space measured p50 8.0 ms. It now runs on the GPU: p50 3.6 ms on the stream; 1.2 vs 2.4 ms in an isolated test at the panel size, with identical codes within 1.
- **IMP-05 deferred.** It needs direct-to-display composition. The local-cursor layer drawn over the video probably prevents that, and an earlier `CAMetalDisplayLink` attempt gave nothing (D-042). It is an experiment with an uncertain result.
- **IMP-11 deferred.** Idle system sleep is off on this Mac (`sleep 0`), and "Keep the Mac awake" now covers the opposite wish. Starting the speaker tap only while "iPad Speaker" is in use risks losing the start of each sound.

Source: `main` at `33af4da` plus the uncommitted space fix (P1-057). Evidence is from the host log (`~/Library/Logs/WiredDisplayHost.log`, 24–25 Nov), the iPad log, and the source. Mac18,5 (M6) with an iPad Air 13-inch (M2), Pro preset.

Current health: no errors in two days. There were 6 warnings: 4 authentication timeouts and 1 setup close (both IMP-01 below), and 1 capture stop on display sleep, which recovered. Encode p50 13.0 ms, conversion p50 2.7 ms, and 0 frames replaced before encode.

## Ranked improvements

| ID | Area | What | Evidence | Gain | Effort / risk |
|---|---|---|---|---|---|
| IMP-01 | iPad lifecycle | When the iPad app is in the background and its audio stops (speaker switched off, or an audio interruption), it keeps its listener open while iPadOS suspends it. The Mac's connection is then accepted, but nobody answers. | 24 Nov 17:54: the audio route went off, then four "client did not authenticate within 5 s (old app version?)" in 35 s, then "connection closed during setup". `ClientApp.setAudio` and the interruption path never close the session in the background. | Clean waiting state, no retry noise, a correct status | Small, low risk |
| IMP-02 | Host status | That message says "old app version?", which is almost never the cause. The panel shows "Retrying: client did not authenticate…". | Same log lines | The user sees the real reason ("the iPad app is not answering: in the background?") | Small, no risk |
| IMP-03 | Logs | Per-frame latency lines take most of each log: on the host, "frame host" is 2,738 of 4,877 lines per hour (56 %); on the iPad, "frame glass" is 4,535 of 7,445 lines (61 %). Past 2 MB, the iPad log is **deleted whole** at the next launch, so earlier history is lost. | The iPad log only went back to today's launch, so the IMP-01 incident could not be traced on the iPad side | Logs that keep days of history; less disk I/O | Small: a summary every 5 s instead of per frame (or `--frame-log`); rotate the iPad log to `client.old.log` instead of deleting it |
| IMP-04 | Latency, host | The GPU conversion waits synchronously (`waitUntilCompleted`) before every encode: p50 2.7 ms, p95 4.6 ms. | `lanes:` lines | About 2–3 ms less per frame, by submitting the encode from the GPU completion | Medium: needs ordering care. Measure before and after |
| IMP-05 | Latency, iPad | From submitting a frame to its appearing on screen takes about 32.6 ms, two refreshes of Core Animation composition and scan-out (D-042). | `metal on glass` submit→glass p50 32.6 ms (23 Nov) | Possibly one refresh (~16 ms) less, if timing the present with `CADisplayLink`, or a direct-to-display layer, works | Medium–high, uncertain. An earlier `CAMetalDisplayLink` try gave no gain (D-042). Experiment only |
| IMP-06 | Quality, process | No CI. Every check runs only on this Mac. | — | `swift test` on every push to GitHub (a macOS runner); catches regressions in the shared modules and the protocol vectors | Small; the public repo only |
| IMP-07 | Process | Publishing is a long manual command (scrub, scan, commit-tree, push), and the auto-mode check blocks it when an agent runs it. CHANGELOG IDs collided between sessions (P1-049, P1-050). | 23 Nov | One `scripts/publish-public.sh` (scrub, scan, show the diff, then push on confirmation) and `scripts/next-change-id.sh` | Small |
| IMP-08 | Testability | Host-only logic (capture size, space mapping, power gating, the input-wake rules, keep-awake) has no unit tests, since `WiredDisplayHost` is an executable target. | `Package.swift` | Regressions caught in `swift test` | Medium: move the pure decisions into `WDSession` or a new `WDHostCore` |
| IMP-09 | iPad renderer | The system display-layer path (an option in Controls) has no decode-queue bound, unlike Metal (issue #1). | `DisplayLayerSink` | The same protection on both renderers | Small–medium |
| IMP-10 | UX | While the capture recovers (displays asleep), the panel still says "Streaming". | AUDIT_A_F R-02 | An honest status ("Paused: Mac displays asleep") | Small |
| IMP-11 | Power | While the iPad speaker is on, coreaudiod holds an idle-sleep assertion, because the speaker tap runs continuously. | PLW-06, `pmset -g assertions` | The Mac can sleep normally while silent | Medium: stop the tap IOProc after silence, restart on sound |
| IMP-12 | Privacy | The iPad app-switcher snapshot can show the Mac desktop. | AUDIT_A_F R-01 | Cover the video before iPadOS takes the snapshot (`sceneWillResignActive`) | Small |
| IMP-13 | Build | `hdiutil attach/detach` is deprecated (a warning in every DMG build). | `build-dmg.sh` output | Future-proof | Small: `diskutil image attach` |

## Tests still not run
- A 2-hour soak.
- The 20-cycle lock, sleep and screensaver series (each needs the user).
- Two iPads at once.
- 120 Hz (no ProMotion iPad).
- The issue #1 fix on an M1 and an iPad 10th gen (waiting for the reporter).

## Suggested order
1. IMP-01, IMP-02 and IMP-03: real incidents and lost evidence; small and safe.
2. IMP-06 and IMP-07: process. They prevent mistakes at every release.
3. IMP-04: a measurable latency gain. Measure it A/B.
4. IMP-10, IMP-12 and IMP-13: small polish.
5. IMP-08, IMP-09 and IMP-11: larger work.
6. IMP-05: an experiment, only if the earlier latency work leaves time.
