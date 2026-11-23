# Power, lock and wake: audit, fixes and evidence (2026-11-23)

Production source: `~/Documents/airplay app ` (git `main`, base `b6944b0`). `~/Documents/Mac host & Ipad app` is an older snapshot with no git and no iPad client, so it is not production.

Environment: WiredDisplay 0.4.2 (build 8), protocol 6. The Mac is a Mac18,5 (Apple M6) on macOS 27.2.1 (26B131); the iPad is an iPad Air 13″ (M2) running the Release client. An iPhone was also cabled; it gets its own idle controller.

## Baseline (before changes)

| Check | Result |
|---|---|
| `swift test` | 146 test cases passed, 0 failures |
| Host build (`swift build --product WiredDisplayHost`) | Succeeded |
| iPad Release build (generic iOS, unsigned) | BUILD SUCCEEDED |
| Mac settings | Screen lock 300 s after screensaver or display sleep (`sysadminctl -screenLock status`); `sleep 0` (no idle system sleep); `displaysleep 90`, held off by WiredDisplay's own assertion |

The host had **no** handling of sleep, wake, display sleep, lock, screensaver or user switching. Its only power code was a `PreventUserIdleDisplaySleep` assertion during a session. That assertion was a user request; it blocks idle display sleep only, never a sleep the user asks for.

## State model

The state is five independent dimensions, all in `PowerState` (`macOSHost/Host/PowerMonitor.swift`):

| Dimension | Set by | Cleared by | Reconciled every 2 s from |
|---|---|---|---|
| `systemAsleep` | `NSWorkspace.willSleep` | `NSWorkspace.didWake` | not reconciled; the process is frozen while asleep |
| `displaysAsleep` | `screensDidSleep` | `screensDidWake` | not reconciled |
| `locked` | `com.apple.screenIsLocked` | `com.apple.screenIsUnlocked` | `CGSessionCopyCurrentDictionary()["CGSSessionScreenIsLocked"]` |
| `screensaver` | `com.apple.screensaver.didstart` | `com.apple.screensaver.didstop` | whether `com.apple.ScreenSaver.Engine` is running |
| `sessionActive` | `sessionDidBecomeActive` | `sessionDidResignActive` | `kCGSessionOnConsoleKey` |

What macOS 27 actually reports, measured here:
- The **screensaver** posts `screenIsLocked` as soon as it starts, even before the 300 s password delay. Closing it inside the delay posts `screenIsUnlocked` without a password.
- **Display sleep** (`pmset displaysleepnow`) also posts `screenIsLocked`.
- ScreenCaptureKit stops with *"Failed to find any displays or windows to capture"* about 20 ms **before** `screensDidSleep` arrives.
- A screensaver that exits without notifications (it was killed) left the state stale, and the session really stayed locked (`CGSSessionScreenIsLocked = 1`). That is why the 2 s reconciliation exists.

### Invariants
1. **Input from the iPad.** It is injected fully only when the Mac is awake, unlocked and on the active session.
   - While locked or in a screensaver, only pointer moves pass. A move wakes the display or dismisses the screensaver.
   - Clicks, scrolls, gestures and keys are dropped. Nothing is typed into the password field, and no tap made to wake the Mac is replayed as a click.
   - Held buttons and keys are released on every transition to "not allowed".
   - While the Mac is asleep or another user is in front, everything is dropped.
2. **Before system sleep**, the session closes cleanly. No reconnect is attempted until `didWake`. Waits are bounded (60 s) and cancellable by stop.
3. **A capture loss** (display sleep) never ends the session or destroys the virtual display.
   - The iPad gets one black keyframe, so it does not keep the last desktop frame.
   - If the displays are asleep, the capture restarts on `screensDidWake` or `didWake`.
   - Otherwise it retries 4 times with 0.5 / 1 / 2 / 4 s backoff. Only then does the session close, as before.
4. **After unlock, screensaver end or display wake**, the stream is reconciled: display mode re-read and a fresh keyframe requested. Nothing is assumed ready.
5. **After the backoff resets on wake**, a session from before sleep is never reused. A new connection, handshake and generation start.

## Findings ledger

