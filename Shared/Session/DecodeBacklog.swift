/// Bounds how many frames wait for the iPad's decoder (GitHub issue #1).
///
/// The decoder works through frames in order. If it is slower than the
/// stream (for example HEVC 4:4:4 10-bit on an iPad whose hardware decoder
/// does not take it), an unbounded queue grows without end: the picture falls
/// seconds behind the Mac and never catches up. Here at most `limit` frames
/// wait. Beyond that, frames are dropped until the next keyframe, because a
/// P-frame whose reference was dropped would only decode into garbage. The
/// caller asks the Mac for a keyframe, and the keyframe also discards
/// whatever older frames are still queued, so the picture jumps to the
/// present. Pure logic, unit-tested.
public struct DecodeBacklog: Sendable, Equatable {
    public enum Decision: Sendable, Equatable {
        /// Decode it.
        case decode
        /// Decode it, and skip the older frames still queued (a keyframe
        /// that arrived while the decoder was behind).
        case decodeSkippingQueued
        /// Drop it and ask for a keyframe. `overflow` is true for the frame
        /// that found the queue full (one event per stall, for statistics
        /// and the format step-down).
        case drop(overflow: Bool)
    }

    public let limit: Int
    /// Frames admitted and not yet finished (skipped ones included: they
    /// finish too, just without decoding).
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
