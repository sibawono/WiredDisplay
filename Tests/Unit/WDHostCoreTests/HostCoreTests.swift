import CoreGraphics
import XCTest
import WDSession
@testable import WDHostCore

final class InputGateTests: XCTestCase {
    private let move = InputEvent.pointer(phase: .move, button: .none, x: 0.5, y: 0.5)
    private let click = InputEvent.pointer(phase: .down, button: .left, x: 0.5, y: 0.5)
    private let release = InputEvent.pointer(phase: .up, button: .left, x: 0.5, y: 0.5)

    func testEverythingPassesWhenAwakeAndUnlocked() {
        for event in [move, click, release, .key(usage: 4, down: true), .releaseAll] {
            XCTAssertEqual(InputGate.decision(for: event, state: PowerState()), .inject)
        }
    }

    func testLockedLetsMovesWakeAndNeverTypesOrClicks() {
        let locked = PowerState(locked: true)
        XCTAssertEqual(InputGate.decision(for: move, state: locked), .moveOnly)
        XCTAssertEqual(InputGate.decision(for: click, state: locked), .wakeAndDrop)
        XCTAssertEqual(InputGate.decision(for: .key(usage: 4, down: true), state: locked), .wakeAndDrop)
        XCTAssertEqual(InputGate.decision(for: .scroll(dx: 0, dy: 3), state: locked), .wakeAndDrop)
        XCTAssertEqual(InputGate.decision(for: .gestureScroll(dx: 0, dy: 1, phase: .began, momentum: .none), state: locked), .wakeAndDrop)
    }

    func testReleasesAndGestureStepsWhileLockedAreDropped() {
        let locked = PowerState(locked: true)
        XCTAssertEqual(InputGate.decision(for: release, state: locked), .drop)
        XCTAssertEqual(InputGate.decision(for: .key(usage: 4, down: false), state: locked), .drop)
        XCTAssertEqual(InputGate.decision(for: .gestureScroll(dx: 0, dy: 1, phase: .changed, momentum: .none), state: locked), .drop)
    }

    func testNothingPassesAsleepOrInAnotherSession() {
        for state in [PowerState(systemAsleep: true), PowerState(locked: true, sessionActive: false), PowerState(sessionActive: false)] {
            for event in [move, click, .key(usage: 4, down: true)] {
                XCTAssertEqual(InputGate.decision(for: event, state: state), .drop)
            }
        }
    }

    func testDisplaysAsleepAloneDoesNotBlock() {
        XCTAssertEqual(InputGate.decision(for: click, state: PowerState(displaysAsleep: true)), .inject)
    }
}

final class DisplaySpaceTests: XCTestCase {
    func testIPadAir13Sizes() {
        let sizes = DisplaySpace.modeSizes(panelWidth: 2732, panelHeight: 2048, hiDPI: true)
        XCTAssertEqual(sizes[.native], CGSize(width: 1366, height: 1024))
        XCTAssertEqual(sizes[.more], CGSize(width: 1536, height: 1152))
        XCTAssertEqual(sizes[.most], CGSize(width: 1708, height: 1280))
    }

    func testSidesAreEvenInPortraitToo() {
        for (space, size) in DisplaySpace.modeSizes(panelWidth: 2048, panelHeight: 2732, hiDPI: true) {
            XCTAssertEqual(Int(size.width) % 2, 0, "\(space)")
            XCTAssertEqual(Int(size.height) % 2, 0, "\(space)")
        }
    }

    func testMatchingFindsOnlyExactSizes() {
        XCTAssertEqual(DisplaySpace.matching(points: CGSize(width: 1536, height: 1152), panelWidth: 2732, panelHeight: 2048, hiDPI: true), .more)
        XCTAssertNil(DisplaySpace.matching(points: CGSize(width: 1440, height: 1080), panelWidth: 2732, panelHeight: 2048, hiDPI: true))
    }

    func testSafePhysicalSizeMeetsMacOS26And27HiDPIFloors() {
        // Portrait iPad mini (1488x2266 @ 326 ppi) has nominal width ~116 mm (< 166 mm macOS 27 floor).
        let portrait = DisplaySpace.safePhysicalSizeMillimeters(pixelWidth: 1488, pixelHeight: 2266, pixelsPerInch: 326, hiDPI: true)
        XCTAssertGreaterThanOrEqual(portrait.width, 175.0)
        XCTAssertGreaterThanOrEqual(portrait.width * portrait.height, 16_500.0)
        XCTAssertEqual(portrait.width / portrait.height, 1488.0 / 2266.0, accuracy: 0.001)

        // Landscape iPad Air 13" (2732x2048 @ 264 ppi) already exceeds both floors.
        let landscape = DisplaySpace.safePhysicalSizeMillimeters(pixelWidth: 2732, pixelHeight: 2048, pixelsPerInch: 264, hiDPI: true)
        XCTAssertEqual(landscape.width, 2732.0 / 264.0 * 25.4, accuracy: 0.1)
        XCTAssertEqual(landscape.height, 2048.0 / 264.0 * 25.4, accuracy: 0.1)

        // Default PPI (0 -> 264) works without division by zero.
        let fallback = DisplaySpace.safePhysicalSizeMillimeters(pixelWidth: 2048, pixelHeight: 2732, pixelsPerInch: 0, hiDPI: true)
        XCTAssertGreaterThanOrEqual(fallback.width, 175.0)
    }
}

