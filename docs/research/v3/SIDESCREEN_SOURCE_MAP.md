# SideScreen Source Map

Repository: `https://github.com/tranvuongquocdat/SideScreen` @ `6ec6e317e448b2858340824b286293423a54f202` (v1.2.1, MIT)

## MacHost Components (`MacHost/Sources/`)
| File | Key Symbols | Role & Verified Behavior |
|---|---|---|
| `CGVirtualDisplayBridge.h` | `CGVirtualDisplay*` | Obj-C forward declarations for private CoreGraphics virtual display APIs |
| `VirtualDisplayManager.swift` | `createDisplay`, `disableMirrorMode`, `ensurePhysicalDisplayStaysMain`, `restoreDisplayPosition` | 2x HiDPI (`ppi = 220`, physical anchor + logical mode), `productID = physW*10000 + physH`, `.forSession` display config, guards physical main display against headless lockout (#39) |
| `ScreenCapture.swift` | `setupDisplay`, `setupStream`, `startFrameMonitor`, `restartStream`, `attemptFallbackCapture`, `requestKeyframeOrReplayCachedFrame`, `handleWake` | `SCStream` (`420v`, `queueDepth = 4`, `showsCursor = true`, 10s timeout on `SCShareableContent`), `OSAtomicAdd32` `pendingEncodes >= 2` drop, idle-screen keepalive replay, `CGDisplayStream` fallback, `IOPMAssertion` display sleep lock |
| `VideoEncoder.swift` | `setupCompressionSession`, `updateSettings`, `encode`, `encodingOutputCallback`, `averageBitRateBps` | `VTCompressionSession` HEVC/H.264 Main profile, `RealTime = true`, `AllowFrameReordering = false`, `MaxFrameDelayCount = 0`, 1s GOP (`frameRate`/`1.0`), no `DataRateLimits`, live `VTSessionSetProperty` bitrate update clamped to `Int32.max`, serialized on `sessionQueue` |
| `CodecLimits.swift` | `clampToClientLimit` | Per-FPS (30/60/120) decoder limit clamping, orientation transpose, exact panel size preservation when aspect matches |
| `StreamingServer.swift` | `ListenerStartupGate`, `sendFrame`, `processInputBuffer`, `beginExistingProtocol` | Single TCP `NWListener` (port 54321, `noDelay = true`, TFO removed in `18b4881`), `waitingForSyncFrame` IDR gate, unencrypted stream, no send backpressure |
| `WirelessAuth.swift`, `HandshakeCodec.swift`, `PairingCode.swift` | `WirelessAuth.validate`, `PairingCode` | Plaintext 32-byte token in `UserDefaults`, constant-time XOR validate, 8-digit one-time pairing code (max 5 tries) |
| `AppDelegate.swift` | `setupADBReverse`, `refreshStatusIndicators`, `handleTouchEvent`, `handleTwoFingerTouch` | USB via `adb reverse` (self-healing 2s poll), touch-only 1-finger/2-finger `CGEvent` injection with momentum scroll |
| `DeviceProfileStore.swift` | `DeviceProfileStore` | Persists up to 20 per-tablet profiles in `UserDefaults` |
| `DaemonManager.swift` | `DaemonManager` | `SMAppService.mainApp` Login Item |

## AndroidClient Relevant Algorithms (`AndroidClient/app/src/main/java/com/sidescreen/app/`)
| File | Key Symbols | Role & Verified Behavior |
|---|---|---|
| `VideoDecoder.kt` | `decode`, `handleOutputBuffer`, `requestKeyframe` | Direct-feed `ConcurrentLinkedQueue<Int>` input buffers, 3-tier `MediaCodec` low-latency fallback, keeps feeding on pool exhaustion + 200 ms forced-IDR throttle (`e529565`), drops outputs with `latencyNs > 100 ms` |
| `CodecCapabilities.kt` | `preferredStreamMime`, `maxStreamSize`, `fitStreamSize` | Hardware decoder probing via `areSizeAndRateSupported` at `[30, 60, 120]` fps, prefers H.264 if area gain >= 1.2x over HEVC |
| `StreamClient.kt` | `openWirelessSocket`, `isSyncFrame` | `wifiNetwork.bindSocket` + `tcpNoDelay`, 8-buffer recycled `ByteArray` pool, Annex-B HEVC IRAP (16..21) / H.264 IDR (5) detector |
| `InputPredictor.kt` | `InputPredictor` | 2-point linear velocity extrapolation (+12 ms hardcoded lookahead on 1-finger move; no smoothing or RTT feedback) |

## Key Historical Fixes (Git Archaeology)
- `920dc2c`: Zero-copy `CVPixelBuffer` to VT + direct-feed decoder + RTT ping/pong.
- `abeaf13`: 2x HiDPI virtual display (`ppi = 220`, physical anchor mode, non-colliding `productID`).
- `049caf8`: Idle-screen `SCStream` silence treated as keepalive replay instead of crash restart.
- `6ffb11c` / `38faae4`: Short-GOP IPP + forced IDR replay + `waitingForSyncFrame` startup gate.
- `6cd6036`: Stale output drop (>100 ms), coalesced input loop, worker-thread priority fix.
- `e529565`: 200 ms forced keyframe request on buffer pool exhaustion (fixes Wi-Fi jitter ghost cursor).
- `18b4881`: Disabled TCP Fast Open (`enableFastOpen`) to fix `.preparing` hangs on hotspots/NAT.
- `27c51dd`: `.forSession` display config + `ensurePhysicalDisplayStaysMain` (prevents headless main-display lockout).
- `4fe0ac3` / `d7d334d`: Display sleep/wake recovery with `streamGeneration` token + `IOPMAssertion`.
- `540e1fc`: `420v` video-range capture + explicit BT.709 VUI tags (fixes vendor highlight clipping).
- `853ed08` / `f5bab86`: Per-rate decoder limits, serialized `sessionQueue`, live bitrate updates, `Int32.max` clamp.
