import Foundation
import os

/// Counts events and the gaps between them over a window, for diagnosing
/// stutter (frames per second, worst gap, gaps above one 60 Hz frame).
/// Thread-safe; cheap enough for per-frame use.
public final class FrameRateMeter: @unchecked Sendable {
    public struct Report: Sendable, CustomStringConvertible {
        public var fps: Double
        public var maxGapMs: Double
        public var p95GapMs: Double
        public var gapsOver25Ms: Int
        public var averageBytes: Int

        public var description: String {
            String(format: "%.1f fps, gap p95 %.1f ms max %.1f ms, %d gaps >25 ms, avg %d KB",
                   fps, p95GapMs, maxGapMs, gapsOver25Ms, averageBytes / 1024)
        }
    }

    private struct State {
        var windowStart: UInt64 = 0
        var last: UInt64 = 0
        var gaps: [Double] = []
        var count = 0
        var bytes = 0
    }

    private let state = OSAllocatedUnfairLock(initialState: State())
    public let window: Double

    public init(windowSeconds: Double = 5) { window = windowSeconds }

    /// Returns a report when a window completes, otherwise nil.
    public func tick(bytes: Int = 0, now: UInt64 = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)) -> Report? {
        state.withLock { s -> Report? in
            if s.windowStart == 0 { s.windowStart = now }
            if s.last != 0 { s.gaps.append(Double(now &- s.last) / 1_000_000) }
            s.last = now
            s.count += 1
            s.bytes += bytes
            let elapsed = Double(now &- s.windowStart) / 1_000_000_000
            guard elapsed >= window, s.count > 1 else { return nil }
            let sorted = s.gaps.sorted()
            let report = Report(fps: Double(s.count - 1) / elapsed,
                                maxGapMs: sorted.last ?? 0,
                                p95GapMs: sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.95))],
                                gapsOver25Ms: sorted.filter { $0 > 25 }.count,
                                averageBytes: s.bytes / s.count)
            s = State(windowStart: now, last: now)
            return report
        }
    }
}
