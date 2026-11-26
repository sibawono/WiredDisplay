# Third-Party Notices & Engineering Attribution

WiredDisplay is licensed under the GNU General Public License v3.0 (`LICENSE`).
During the V3 comparative engineering effort, the following open-source projects were analyzed as engineering references. All WiredDisplay changes are written in idiomatic Swift 6 / Objective-C for WiredDisplay's architecture, and no new third-party package dependencies were added.

## 1. SideScreen
- **Repository**: `https://github.com/tranvuongquocdat/SideScreen`
- **Analyzed Revision**: `6ec6e317e448b2858340824b286293423a54f202` (v1.2.1)
- **License**: MIT License (Copyright (c) 2025 Side Screen)
- **Referenced Engineering Techniques**:
  - Clamping `kVTCompressionPropertyKey_AverageBitRate` to `Int32.max` and live bitrate updates via `VTSessionSetProperty` (commit `f5bab86`).
  - Disabling TCP Fast Open on `NWListener` to avoid hotspot/NAT `.preparing` stalls (commit `18b4881`).
  - 200 ms forced-keyframe recovery throttle on jitter/buffer exhaustion (commit `e529565`).

## 2. OpenDisplay
- **Repository**: `https://github.com/peetzweg/opendisplay`
- **Analyzed Revision**: `7f61aeb619a93c3a5b310107cdd7029c8708e433` (v1.30.3+)
- **License**: GNU General Public License v3.0
- **Referenced Engineering Techniques**:
  - macOS 26.1/27 virtual display minimum physical `sizeInMillimeters` floor (`208x96 mm` landscape / `175x380 mm` portrait) to prevent 1x fallback or online refusal (commits `91b87838`, `8568e181`).
  - In-place `CGVirtualDisplay` resize on rotation with square `maxPixels >= 8192` headroom and 3-offset poisoned display identity retry (commits `2a4abf74`, `87b000b9`).
  - `VTCompressionSessionCreate` fallback when `EnableLowLatencyRateControl` is unsupported, and drop-replay timer to prevent final-frame divergence (commits `d9eb302d`, `c8b24177`).
  - `Network.framework` `preferNoProxies = true` and `serviceClass = .interactiveVideo` for local LAN connections, plus live transport switching preserving virtual display state (commits `ac3b3cbf`, `8fecc3c4`).
