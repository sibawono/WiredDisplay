import XCTest
@testable import WDSession

final class GestureTrackerTests: XCTestCase {
    func testNothingOpenAtStart() {
        var tracker = GestureTracker()
        XCTAssertEqual(tracker.takeOpen(), [])
    }

    func testBeganWithoutEndStaysOpen() {
        var tracker = GestureTracker()
        tracker.note(.scroll, phase: .began)
        tracker.note(.scroll, phase: .changed)
        tracker.note(.magnify, phase: .began)
        XCTAssertEqual(tracker.openGestures, [.scroll, .magnify])
    }

    func testEndedAndCancelledClose() {
        var tracker = GestureTracker()
        tracker.note(.scroll, phase: .began)
        tracker.note(.scroll, phase: .ended)
        tracker.note(.rotate, phase: .began)
        tracker.note(.rotate, phase: .cancelled)
        XCTAssertEqual(tracker.takeOpen(), [])
    }

    func testMomentumIsTrackedSeparately() {
        var tracker = GestureTracker()
        tracker.note(.scroll, phase: .began)
        tracker.note(.scroll, phase: .ended)
        tracker.note(momentum: .begin)
        tracker.note(momentum: .continue)
        XCTAssertEqual(tracker.openGestures, [.momentum])
        tracker.note(momentum: .end)
        XCTAssertEqual(tracker.openGestures, [])
    }

    func testTakeOpenClearsSoEndsArePostedOnce() {
        var tracker = GestureTracker()
        tracker.note(.scroll, phase: .began)
        tracker.note(.rotate, phase: .began)
        XCTAssertEqual(tracker.takeOpen(), [.scroll, .rotate])
        XCTAssertEqual(tracker.takeOpen(), [], "a second releaseAll posts nothing")
    }
}