| ID | Severity | Symptom and trigger | Location | Root cause | Fix | Regression evidence | Status |
|---|---|---|---|---|---|---|---|
| PLW-01 | High | Every display sleep ended the iPad session and destroyed the virtual display, so windows were rearranged and the stream reconnected. 2 of 20 cycles also failed to recreate the display (`initWithDescriptor: returned nil`). | `HostController.startEncoding` `onStop` | A ScreenCaptureKit stop was treated as fatal | `captureLost` / `recoverCapture`, a black frame and a wait for wake | 20 display-sleep cycles: before 21 sessions ended, 2 creation failures; after 0 ended, 0 displays released, 20/20 recovered on the first attempt | **Fixed, PASS** |
| PLW-02 | High | No sleep handling: connect attempts could run during sleep transitions, and nothing ensured a clean reconnect after wake. | `HostController.runLoop` | No power awareness | `willSleep` closes the session; the run loop pauses until `didWake` and then resets the backoff | 1 system-sleep cycle: paused, no attempts while asleep, picture back 2.4 s after wake | **Fixed, PASS (1 cycle)** |
| PLW-03 | Medium | iPad input reached a locked Mac: taps, clicks and keys could hit the lock screen's password field, and a tap made to wake could act as a click. | `InputInjector.handle` | No lock or sleep gating | Power gate: only moves pass while locked or in a screensaver; buttons and keys are released | Physical: a one-finger move on the iPad dismissed the screensaver; the log shows "INPUT limited" | **Fixed, PASS (manual)** |
| PLW-04 | Low | A killed screensaver left the screensaver state stale. | `PowerMonitor` | Notification-only state | Reconcile every 2 s with the session dictionary and the running ScreenSaverEngine | The log shows the `reconcile` correction after the kill | **Fixed** |
| PLW-05 | Info | The lock screen is captured by ScreenCaptureKit and shown on the iPad. No desktop is visible while locked. | — | Platform behaviour | — | Locked at 09:38:03: capture went on at about 35 fps; the user saw the lock screen on the iPad | **Verified, no leak** |
| PLW-07 | Medium | After system sleep the iPad came back at native "looks like" instead of the user's most space; the UI looked zoomed (user report). | `HostController.startVideo` | The virtual display is recreated after sleep, rotation or a replug, always with the default space; the user's choice was never stored | The last space per iPad is remembered (`displaySpaces`) when the mode changes and used when the display is created; `--space` still wins | Set most space → restarted the host → the display came back "default mode most 1280x1708" | **Fixed, PASS** |
| PLW-06 | Low / risk | While the iPad speaker is on, coreaudiod holds `PreventUserIdleSystemSleep` for `iPad Speaker` and its tap, because the tap's IOProc runs continuously. | Audio driver and HostAudioBridge | Running IO on a HAL device | Not changed. Idle system sleep is disabled on this Mac (`sleep 0`). Stopping the tap when nothing plays is a possible follow-up. | `pmset -g assertions` | **Open (documented)** |

## Physical results (host build with these fixes)

| Scenario | Runs | Result | Recovery |
|---|---|---|---|
| Display sleep → wake (`pmset displaysleepnow` / `caffeinate -u`) | 20 | **PASS**: 0 sessions ended, 20/20 captures recovered on the first attempt | wake → capture running: p50 86 ms, p95 312 ms, max 312 ms |
| Screensaver → dismissed by an iPad pointer move | 1 | **PASS** | immediate |
| Screensaver → dismissed by the Mac's own input | 1 (earlier run) | **PASS** | immediate |
| Lock → unlock (lock via `SACLockScreenImmediate`, unlock by the user) | 1 | **PASS**: lock screen shown on the iPad, no desktop; the session survived the unlock | no interruption |
| System sleep → wake with the Mac keyboard → unlocked | 1 | **PASS**: clean close, paused, no reconnect storm | picture back 2.4 s after `didWake` (USB reconnect 34 ms) |
| Screensaver 20-cycle automation | 20 | **NOT RUN**: neither `caffeinate -u` nor a synthetic event from an unprivileged process dismisses the screensaver; each cycle needs real input | — |
| Lock/unlock ×20, sleep/wake ×20 | 20 each | **NOT RUN**: each cycle needs the user's password and physical wake | — |
| Screensaver → lock (after 300 s) → unlock | 0 | **NOT RUN** | — |
| Sleep during connect or negotiation; unplug during sleep; fast user switching; login window; FileVault | 0 | **NOT RUN** | — |
| Waking the Mac from system sleep with the iPad keyboard or trackpad | 0 | **NOT SUPPORTED (by design)**: the host process and usbmux transport are frozen while the Mac sleeps, so iPad input cannot reach it. Display sleep and screensaver can be woken by an iPad pointer move. | — |
| 2-hour soak | 0 | **NOT RUN** in this pass. The last soak was 30 min on 2026-11-18 (`CHANGELOG` P1-029). | — |

Build and tests after the changes: `swift test` 146/146 passed; the host was built, installed and relaunched.

## Observed outside WiredDisplay
- After the system-sleep test, the main monitor (Mi Monitor, 2K, run as a 5K HiDPI mode created by BetterDisplay) showed the desktop magnified and cropped, although macOS still reported 2560 × 1440 on a 5120 × 2880 framebuffer and accessibility Zoom was off. WiredDisplay never touches that display; only its own virtual display is managed. The user restored it in BetterDisplay. This is treated as a BetterDisplay or monitor behaviour after wake, not a WiredDisplay defect.

## Reproduction procedures for the scenarios not run
- **Lock ×20:** run `scratchpad lock` (SACLockScreenImmediate), or use Apple menu › Lock Screen. Look at the iPad, unlock, and repeat. Count `screenIsLocked` / `screenIsUnlocked` pairs and `session cleaned up` in the host log (it must be 0).
- **Sleep ×20:** run `pmset sleepnow`, wake with the Mac keyboard, and unlock. In the log, each cycle must show `Mac is going to sleep` → `session paused` → `session resuming after wake` → `streaming to iPad`, with no connect attempt between pause and resume.
- **Screensaver ×20:** `open -a ScreenSaverEngine`, then dismiss with a move on the iPad or the Mac's mouse within the lock delay.

## Rollback
The changes are self-contained: `PowerMonitor.swift`, the power section of `HostController` (`powerChanged`, `waitWhileAsleep`, `captureLost` / `recoverCapture`), the power gate in `InputInjector`, `VideoEncoder.encodeBlackFrame`, and the `main.swift` wiring. To return to the previous behaviour, revert the commit that adds this file. The wire protocol is unchanged (still 6), and the iPad app is untouched.
