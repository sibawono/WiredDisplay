# Benchmarks & Performance Measurements

## Test Environment
- **Host OS / SDK**: macOS 27.2 (`arm64-apple-macosx27.2.0`), Xcode 27.2 (27B52), Apple Swift 6.4.2
- **Host CPU / RAM**: 12-core Apple Silicon (2 Super, 4 Performance, 6 Efficiency), 16 GB RAM
- **Physical Receiver**: iPad Air 13-inch (M2) (`iPad14,10`, 60 Hz panel)

## Baseline Measurements (Commit `de29a51`, WiredDisplay 0.5.3 build 12)
- **Unit Test Suite (`swift test`)**: 8 test suites, 189 XCTest cases executed, 0 failures (1 skipped), total runtime ~6.1s.
- **Compiler Diagnostics**: 3 Swift 6 `#SendableClosureCaptures` warnings (`InputInjector.swift:370`, `HostController.swift:1375`, `VideoTests.swift:200,208`).
- **Video Frame Serialization**: Baseline `SampleBuffers.accessUnit` + `unit.annexB` allocates intermediate `[[UInt8]]` array of NALs then copies into `[UInt8]`.

## Post-Optimization Measurements
*(To be populated after implementing Q-01 through Q-08 with reproducible microbenchmarks and real builds.)*
