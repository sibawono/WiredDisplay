# Validation Report

## Stage 0 Baseline (`de29a51`)
- `swift test`: PASS (8 suites, 189 tests, 0 failures, 1 skipped).
- Pre-existing warnings: 3 Swift 6 `#SendableClosureCaptures` warnings.

## Final Branch Validation (`v3-comparative-engineering`)
- `swift build --product WiredDisplayHost`: PASS (0 warnings, 0 errors).
- `swift test`: PASS (all 8 test suites, 195 tests executed, 0 failures, 1 skipped):
  - `WDVideoTests`: 11 tests PASS (including byte-for-byte parity of single-pass `SampleBuffers.annexBPayload` vs `accessUnit` on real hardware H.264 & HEVC).
  - `WDHostCoreTests`: 14 tests PASS (including `DisplaySpace.safePhysicalSizeMillimeters`, `AdaptiveBitrateController`, `PipelineMetrics`).
  - `WDTransportTests`: 10 tests PASS (including `NWFramedConnectionTests` encrypted Ed25519/X25519/AES-256-GCM handshake + video round-trip + malformed garbage rejection over `Network.framework`).
  - `CVirtualDisplayTests`: 3 tests PASS.
  - `WDProtocolTests`, `WDSessionTests`, `WDUsbmuxTests`, `WDGeometryTests`: ALL PASS.
- `xcodebuild` (`WiredDisplayClient`, `generic/platform=iOS`, arm64 Debug): PASS (`** BUILD SUCCEEDED **`).

## Independent Adversarial Audit (Stage 13-14)
All 7 findings identified by the independent auditor were fixed and re-verified:
1. [HIGH] Removed local username/path leak from `docs/research/v3/UPSTREAM_SOURCE_MANIFEST.md`.
2. [HIGH] Moved USB-C upgrade probe off `queue` onto utility queue and verified actual `clientPort` listener before closing Wi-Fi session (prevents infinite 2s disconnect loop when unrelated USB devices like an iPhone are plugged in).
3. [MEDIUM] Fixed `HostController.runLoop()` Wi-Fi peer iteration to try remaining Bonjour peers if the first peer fails.
4. [MEDIUM] Fixed `NWFramedConnection.send()` return value on framing failure, closed `start()`/`close()` `dialTimer` race, and enqueued `authHelloPayload` deterministically at seq 0 in `start()`.
5. [MEDIUM] Fixed `SampleBuffers.annexBPayload` to only strip in-band parameter sets when format-description parameter sets were resolved, and propagate errors consistently with `accessUnit`.
6. [LOW] Fixed `CaptureEngine` `screenRect` guard to ignore transiently empty bounds during wake/reconfig.
7. [LOW] Added 5s recovery retry to `ClientSession.startWiFiListener()` on `.failed`.

## Remaining Physical-Device Validations (User / Lab Hardware Required)
- Live USB-C <-> Wi-Fi end-to-end streaming & migration on physical iPad Air 13-inch (M2).
- 2-hour continuous soak test (USB-C and Wi-Fi) and 20-cycle lock/sleep/screensaver series.
- 100-cycle physical cable unplug/replug & Wi-Fi impairment (`Network Link Conditioner`) test.
- 120 Hz ProMotion bitrate scaling (requires ProMotion iPad).
- High-speed camera physical glass-to-glass / input-to-photon latency measurement.
