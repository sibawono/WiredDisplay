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
