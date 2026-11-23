# Audit A–F (2026-11-23)

Source: `main` at `cf63a85` plus the changes in this audit. Host build 0.4.2 on macOS 27.2.1 (Mac18,5, M6); iPad Air 13-inch (M2) on iPadOS 27.3; protocol 6.
Baseline before the changes: `swift test` 156/156; the host build succeeded.

The audit follows sections A–F of the audit brief. It was done by reading the current source of every file on the path (USB discovery → connect → auth → hello → display → capture → encode → schedule → transport → decode → present → input/audio → teardown) and checking against the logs and hardware. Power, lock and wake are in `POWER_LOCK_WAKE.md`. The review of the other session's changes is in `HIGH_RISK_REVIEW.md`.

## Findings

| ID | Area | Severity | Symptom and trigger | Location | Root cause | Fix | Evidence | Status |
|---|---|---|---|---|---|---|---|---|
| AUD-01 | A, E | Medium | A session that ends during setup can leave the speaker or microphone bridge running. Example: the iPad sends its hello and audio route, then the host rejects it (protocol mismatch, no hello, pairing). The IOProc then keeps the "iPad Speaker" device busy (CPU, and the coreaudiod sleep assertion in PLW-06) with no session. | `HostController.runSession` teardown; `.audioRoute` handler | The socket was closed **last** in teardown. Between `audio.stopAll()` and the close, a queued audio route frame still passed `handle` and started the bridge again. | The socket now closes first, so `handle` drops every later frame. The audio-start closure also returns if the session is closed. The audio queue is serial, so a start that passed the check before the close still runs before `stopAll`. | Source trace; build. Regular sessions were unchanged in hardware runs (below). Not reproduced on purpose: that needs a client with a wrong protocol. | **Fixed** |
| AUD-02 | D | Low–Medium | Input cut off mid-gesture (input switched off, Mac locks, iPad disconnects or backgrounds during a two-finger scroll, pinch or rotate). The Mac never gets "ended", so an app can stay mid-scroll (rubber band held, momentum state) or mid-pinch. | `InputInjector.releaseAll` | `releaseAll` released buttons and keys but not open gesture phases. | `GestureTracker` (WDSession) records scroll, momentum, magnify and rotate phases. `releaseAll` cancels whatever is still open, once. | 5 unit tests. Physical: NOT RUN (needs a hand on the iPad trackpad at the moment input is cut). | **Fixed (unit-tested)** |
| AUD-03 | A, C | Low–Medium | If ScreenCaptureKit's shareable-content query never answers (for example while a permission prompt is up), the video queue waits forever. Session teardown waits for that queue, so the controller can hang. | `CaptureEngine.findDisplay` | An unbounded `done.wait()`. | Bounded to 5 s, then a capture error. Capture recovery and the session's normal error path take over. | Build; 3/3 display-sleep cycles still recovered on the first attempt. | **Fixed** |
| AUD-04 | A, F | Low | Reading the iPad's name and model from lockdownd (P1-046) ran on the session thread between the hello and the display. A slow lockdownd could delay the picture by several seconds. | `HostController.runSession` | Serial read. | The read starts at connect, in parallel with the handshake. After the hello, the host waits at most 1 s, then goes on with the generic name. | Log: identity read 7 ms after auth; picture as before. | **Fixed** |

## Checked, no defect found

- **A. Lifecycle and concurrency.**
  - Queue nesting: `videoQueue → queue.sync` only; `queue` never waits on `videoQueue`. The session thread waits on both, and on main only for the pairing alert, which has a 2-minute timeout. No cycle.
  - Callbacks from old sessions: frames, verification and capture stops check `socket === origin` or `video?.socket`.
  - Session state is reset at the start and end of each session. Reconnect backoff is 1 → 8 s, with sleep pauses (PLW).
  - Timers: keepalive and the iPad watchdog are cancelled at teardown. The encoder's delayed refinements check the generation and the invalidation flag.
- **B. Transport and protocol.**
  - Bounded frame parser; session and sequence validator (gaps allowed, no replay or reordering).
  - AES-GCM with a nonce per stream and sequence, and the header as additional data. Plaintext after the handshake is refused. Low-order X25519 keys are refused. Version check is in the auth hello.
  - Scheduler order: control > input > audio > video. Video is bounded (4) and dropped only up to the next keyframe. A keyframe is requested and re-encoded from the last frame after 0.1 s, so a still screen also recovers.
  - Writes have a 5 s deadline. Each side has a 6 s no-traffic watchdog. Wired only (non-USB devices are refused).
- **C. Display and video.**
  - The config is sent before capture starts (D-042). The iPad drops video that arrives before its config and asks for a keyframe.
  - Point-size-only changes keep the decoder; a codec or pixel-size change resets it.
  - The main display is never changed: `setSpace` refuses the main display and mirror sets.
  - Colour, end to end: sRGB tags; the host's virtual-display profile matches sRGB within 0.2 %; the iPad Metal layer is tagged sRGB, so iPadOS colour-manages it onto the P3 panel (measured during the Mi Monitor colour question).
  - Presented frames are counted separately from enqueued ones (presented handler).
- **D. Input.**
  - Coordinates are normalised and clamped. Touches in the letterbox never click (`CoordinateMapper`, unit-tested).
  - Buttons and keys are released on disconnect, lock and input-off. A key-up or button-up with no matching down is ignored, so a tap made to wake the Mac is not replayed.
  - Key repeat stops when the key is released or input stops.
- **E. Audio.**
  - The speaker IO thread does not allocate and only try-locks.
  - Audio routing gives the default device back when the iPad stops, and on quit.
  - One audio owner across iPads.
- **F. UX and compatibility.**
  - Status states name the cause: waiting for USB, nothing listening (app not open), pairing code, retry reason, audio only.
  - Private APIs are guarded: virtual display availability check (fails closed); gesture CGEvent fields fall back to ⌘+/⌘−; the P3 primaries setter falls back to sRGB.
  - Settings are optional with defaults. The new `TrustedPeer.model` field decodes old entries.

## Risks and limits, documented and not changed

| ID | Severity | Note |
|---|---|---|
| R-01 | Low (privacy) | When the iPad app moves to the background, iPadOS takes its app-switcher snapshot, which can show the Mac desktop of that moment. The video is flushed when the app backgrounds, but the snapshot timing belongs to the system. It only shows on the owner's iPad. |
| R-02 | Low (UX) | While capture is recovering (display asleep), the panel still says "Streaming". It cannot be opened while the displays sleep anyway. |
| R-03 | Low (theoretical) | The control queue drops its oldest messages after 512 when the link stalls (cursor updates at 120/s). It would take more than 4 s of stall, and the 5 s write deadline closes the session first. |
| PLW-06 | Low | Unchanged: the speaker tap keeps coreaudiod's idle-sleep assertion while the iPad speaker is on. |

## Results after the fixes
- `swift test`: 161/161 passed (156 + 5 new).
- Host build: succeeded, with no new warnings (the 2 warnings left were already there).
- Physical, host reinstalled: session up in landscape at 2732 × 2048, 60 Hz; identity read 7 ms after auth; 3/3 display-sleep cycles recovered on the first attempt, 0 sessions ended.

**NOT RUN:**
- AUD-01 reproduction (needs an incompatible client).
- AUD-02 on hardware (input cut mid-gesture).
- 2-hour soak.
- Two iPads at once.
- 120 Hz (no ProMotion iPad).
