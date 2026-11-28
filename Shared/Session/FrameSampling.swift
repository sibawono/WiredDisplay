/// Which frames get a latency line in the logs. Host and iPad apply it to the same wire
/// timestamp, so the sampled frames match on both sides.
public enum FrameSampling {
    /// One frame in `every`, about one line per 5 s at 60 Hz.
    public static let every: UInt64 = 300

    /// Uses microseconds: on Apple silicon the clock moves in 41.67 ns steps, so
    /// `nanos % 300` was true for 1 frame in 36 (audit LOG-01).
    public static func isSampled(_ timestampNanos: UInt64) -> Bool {
        (timestampNanos / 1_000) % every == 0
    }
}
