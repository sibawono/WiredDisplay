import WDSession

/// What happens to one iPad input event in the current power state.
public enum InputGate {
    public enum Decision: Equatable, Sendable {
        /// Inject it.
        case inject
        /// Locked, screensaver or displays asleep: only a pointer move passes, to wake or dismiss.
        case moveOnly
        /// A tap, click, key or scroll start: wake the displays, drop the event itself.
        case wakeAndDrop
        /// Nothing reaches the Mac (asleep, another user's session, or a release while locked).
        case drop
    }

    public static func decision(for event: InputEvent, state: PowerState) -> Decision {
        if state.allowsInput { return .inject }
        guard !state.systemAsleep, state.sessionActive else { return .drop }
        switch event {
        case .pointer(.move, _, _, _), .stylus(.move, _, _, _): return .moveOnly
        case .pointer(.down, _, _, _), .stylus(.down, _, _, _), .key(_, true), .scroll, .gestureScroll(_, _, .began, _): return .wakeAndDrop
        default: return .drop
        }
    }
}
