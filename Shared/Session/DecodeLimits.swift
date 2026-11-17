/// Video formats a particular iPad turned out not to decode (D-031). The host
/// learns them when the iPad reports `.decodeFailed`, remembers them per iPad,
/// and steps the stream down: first away from 4:4:4, then to 8-bit.
public struct DecodeLimits: OptionSet, Sendable, Hashable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    /// No HEVC 4:4:4 (Ultra, High Color, and the still lane of Balanced).
    public static let no444 = DecodeLimits(rawValue: 1 << 0)
    /// No 10-bit (HEVC Main 10).
    public static let no10Bit = DecodeLimits(rawValue: 1 << 1)

    /// The limit to add after a decode failure of a stream that used
    /// 4:4:4 (`uses444`) and/or 10-bit; nil when nothing is left to drop.
    public static func next(after current: DecodeLimits, uses444: Bool, tenBit: Bool) -> DecodeLimits? {
        if uses444, !current.contains(.no444) { return current.union(.no444) }
        if tenBit, !current.contains(.no10Bit) { return current.union(.no10Bit) }
        return nil
    }

    /// Short description for menus and logs.
    public var summary: String {
        switch (contains(.no444), contains(.no10Bit)) {
        case (true, true): return "4:2:0 8-bit only"
        case (true, false): return "no 4:4:4"
        case (false, true): return "8-bit only"
        case (false, false): return "none"
        }
    }
}

/// Watches the iPad's video renderer: a few failures in a short window mean
/// the format is not decodable here (not a one-off glitch). Pure, testable.
public struct DecodeFailureDetector: Sendable {
    public var threshold = 3
    public var window: Double = 10
    /// After reporting, wait this long for the host to switch before counting again.
    public var cooldown: Double = 8
    private var failures: [Double] = []
    private var lastReport: Double = -.infinity

    public init() {}

    /// Record one renderer failure at `time` (seconds); true = report it now.
    public mutating func failed(at time: Double) -> Bool {
        guard time - lastReport >= cooldown else { return false }
        failures.append(time)
        failures.removeAll { time - $0 > window }
        guard failures.count >= threshold else { return false }
        failures.removeAll()
        lastReport = time
        return true
    }

    /// The stream format changed (new config or keyframe after a switch).
    public mutating func reset() { failures.removeAll() }
}
