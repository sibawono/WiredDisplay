# Implementation Queue (Bottleneck-First Priority)

## P0 - Critical Foundations & Correctness
1. **Q-01: Resolve all 3 Swift 6 `#SendableClosureCaptures` compiler warnings**
   - Files: `macOSHost/Host/InputInjector.swift:370`, `macOSHost/Host/HostController.swift:1375`, `Tests/Unit/WDVideoTests/VideoTests.swift:200,208`.
   - Status: PENDING.
2. **Q-02: Virtual Display macOS 26.1/27 Physical Size Floor, In-Place Rotation & Poisoned Identity Retry**
   - Add pure `DisplaySpace.safePhysicalSizeMillimeters(...)` (`>= 166 mm` width, `>= 160 cm^2` area, `>= 200 ppi` effective for HiDPI) in `Shared/HostCore/DisplaySpace.swift` + unit tests.
   - Add square `maxPixels >= 8192` headroom & `WDVirtualDisplayResize(...)` in-place mode update in `macOSHost/Display/CVirtualDisplay/WDVirtualDisplayShim.m` and `VirtualDisplayController.swift` so iPad rotation preserves windows instead of destroying the display.
   - Add poisoned-identity serial offset retry (up to 3 offsets) if `waitUntilOnline` fails.
   - Status: PENDING.
3. **Q-03: Unified Transport Abstraction (`TransportChannel` + `TransportMode`) & Secure Local Wi-Fi (`Network.framework` + Bonjour `_wireddisplay._tcp` + `SecureChannel`)**
   - `Shared/Transport/TransportMode.swift`: `.usbOnly`, `.wifiOnly`, `.automatic` (default `.usbOnly` until hardware-validated, switchable via UI/prefs).
   - `Shared/Transport/FramedConnection.swift`: protocol unifying `FramedSocket` (usbmuxd POSIX fd) and `NWFramedConnection` (`NWConnection` TCP with `noDelay = true`, `enableFastOpen = false`, `preferNoProxies = true`, `serviceClass = .interactiveVideo`, 5s dial timeout, `SecureChannel` AES-256-GCM + `SendScheduler`).
   - `Shared/Transport/BonjourDiscovery.swift`: macOS `NWBrowser` + iPadOS `NWListener` advertising `_wireddisplay._tcp` with TXT `v=1`, `id=<peerID>`.
   - Security rule: Wi-Fi connections NEVER allow silent TOFU; unknown Wi-Fi peers require explicit 6-digit SAS confirmation on Mac; already-trusted peers reconnect automatically.
   - Wire into `HostController` / `HostFleet` and `iPadOSClient` (`ClientSession.swift` listening on both `127.0.0.1:9100` for usbmuxd and local LAN Bonjour port for Wi-Fi, with transport preference UI).
   - Status: PENDING.

## P1 - Core Pipeline, Visual Quality & Adaptive Streaming
4. **Q-04: VideoEncoder Hardening, Single-Pass Annex-B & Live Bitrate Updates**
   - Single-pass `SampleBuffers.annexBPayload(from:codec:)` in `Shared/Video/SampleBuffers.swift` to eliminate per-frame `[[UInt8]]` -> `[UInt8]` double copy.
   - Clamp `kVTCompressionPropertyKey_AverageBitRate` to `Int(Int32.max)` bps; set `MaxFrameDelayCount = 0` on motion lane.
   - Add `EnableLowLatencyRateControl` fallback retry if `VTCompressionSessionCreate` fails.
   - Add live `VideoEncoder.updateBitrate(_:)` via `VTSessionSetProperty` without rebuilding session.
   - Add `dropReplayTimer` (1 frame interval) so coalesced/dropped final frames of a burst are re-encoded once GPU/encoder pressure clears.
   - Status: PENDING.
5. **Q-05: Adaptive Bitrate & Congestion Control (`AdaptiveBitrateController`)**
   - Pure, unit-tested `AdaptiveBitrateController` in `Shared/HostCore/AdaptiveBitrateController.swift`: tracks RTT, send-queue drops, and stability window; multiplicative decrease on congestion, slow additive increase on stability; clamps within transport bounds (USB-C: 30-120 Mbps, Wi-Fi: 6-50 Mbps); never changes logical desktop resolution.
   - Hook into `HostController` to drive `VideoEncoder.updateBitrate(_:)` live over Wi-Fi.
   - Status: PENDING.
6. **Q-06: iPadOS Display P3 Color Matching (BUG-033) & Fast Keyframe Recovery**
   - Update `MetalVideoRenderer.swift` to inspect `CVBufferCopyAttachment(pixelBuffer, kCVImageBufferColorPrimariesKey)` and switch `CAMetalLayer.colorspace` dynamically between `CGColorSpace.displayP3` and `CGColorSpace.sRGB`.
   - Add 200 ms forced-keyframe recovery throttle in `DecodeBacklog` / `MetalVideoRenderer` so Wi-Fi jitter stalls recover quickly without storming IDRs.
   - Status: PENDING.
7. **Q-07: Pipeline Instrumentation (`PipelineMetrics` + `os_signpost`) & Capture `screenRect` Guard**
   - Add `PipelineMetrics` in `Shared/HostCore/PipelineMetrics.swift` (rolling P50/P95/P99 latency + split `encDrops`/`netDrops`/`decDrops` counters) + unit tests.
   - Add `os_signpost` intervals at capture/encode boundaries in `CaptureEngine.swift` / `VideoEncoder.swift`.
   - Add `screenRect` vs `CGDisplayBounds` mismatch guard in `CaptureEngine.swift` (`queueDepth = 6`).
   - Status: PENDING.

## P2 - Hybrid Live Transport Migration & Polish
8. **Q-08: Transport-Generation-Fenced Live Migration (USB-C <-> Wi-Fi)**
   - In `HostController.swift`, add `transportGeneration` fence and `migrateTransport` path so discovering a trusted peer on USB-C while on Wi-Fi upgrades transport and requests an immediate IDR without destroying the virtual display.
   - Status: PENDING.
9. **Q-09: Independent Adversarial Audit, Full Build (macOS + iPadOS) & Validation**
   - Run full `swift test`, `swift build --product WiredDisplayHost`, iPadOS `xcodebuild`, protocol fuzz/malformed-packet tests, and independent adversarial review subagent.
   - Status: PENDING.
