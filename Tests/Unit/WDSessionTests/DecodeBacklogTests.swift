import XCTest
@testable import WDSession

final class DecodeBacklogTests: XCTestCase {
    func testDecoderKeepingUpDecodesEverything() {
        var backlog = DecodeBacklog(limit: 3)
        XCTAssertEqual(backlog.admit(isKeyframe: true), .decode)
        backlog.finished()
        for _ in 0..<600 {
            XCTAssertEqual(backlog.admit(isKeyframe: false), .decode)
            backlog.finished()
        }
        XCTAssertEqual(backlog.queued, 0)
    }

    /// Issue #1: a decoder slower than the stream must not build a queue of
    /// seconds; frames beyond the limit are dropped until a keyframe.
    func testSlowDecoderIsBoundedAndWaitsForAKeyframe() {
        var backlog = DecodeBacklog(limit: 3)
        XCTAssertEqual(backlog.admit(isKeyframe: true), .decode)
        XCTAssertEqual(backlog.admit(isKeyframe: false), .decode)
        XCTAssertEqual(backlog.admit(isKeyframe: false), .decode)
        XCTAssertEqual(backlog.admit(isKeyframe: false), .drop(overflow: true))
        XCTAssertEqual(backlog.admit(isKeyframe: false), .drop(overflow: false))
        XCTAssertEqual(backlog.queued, 3, "never more than the limit waiting")
        // The decoder catches up, but P-frames still wait for a keyframe:
        // their references were dropped.
        backlog.finished(); backlog.finished(); backlog.finished()
        XCTAssertEqual(backlog.admit(isKeyframe: false), .drop(overflow: false))
        XCTAssertEqual(backlog.admit(isKeyframe: true), .decodeSkippingQueued)
        XCTAssertEqual(backlog.admit(isKeyframe: false), .decode)
    }

    func testKeyframeIntoAFullQueueSkipsTheOlderFrames() {
        var backlog = DecodeBacklog(limit: 2)
        _ = backlog.admit(isKeyframe: true)
        _ = backlog.admit(isKeyframe: false)
        XCTAssertEqual(backlog.admit(isKeyframe: true), .decodeSkippingQueued)
        XCTAssertEqual(backlog.queued, 3, "skipped frames still finish and are counted until then")
        backlog.finished(); backlog.finished(); backlog.finished()
        XCTAssertEqual(backlog.queued, 0)
    }

    func testOneOverflowEventPerStall() {
        var backlog = DecodeBacklog(limit: 1)
        _ = backlog.admit(isKeyframe: true)
        var overflows = 0
        for _ in 0..<10 { if case .drop(true) = backlog.admit(isKeyframe: false) { overflows += 1 } }
        XCTAssertEqual(overflows, 1)
    }

    func testFinishedNeverGoesNegative() {
        var backlog = DecodeBacklog()
        backlog.finished()
        XCTAssertEqual(backlog.queued, 0)
    }

    func testResetEndsTheWaitForAKeyframe() {
        var backlog = DecodeBacklog(limit: 1)
        _ = backlog.admit(isKeyframe: true)
        _ = backlog.admit(isKeyframe: false) // overflow, now waiting
        backlog.finished()
        backlog.reset()
        XCTAssertEqual(backlog.admit(isKeyframe: false), .decode)
    }
}
