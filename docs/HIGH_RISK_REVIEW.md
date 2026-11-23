# High-risk review of commit b6944b0 (2026-11-23)

Scope: the changes another session made and that were committed without review in `b6944b0`, together with the power, lock and wake code from `dbb00f8` that shares the same paths. The diff base is `5a249cb`.

## Reviewed

| Area | Files | Verdict |
|---|---|---|
| Frame timestamps on the wire | `SendScheduler`, `FramedSocket`, `VideoEncoder` (output callback) | **OK.** The timestamp is `CLOCK_UPTIME_RAW` taken under `outputLock`, so it is monotonic and in send order. Covered by the existing `[7, 5, 7]` test. |
| Latency diagnostics | `VideoEncoder` "frame host", `CaptureEngine` callback timing, iPad "frame glass" | **OK, diagnostic only.** About 2 lines/s on each side. "capture->convert" shows hundreds of ms on still-lane refinement re-encodes, because these encode an older frame again: this is not a delay. The iPad log is only trimmed at launch (2 MB), so a long session grows it by about 1 MB/h. |
| Metal renderer | `MetalVideoRenderer` | **One defect (HR-01).** Also checked: the target size now comes from the drawable texture (fixes the earlier `drawableSize` race); direct texel reads apply only when the video and drawable sizes are equal; `gpuTimes` is capped at 1024. |
| iPad session and view | `ClientSession` (transit attachment), `VideoView` (`nativeScale`), `ClientApp` (`setStreamGeometry`) | **OK.** On this iPad `nativeScale` equals `scale` (2); with Display Zoom it makes the drawable match the real pixels. |
| Virtual display space | `VirtualDisplayController.setSpace`, `HostController.setDisplaySpace` | **OK.** It refuses the main display and mirror sets (D-015), matches the mode on size and refresh rate, applies it only for the session, and cancels the configuration on failure. |
| Capture size and mode changes | `HostController.captureSize` / `followDisplayMode` | **OK.** The capture restarts only when the framebuffer size changes, and a failed restart closes the session with a reason. |
| Capture recovery | `HostController.captureLost` / `recoverCapture` | **Two defects (HR-02, HR-03).** |
| Queue nesting | `videoQueue` → `queue.sync` | **OK.** `videoQueue.sync` is called only from the session thread, never from `queue`, so there is no deadlock cycle. |

## Findings

| ID | Severity | Symptom and trigger | Root cause | Fix | Evidence | Status |
|---|---|---|---|---|---|---|
| HR-01 | Medium | The iPad keeps an older frame when `nextDrawable()` returns nil (1 s timeout, or a zero size during layout) and no newer frame follows (a still desktop). This was already present before b6944b0. | `drawPending` took the pending frame before it checked the drawable, and a decode schedules a draw only when nothing is pending. | When there is no drawable, the frame stays pending and the draw retries after 50 ms, up to 10 times. A newer decode replaces the frame in the meantime. After that, the frame is dropped and the next decode schedules a draw again. | iPad Release build succeeded; installed and streaming. Not reproduced on hardware: nil drawables are rare. | **Fixed, build-verified** |
| HR-02 | Medium | A capture that stops right after each restart (for example, Screen Recording permission withdrawn while streaming) restarts without end, with no delay. | `captureLost` always restarted at attempt 0. The 4-attempt backoff only covered restarts that throw, and a stream that starts and then stops does not throw. | `QuickFailureCounter` (WDSession). A stop within 2 s of a successful recovery extends a streak: the restart waits 0.5, 1, then 2 s, and the 4th quick stop ends the session ("capture keeps stopping"). A stop after a longer run (each display sleep) starts again at 0. | 6 new unit tests, including 20 display-sleep cycles with no streak. Physical: 5 display-sleep cycles with the session up all recovered on the first attempt with no streak (wake → recovered 96–414 ms) and no session ended. | **Fixed, PASS (the loop path is covered by unit tests only)** |
| HR-03 | Low | A delayed recovery retry, or a restart still pending on wake, could restart the capture of a *later* session. | The retry closures and `captureRestartPending` were not tied to a session. | `recoverCapture` takes the session's socket and returns if it is no longer the current one. `stopVideo` clears `captureRestartPending` and the streak. | Compile check and unit tests; the regular path was unchanged in the 5 cycles above. | **Fixed** |

## Observed, not changed
- **Relaunching the iPad app** with `devicectl … --terminate-existing` right after an install left the old process holding port 9100 for about 60 s. The new app logged `listener failed … Address already in use` every 2 s, and the host saw four "client did not authenticate within 5 s" sessions before it connected. Normal use (opening the app) is not affected. If it shows up in practice, a possible follow-up is to set `SO_REUSEADDR` on the iPad listener.

## Results
- `swift test`: 152/152 passed (146 + 6 new).
- `swift build --product WiredDisplayHost`: succeeded with no warnings. iPad Release build (generic iOS): BUILD SUCCEEDED.
- The host and iPad app were installed and relaunched, and streamed 2048 × 2732 at 60 Hz.

**NOT RUN:**
- The quick-stop loop on hardware: it would mean withdrawing Screen Recording permission, which the project rules forbid.
- A nil drawable on the iPad.
- A 2-hour soak.
