/// Tells a one-off failure from a loop. A recovery that fails again within
/// `window` seconds of succeeding extends the streak; a failure after the
/// thing ran longer starts over at 0.
///
/// Used for ScreenCaptureKit stops: a display sleep stops the capture once
/// per sleep (streak 0, recover at once), but a capture that is restarted and
/// stops again right away (for example after Screen Recording permission was
/// withdrawn) would otherwise restart without end.
public struct QuickFailureCounter: Sendable {
    public let window: Double
    private var lastRecovery: Double?
    public private(set) var streak = 0

    public init(window: Double) { self.window = window }

    /// The recovery succeeded at `time` (seconds, any monotonic clock).
    public mutating func recovered(at time: Double) { lastRecovery = time }

    /// A failure at `time`. Returns the streak: 0 for a failure after a run
    /// of at least `window`, n for the n-th failure in a row that came back
    /// sooner.
    @discardableResult
    public mutating func failed(at time: Double) -> Int {
        if let lastRecovery, time - lastRecovery < window { streak += 1 } else { streak = 0 }
        lastRecovery = nil
        return streak
    }

    public mutating func reset() {
        lastRecovery = nil
        streak = 0
    }
}
