# OpenDisplay Source Map

Repository: `https://github.com/peetzweg/opendisplay` @ `7f61aeb619a93c3a5b310107cdd7029c8708e433` (v1.30.3+, GPL-3.0)

## Apple-Native Host Components (`Mac/`)
| File | Key Symbols | Role & Verified Behavior |
|---|---|---|
| `CGVirtualDisplayPrivate.h` | `CGVirtualDisplay*` | Private CoreGraphics virtual display header |
| `VirtualDisplay.swift` | `VirtualDisplay`, `resize`, `ensureNotMirrored`, `selectTargetMode`, `manageOrigin`, `DisplayUnits.clash` | `maxPixelsWide/High >= 8192` headroom for in-place rotation, 200ms/2000ms enforcement loop, `.forSession` mirror dissolution (`== 1` check), unit-number clash recovery |
| `VirtualCanvasSizing.swift` | `physicalSizeInMillimeters`, `bootstrapSize` | Empirical macOS 26.1/27 physical size floor (`208x96 mm` landscape, `175x380 mm` portrait) to prevent 1x fallback or online refusal; `3200x1800` bootstrap -> in-place promote |
| `DesktopPolicy.swift` | `plan`, `canvas`, `oneXFallback`, `DisplaySizeStore` | `minimumTwoXPoints = 526` floor, 1:1 canvas cap when stream < panel (avoids double scaling), per-`installID` persistence |
| `DisplayArrangement.swift`, `OriginRestore.swift` | `DisplayArrangement`, `OriginRestore` | Side-preserving arrangement across rotation; 6s origin enforcement measured from first post-wake tick |
| `MacSender.swift` | `setupExtend`, `startCapture`, `setupEncoder`, `shouldDropFrame`, `scheduleDropReplayTimer`, `enqueueFramed`, `switchTransport`, `startUpgradeProbing`, `consoleIsInteractive` | `SCStream` (`1/120` interval, `420v`, `queueDepth = 8`), `VTCompressionSession` (HEVC arm64 / H.264 High@L5.2, low-latency RC with `nil` fallback, `maxPendingEncodes = 1`, `maxPendingSends = 3`), drop-replay timer, 30-failure HEVC->H.264 fallback, poisoned display identity 3-offset retry, live `switchTransport` without destroying display, `preferNoProxies = true` |
| `CaptureSourceCheck.swift` | `CaptureSourceCheck` | Verifies `SCStreamFrameInfo.screenRect` against `CGDisplayBounds(displayID)`; re-attaches capture if mismatched >= 1.5s |
| `StreamConfiguration.swift` | `VideoStreamConfiguration`, `FrameRateLimiter` | H.264 L5.2 macroblock cap, Best/Balanced/Fast (18/10/6 Mbps), deadline-anchored fractional FPS limiter |
| `Usbmux.swift` | `Usbmux.connect`, `Usbmux.deviceName`, `UsbmuxDeviceWatcher` | Direct `/var/run/usbmuxd` over `NWConnection(.unix)` (no libusbmuxd); `ListDevices` + `Listen` + `lockdownd` port 62078 |
| `InputInjector.swift` | `InputInjector` | Touch hold-delay (0.12s / 10pt) with 2-finger cancel (`clickState = 0`), Apple Pencil `.tabletProximity`/`.tabletPoint` + tilt + synthetic multi-click. No keyboard/trackpad. |
| `OpenSidecarMacApp.swift` | `SenderController.upgradeToUSB`, `failover` | `NWBrowser` for `_opensidecar._tcp`, coordinates live USB<->Wi-Fi switching |

## Apple-Native Receiver & Shared Components (`Shared/`, `iOS/`)
| File | Key Symbols | Role & Verified Behavior |
|---|---|---|
| `Shared/StreamReceiver.swift` | `startListener`, `pendingConnections`, `AVSampleBufferDisplayLayer`, `VTDecompressionSession` | TCP 9000 (`noDelay = true`, `serviceClass = .interactiveVideo`) + Bonjour `_opensidecar._tcp` + UDP 9001 cursor (`serviceClass = .responsiveData`), newcomer parking, default AVSBDL + opt-in NV12 Metal |
| `iOS/OpenSidecarPhoneApp.swift` | `InputCaptureEngine`, `enterSleep`, `protectedDataWillBecomeUnavailableNotification` | Distinguishes screen lock (`sleeping`) vs app switch (keep display alive), rotation blur hold, 120 Hz local cursor `CALayer`, Pencil hover/tilt/coalesced+predicted touch |
| `iOS/MetalVideoRenderer.swift` | `MetalVideoRenderer` | Inline MSL BT.709 NV12->BGRA8, `maximumDrawableCount = 3`, single latest-wins `pendingFrame`, `addPresentedHandler` |
| `iOS/DecodeBudget.swift` | `DecodeBudget` | Advertises H.264 L4.2 pixel-rate cap for legacy A8/A8X iPads |
| `Shared/DirectCable.swift` | `DirectCable.carries` | Detects direct Thunderbolt/USB-C host-to-host cable; excludes `awdl*`/`llw*`/`anpi*`/`utun*` |

## Non-Apple Components (Verified Scope)
- `linux/`: Rust workspace (`Cargo.toml`, 5 crates) strictly for Linux sender/receiver. Not used on Apple platforms.
- `Android/`: Kotlin/Gradle receiver.

## Key Historical Fixes (Git Archaeology)
- `964d5678`: `minimumFrameInterval = 1/120`, `queueDepth = 8`, `MaxFrameDelayCount = 0`, receiver `noDelay = true`.
- `49b4b8d8`: Metal renderer A/B benchmark (3 drawables NV12 latest-wins; AVSBDL remains fast hardware compositor).
- `0490441c` / `c8b24177`: `maxPendingEncodes = 1` + `dropReplayTimer` to prevent stale final-frame divergence.
- `ceebb2d4`: Re-attach `SCStream` on death instead of rebuilding `CGVirtualDisplay` (avoids multi-display rebuild loop).
- `2a4abf74`: In-place `VirtualDisplay.resize()` on rotation + side-preserving `DisplayArrangement`.
- `87b000b9`: Poisoned virtual display identity 3-offset retry after macOS "Stop Extending".
- `d9eb302d`: `VTCompressionSessionCreate` fallback when `EnableLowLatencyRateControl` fails.
- `09e717ed`: Defer capture recovery during display sleep / screen lock (`CGSessionCopyCurrentDictionary` + `CGDisplayIsAsleep`).
- `f244d630`: 1:1 virtual display canvas cap when stream < panel.
- `91b87838` / `8568e181`: macOS 26.1/27 physical `sizeInMillimeters` floor (`208x96 mm` / `175x380 mm`).
- `5de42527` / `ac3b3cbf`: `CGDisplayUnitNumber` clash avoidance; `preferNoProxies = true` to bypass Clash/Surge proxies.
- `8fecc3c4`: Live USB <-> Wi-Fi `switchTransport(to:)` without tearing down virtual display.
