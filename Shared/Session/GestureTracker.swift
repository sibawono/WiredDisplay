/// Which trackpad gestures the Mac has seen begin but not end.
///
/// The injector posts scroll, magnify and rotate events with phases. If the
/// stream of events stops mid-gesture (input switched off, the Mac locks, the
/// iPad disconnects), the Mac never sees "ended" and an app can stay in the
/// middle of a gesture: a scroll view keeps its rubber band, a pinch stays
/// half applied. `releaseAll` asks this tracker what is still open and
/// cancels it.
public struct GestureTracker: Sendable, Equatable {
    public enum Kind: Sendable, Equatable, CaseIterable { case scroll, momentum, magnify, rotate }

    private var open: Set<Kind> = []

    public init() {}

    public var openGestures: [Kind] { Kind.allCases.filter(open.contains) }

    public mutating func note(_ kind: Kind, phase: ScrollPhase) {
        switch phase {
        case .began: open.insert(kind)
        case .ended, .cancelled: open.remove(kind)
        case .changed, .none: break
        }
    }

    public mutating func note(momentum: MomentumPhase) {
        switch momentum {
        case .begin: open.insert(.momentum)
        case .end: open.remove(.momentum)
        case .continue, .none: break
        }
    }

    /// Returns what was open and forgets it (the caller posts the ends).
    public mutating func takeOpen() -> [Kind] {
        defer { open.removeAll() }
        return openGestures
    }
}
