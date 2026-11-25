/// What the Mac is doing, as independent dimensions: a screensaver can run on a locked session,
/// and a wake event does not mean unlocked (docs/POWER_LOCK_WAKE.md).
public struct PowerState: Equatable, Sendable, CustomStringConvertible {
    public var systemAsleep = false
    public var displaysAsleep = false
    public var locked = false
    public var screensaver = false
    /// False while another user's session is in front (fast user switching).
    public var sessionActive = true

    public init(systemAsleep: Bool = false, displaysAsleep: Bool = false, locked: Bool = false,
                screensaver: Bool = false, sessionActive: Bool = true) {
        self.systemAsleep = systemAsleep
        self.displaysAsleep = displaysAsleep
        self.locked = locked
        self.screensaver = screensaver
        self.sessionActive = sessionActive
    }

    /// iPad input may reach the Mac only in an awake, unlocked, active session.
    public var allowsInput: Bool { !systemAsleep && !locked && sessionActive }

    public var description: String {
        "sleep \(systemAsleep ? "Y" : "n") displays-asleep \(displaysAsleep ? "Y" : "n") locked \(locked ? "Y" : "n") " +
            "screensaver \(screensaver ? "Y" : "n") session-active \(sessionActive ? "Y" : "n")"
    }
}
