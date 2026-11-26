# Upstream Source Manifest

## 1. Development Target: WiredDisplay
- **Repository**: `https://github.com/sibawono/WiredDisplay`
- **Local Path**: repository root
- **Base Commit**: `de29a51` (`main`, WiredDisplay 0.5.3 build 12)
- **Dev Branch**: `v3-comparative-engineering`
- **License**: GNU General Public License v3.0 (`LICENSE`)
- **Toolchain**: Apple Swift 6.4.2, Xcode 27.2 (27B52), macOS 27.2 SDK (`arm64-apple-macosx27.2.0`)
- **Targets**: SwiftPM (`Package.swift`, Swift 6.0, macOS 14+, iOS 17+) + iPadOS Xcode project (`iPadOSClient/WiredDisplayClient`) + HAL C AudioServerPlugIn (`MacVirtualDevices/AudioDriver`)

## 2. Primary Research Source A: SideScreen
- **Website**: `https://www.sidescreen.dev/`
- **Repository**: `https://github.com/tranvuongquocdat/SideScreen`
- **Clone Path**: `/tmp/wd-upstream-research/SideScreen` (isolated outside WiredDisplay tree)
- **Branch**: `main`
- **Commit SHA**: `6ec6e317e448b2858340824b286293423a54f202`
- **Tag / Version**: `1.2.1-1-g6ec6e31` (v1.2.1)
- **License**: MIT License (`LICENSE:1-21`, Copyright (c) 2025 Side Screen)
- **Open-Source vs Pro Split**: Open-source repo is 100% MIT. Closed-source `SideScreen Pro` binary gates multi-tablet, audio streaming, pinned display, and connection check. No proprietary binaries inspected or used.
- **Dependencies**:
  - `MacHost`: Swift 5.9 (macOS 13+), only 1 third-party dep (`Sparkle >= 2.10.1`, MIT).
  - `AndroidClient`: Kotlin/Gradle (`minSdk 26`, `targetSdk 36`), AndroidX, CameraX, ML Kit barcode-scanning, Play Core.
- **Supported Platforms**: macOS host -> Android tablet client (USB via `adb reverse`, Wi-Fi via manual IP/QR/8-digit code).

## 3. Primary Research Source B: OpenDisplay
- **Website**: `https://opendisplay.app/`
- **Repository**: `https://github.com/peetzweg/opendisplay`
- **Clone Path**: `/tmp/wd-upstream-research/OpenDisplay` (isolated outside WiredDisplay tree)
- **Branch**: `main`
- **Commit SHA**: `7f61aeb619a93c3a5b310107cdd7029c8708e433`
- **Tag / Version**: `v1.30.3-7-g7f61aeb`
- **License**: GNU General Public License v3.0 (`LICENSE:1-674`; relicensed from MIT in `22607a760afe0589f1f2485743b0a972b5f71804`)
- **Language / Architecture Verification**:
  - Apple targets (`OpenSidecarMac` macOS 14+, `OpenSidecarMacReceiver` macOS 12+, `OpenSidecariOS` iOS 15+, `OpenSidecarMacTests`): **100% Swift 5.9 + minimal Obj-C/C bridging header (`CGVirtualDisplayPrivate.h`)**.
  - **Rust (`linux/Cargo.toml`, 5 crates under `linux/crates/`) is strictly Linux-only.** Zero Rust in macOS/iOS targets.
- **Dependencies**:
  - `OpenSidecarMac`: only `Sparkle >= 2.6.0` (MIT).
  - `OpenSidecariOS`: zero third-party dependencies.
  - No `libusbmuxd` or `libimobiledevice` (speaks `/var/run/usbmuxd` directly over `Network.framework`).
- **Supported Platforms**: macOS/Linux host -> iOS/iPadOS, macOS, Android, Linux receivers (USB via usbmuxd/AOA, Wi-Fi via Bonjour + TCP 9000 + UDP 9001 cursor).

## 4. License Compatibility Verdict
- WiredDisplay is GPL-3.0.
- SideScreen (MIT) -> GPL-3.0 compatible (retain MIT copyright & permission notice if adapted).
- OpenDisplay (GPL-3.0) -> GPL-3.0 compatible (retain copyright notice & provenance if adapted).
- Policy adopted: prefer clean, idiomatic Swift 6 independent or adapted implementations tailored to WiredDisplay's architecture, with zero new third-party dependencies and full attribution in `THIRD_PARTY_NOTICES.md`.
