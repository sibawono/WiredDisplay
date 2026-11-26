# WiredDisplay V3 Comparative Engineering Research State

Last updated: 2026-11-26
Development branch: `v3-comparative-engineering` (branched from `main` @ `de29a51`, WiredDisplay 0.5.3 build 12)

## Stage Status
- Stage 0 (Environment & Baseline): DONE. Baseline `swift test` passed (8 suites, 189 tests, 0 failures; 3 pre-existing Swift 6 warnings).
- Stage 1 (Upstream Acquisition & Licensing): DONE. SideScreen (`6ec6e317`, MIT) and OpenDisplay (`7f61aeb6`, GPL-3.0) cloned outside repo; WiredDisplay is GPL-3.0 (compatible).
- Stage 2 (Independent Source Reconstruction): DONE for WiredDisplay, SideScreen, and OpenDisplay.
- Stage 3 (Git Archaeology): DONE (11 SideScreen commits, 12 OpenDisplay commits analyzed with diffs).
- Stage 4 (Three-Way Comparative Matrix): DONE (`THREE_WAY_COMPARISON.md`).
- Stage 5 (Bottleneck Prioritization): DONE (`IMPLEMENTATION_QUEUE.md`).
- Stage 6 (Source Extraction & Reuse Registry): DONE (`SOURCE_REUSE_REGISTRY.md`, `THIRD_PARTY_NOTICES.md`).
- Stage 7 (Concurrency & Correctness): DONE (0 warnings across Swift 6 strict concurrency).
- Stage 8 (Virtual Display, HiDPI, Capture, Encode, Decode, Render): DONE (macOS 26/27 physical size floor, in-place rotation, poisoned serial retry, single-pass Annex-B, live bitrate, drop replay, Display P3 `CAMetalLayer` fix, 200 ms IDR throttle, `screenRect` guard).
- Stage 9-10 (Unified Transport, Secure Local Wi-Fi & Hybrid USB-C Upgrade): DONE (`FramedTransport`, `NWFramedConnection`, `BonjourBrowser`, strict Wi-Fi SAS auth, `AdaptiveBitrateController`, off-queue USB-C upgrade probe, iPadOS dual listener + Bonjour + Local Network Info.plist).
- Stage 11-12 (Automated Builds & Unit/Integration Validation): DONE (`WiredDisplayHost`, `WiredDisplayClient` arm64 iOS, all 8 SwiftPM test suites). Physical-device soak/latency benchmarks documented as pending hardware run.
- Stage 13-14 (Independent Adversarial Audit & Remediation): DONE (all 7 audit findings resolved and re-verified).
- Stage 15 (Final Engineering Report): DONE.
