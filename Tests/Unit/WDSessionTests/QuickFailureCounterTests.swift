import XCTest
@testable import WDSession

final class QuickFailureCounterTests: XCTestCase {
    func testFirstFailureIsNotAStreak() {
        var counter = QuickFailureCounter(window: 2)
        XCTAssertEqual(counter.failed(at: 100), 0)
    }

    /// Display sleep cycles: the capture runs for seconds between stops.
    func testFailuresAfterLongRunsStayAtZero() {
        var counter = QuickFailureCounter(window: 2)
        for cycle in 0..<20 {
            let t = Double(cycle) * 5
            XCTAssertEqual(counter.failed(at: t), 0)
            counter.recovered(at: t + 0.1)
        }
    }

    /// A capture that stops right after every restart builds a streak.
    func testFailuresRightAfterRecoveryBuildAStreak() {
        var counter = QuickFailureCounter(window: 2)
        XCTAssertEqual(counter.failed(at: 0), 0)
        counter.recovered(at: 0.1)
        XCTAssertEqual(counter.failed(at: 0.15), 1)
        counter.recovered(at: 0.7)
        XCTAssertEqual(counter.failed(at: 0.75), 2)
        counter.recovered(at: 1.8)
        XCTAssertEqual(counter.failed(at: 3.79), 3, "just inside the window")
    }

    func testALongRunEndsTheStreak() {
        var counter = QuickFailureCounter(window: 2)
        counter.failed(at: 0)
        counter.recovered(at: 0.1)
        XCTAssertEqual(counter.failed(at: 0.2), 1)
        counter.recovered(at: 1)
        XCTAssertEqual(counter.failed(at: 3), 0, "ran for the whole window")
    }

    /// A failure with no recovery in between (retries still running) is not
    /// counted as a quick failure.
    func testFailureWithoutRecoveryDoesNotExtendTheStreak() {
        var counter = QuickFailureCounter(window: 2)
        counter.failed(at: 0)
        XCTAssertEqual(counter.failed(at: 0.1), 0)
    }

    func testResetClearsTheStreak() {
        var counter = QuickFailureCounter(window: 2)
        counter.failed(at: 0)
        counter.recovered(at: 0.1)
        counter.failed(at: 0.2)
        counter.reset()
        XCTAssertEqual(counter.streak, 0)
        XCTAssertEqual(counter.failed(at: 0.3), 0)
    }
}