final class CaptureSizingTests: XCTestCase {
    private let panel = CGSize(width: 2732, height: 2048)

    func testLargerFramebufferIsCapturedWhole() {
        XCTAssertEqual(CaptureSizing.size(panel: panel, framebuffer: CGSize(width: 3072, height: 2304), ownDownscale: true, wantsBGRA: true),
                       CGSize(width: 3072, height: 2304))
    }

    func testPanelSizeOtherwise() {
        let more = CGSize(width: 3072, height: 2304)
        XCTAssertEqual(CaptureSizing.size(panel: panel, framebuffer: more, ownDownscale: false, wantsBGRA: true), panel, "flag off")
        XCTAssertEqual(CaptureSizing.size(panel: panel, framebuffer: more, ownDownscale: true, wantsBGRA: false), panel, "8-bit 4:2:0 lane")
        XCTAssertEqual(CaptureSizing.size(panel: panel, framebuffer: panel, ownDownscale: true, wantsBGRA: true), panel, "native")
        XCTAssertEqual(CaptureSizing.size(panel: panel, framebuffer: CGSize(width: 5120, height: 2880), ownDownscale: true, wantsBGRA: true),
                       panel, "mirroring another aspect")
        XCTAssertEqual(CaptureSizing.size(panel: panel, framebuffer: CGSize(width: 9000, height: 6750), ownDownscale: true, wantsBGRA: true),
                       panel, "over 8192")
        XCTAssertEqual(CaptureSizing.size(panel: panel, framebuffer: nil, ownDownscale: true, wantsBGRA: true), panel, "no mode")
    }
}

final class AdaptiveBitrateTests: XCTestCase {
    func testDecreasesOnDropAndRecoversGraduallyWhenStable() {
        var controller = AdaptiveBitrateController(config: .wifi(ceilingMbps: 40))
        XCTAssertEqual(controller.currentMbps, 25)

        // Frame drop triggers multiplicative decrease.
        let lowered = controller.observe(rttMs: 12, droppedFrames: 1, queueDepth: 1, now: 1.0)
        XCTAssertEqual(lowered, 18)

        // Within 1s cooldown, another drop does not oscillate further.
        XCTAssertNil(controller.observe(rttMs: 40, droppedFrames: 2, queueDepth: 3, now: 1.5))

        // After cooldown, sustained high RTT decreases again.
        let loweredAgain = controller.observe(rttMs: 45, droppedFrames: 0, queueDepth: 1, now: 2.5)
        XCTAssertEqual(loweredAgain, 15)

        // Healthy window starts stability timer; after 3s it steps up by 2 Mbps.
        XCTAssertNil(controller.observe(rttMs: 8, droppedFrames: 0, queueDepth: 0, now: 3.0))
        XCTAssertNil(controller.observe(rttMs: 8, droppedFrames: 0, queueDepth: 0, now: 5.5))
        XCTAssertEqual(controller.observe(rttMs: 8, droppedFrames: 0, queueDepth: 0, now: 6.1), 17)
    }

    func testRespectsMinAndMaxBounds() {
        var controller = AdaptiveBitrateController(config: .init(minMbps: 6, maxMbps: 10, initialMbps: 8, decreaseCooldown: 0, increaseInterval: 1))
        for i in 0..<10 {
            _ = controller.observe(rttMs: 100, droppedFrames: 3, queueDepth: 4, now: Double(i))
        }
        XCTAssertEqual(controller.currentMbps, 6)

        for i in 10..<25 {
            _ = controller.observe(rttMs: 5, droppedFrames: 0, queueDepth: 0, now: Double(i))
        }
        XCTAssertEqual(controller.currentMbps, 10)
    }
}

final class PipelineMetricsTests: XCTestCase {
    func testPercentilesAndDropCounters() {
        var metrics = PipelineMetrics(capacity: 100)
        for v in 1...100 {
            metrics.recordLatencyMs(Double(v))
        }
        metrics.noteEncoderDrop()
        metrics.noteNetworkDrop()
        metrics.noteNetworkDrop()
        metrics.noteDecoderDrop()

        let s = metrics.summary()
        XCTAssertEqual(s.count, 100)
        XCTAssertEqual(s.p50Ms, 50)
        XCTAssertEqual(s.p95Ms, 95)
        XCTAssertEqual(s.p99Ms, 99)
        XCTAssertEqual(s.maxMs, 100)
        XCTAssertEqual(s.encoderDrops, 1)
        XCTAssertEqual(s.networkDrops, 2)
        XCTAssertEqual(s.decoderDrops, 1)
    }
}
