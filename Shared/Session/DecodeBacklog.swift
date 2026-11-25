/// At most `limit` frames wait for the iPad's decoder, so a slow decoder skips
/// ahead instead of falling seconds behind. Past the limit, frames are dropped up to the next keyframe.
public struct DecodeBacklog: Sendable, Equatable {
    public enum Decision: Sendable, Equatable {
        case decode
        /// A keyframe that arrived while behind: older queued frames are skipped.
        case decodeSkippingQueued
        /// Drop it and ask for a keyframe; `overflow` marks the first drop of a stall.
        case drop(overflow: Bool)
    }

    public let limit: Int
    /// Admitted and not yet finished, skipped frames included.
    public private(set) var queued = 0
    private var waitingForKeyframe = false

    public init(limit: Int = 3) {
        precondition(limit >= 1)
        self.limit = limit
    }

    public mutating func admit(isKeyframe: Bool) -> Decision {
        if isKeyframe {
            let behind = queued >= limit || waitingForKeyframe
            waitingForKeyframe = false
            queued += 1
            return behind ? .decodeSkippingQueued : .decode
        }
        if waitingForKeyframe { return .drop(overflow: false) }
        if queued >= limit {
            waitingForKeyframe = true
            return .drop(overflow: true)
        }
        queued += 1
        return .decode
    }

    /// One admitted frame left the queue (decoded, failed or skipped).
    public mutating func finished() { queued = max(0, queued - 1) }

    /// The renderer was flushed: the next frame it gets is a keyframe anyway.
    public mutating func reset() { waitingForKeyframe = false }
}
