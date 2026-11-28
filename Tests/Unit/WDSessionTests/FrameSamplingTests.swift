import XCTest
@testable import WDSession

/// LOG-01 (audit 2026-11-28): one sample in about 300 frames on Apple silicon's 41.67 ns clock.
final class FrameSamplingTests: XCTestCase {
    func testRateOnAppleSiliconClock() {
        // 24 MHz timebase: nanos = ticks * 125 / 3. 60 Hz frames are 400,000 ticks apart, plus jitter.
        var rng = SystemRandomNumberGenerator()
        var ticks: UInt64 = 1_000_000_007
        var newHits = 0, oldHits = 0
        let frames = 600_000
        for _ in 0..<frames {
            ticks += 400_000 + UInt64.random(in: 0..<2_000, using: &rng)
            let nanos = ticks * 125 / 3
            if FrameSampling.isSampled(nanos) { newHits += 1 }
            if nanos % 300 == 0 { oldHits += 1 }
        }
        let newRate = Double(frames) / Double(newHits)
        XCTAssertEqual(newRate, 300, accuracy: 30, "about 1 in 300")
        XCTAssertLessThan(Double(frames) / Double(oldHits), 60, "the old test sampled far more often")
    }
}
