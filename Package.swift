// swift-tools-version: 6.0
import PackageDescription

// Shared logic (protocol, session, video, usbmux, geometry), the private-API
// display shim, the macOS host app, and feasibility probes.
// The iPad apps are Xcode projects under iPadOSClient/ that use this package.
let package = Package(
    name: "WiredDisplay",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "WDProtocol", targets: ["WDProtocol"]),
        .library(name: "WDSession", targets: ["WDSession"]),
        .library(name: "WDVideo", targets: ["WDVideo"]),
        .library(name: "WDUsbmux", targets: ["WDUsbmux"]),
        .library(name: "WDGeometry", targets: ["WDGeometry"]),
        .library(name: "WDTransport", targets: ["WDTransport"]),
    ],
    targets: [
        .target(name: "WDProtocol", path: "Shared/Protocol"),
        .target(name: "WDSession", dependencies: ["WDProtocol"], path: "Shared/Session"),
        .target(name: "WDVideo", path: "Shared/Video"),
        .target(name: "WDUsbmux", path: "Shared/Usbmux"),
        .target(name: "WDGeometry", path: "Shared/Geometry"),
        .target(name: "CAoaUSB", path: "Shared/CAoaUSB", linkerSettings: [.linkedFramework("IOKit"), .linkedFramework("CoreFoundation")]),
        .target(name: "WDTransport", dependencies: ["WDProtocol", "WDSession", "CAoaUSB"], path: "Shared/Transport"),
        // macOS CoreAudio helpers for the host and the audio probe.
        .target(name: "WDMacAudio", dependencies: ["WDSession"], path: "Shared/MacAudio"),
        // The host's pure decisions (power gating, display sizes, capture size), unit-tested.
        .target(name: "WDHostCore", dependencies: ["WDSession"], path: "Shared/HostCore"),

        // Private CGVirtualDisplay access, isolated in one Objective-C shim that
        // resolves every class and selector at runtime and fails closed.
        .target(name: "CVirtualDisplay", path: "macOSHost/Display/CVirtualDisplay"),

        // macOS host: virtual display -> capture -> encode -> USB -> iPad, and
        // iPad input -> CGEvent. Packaged as an app by scripts/build-host-app.sh.
        .executableTarget(
            name: "WiredDisplayHost",
            dependencies: ["WDProtocol", "WDSession", "WDVideo", "WDUsbmux", "WDGeometry", "WDTransport", "WDMacAudio", "WDHostCore",
                           "CVirtualDisplay"],
            path: "macOSHost/Host"
        ),

        .executableTarget(
            name: "wd-usbmux-probe",
            dependencies: ["WDProtocol", "WDUsbmux"],
            path: "macOSHost/Probes/wd-usbmux-probe"
        ),
        .executableTarget(
            name: "wd-audio-probe",
            dependencies: ["WDMacAudio"],
            path: "macOSHost/Probes/wd-audio-probe"
        ),
        .executableTarget(
            name: "wd-vdisplay-probe",
            dependencies: ["CVirtualDisplay"],
            path: "macOSHost/Probes/wd-vdisplay-probe"
        ),

        .testTarget(name: "WDProtocolTests", dependencies: ["WDProtocol"], path: "Tests/Unit/WDProtocolTests"),
        .testTarget(name: "WDSessionTests", dependencies: ["WDSession", "WDProtocol"], path: "Tests/Unit/WDSessionTests"),
        .testTarget(name: "WDVideoTests", dependencies: ["WDVideo"], path: "Tests/Unit/WDVideoTests"),
        .testTarget(name: "WDUsbmuxTests", dependencies: ["WDUsbmux"], path: "Tests/Unit/WDUsbmuxTests"),
        .testTarget(name: "CVirtualDisplayTests", dependencies: ["CVirtualDisplay"], path: "Tests/Unit/CVirtualDisplayTests"),
        .testTarget(name: "WDTransportTests", dependencies: ["WDTransport", "WDProtocol", "WDSession"], path: "Tests/Unit/WDTransportTests"),
        .testTarget(name: "WDGeometryTests", dependencies: ["WDGeometry"], path: "Tests/Unit/WDGeometryTests"),
        .testTarget(name: "WDHostCoreTests", dependencies: ["WDHostCore", "WDSession"], path: "Tests/Unit/WDHostCoreTests"),
    ],
    swiftLanguageModes: [.v6]
)
