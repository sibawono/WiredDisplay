import WDProtocol

/// Decides what goes on the wire next. Pure logic, no I/O, so it is unit-tested.
///
/// - Order: control > input > real-time audio > video. A touch must never wait
///   behind a 4 MB keyframe, and audio must not either (spec §5, §7).
/// - Video is bounded. When the link cannot keep up, queued video is dropped
///   and nothing more is accepted until the next keyframe, because a P-frame
///   whose reference was dropped would only decode into garbage. The caller is
///   told to force a keyframe.
/// - Control/input are bounded too; on overflow the oldest are dropped and
///   counted (a peer that stops reading must not exhaust memory).
public struct SendScheduler: Sendable {
    public struct Stats: Sendable, Equatable {
        public var videoDropped = 0
        public var urgentDropped = 0
        public var audioDropped = 0
    }

    public let maxVideoFrames: Int
    public let maxUrgentFrames: Int
    private var control: [[UInt8]] = []
    private var input: [[UInt8]] = []
    private var audio: [[UInt8]] = []
    private var video: [[UInt8]] = []
    /// Audio packets are ~10–100 ms each; 64 queued is seconds behind real time.
    public static let maxAudioPackets = 64
    private var waitingForKeyframe = false
    public private(set) var stats = Stats()

    public init(maxVideoFrames: Int = 3, maxUrgentFrames: Int = 512) {
        precondition(maxVideoFrames >= 1 && maxUrgentFrames >= 1)
        self.maxVideoFrames = maxVideoFrames
        self.maxUrgentFrames = maxUrgentFrames
    }

    public var isEmpty: Bool { control.isEmpty && input.isEmpty && audio.isEmpty && video.isEmpty }
    public var queuedVideoFrames: Int { video.count }

    /// Control, input and audio (any non-video stream). Never traps: an earlier
    /// `precondition` here crashed the host on the first audio packet (BUG-027).
    public mutating func enqueue(urgent wire: [UInt8], stream: StreamType) {
        switch stream {
        case .control: Self.push(&control, wire, cap: maxUrgentFrames, dropped: &stats.urgentDropped)
        case .input: Self.push(&input, wire, cap: maxUrgentFrames, dropped: &stats.urgentDropped)
        case .speaker, .microphone, .camera, .video:
            // Late audio is worse than no audio: drop the oldest when behind.
            Self.push(&audio, wire, cap: Self.maxAudioPackets, dropped: &stats.audioDropped)
        }
    }

    /// Returns true when the caller must force the encoder to emit a keyframe.
    @discardableResult
    public mutating func enqueue(video wire: [UInt8], isKeyframe: Bool) -> Bool {
        if waitingForKeyframe && !isKeyframe {
            stats.videoDropped += 1
            return false // already asked for one
        }
        if isKeyframe {
            // A keyframe makes everything queued before it pointless.
            stats.videoDropped += video.count
            video.removeAll(keepingCapacity: true)
            waitingForKeyframe = false
            video.append(wire)
            return false
        }
        if video.count >= maxVideoFrames {
            stats.videoDropped += video.count + 1
            video.removeAll(keepingCapacity: true)
            waitingForKeyframe = true
            return true
        }
        video.append(wire)
        return false
    }

    public mutating func next() -> [UInt8]? {
        if !control.isEmpty { return control.removeFirst() }
        if !input.isEmpty { return input.removeFirst() }
        if !audio.isEmpty { return audio.removeFirst() }
        if !video.isEmpty { return video.removeFirst() }
        return nil
    }

    private static func push(_ queue: inout [[UInt8]], _ wire: [UInt8], cap: Int, dropped: inout Int) {
        if queue.count >= cap {
            queue.removeFirst()
            dropped += 1
        }
        queue.append(wire)
    }
}

/// Builds wire frames with per-stream sequence numbers and monotonic
/// timestamps for one session.
public struct SessionFramer: Sendable {
    public let sessionID: UInt64
    private var sequences: [StreamType: UInt64] = [:]
    private let clock: @Sendable () -> UInt64
    /// When set, every frame goes through the channel (D-023): in the clear
    /// only for our authHello, encrypted afterwards.
    public let channel: SecureChannel?

    public init(sessionID: UInt64, channel: SecureChannel? = nil, clock: @escaping @Sendable () -> UInt64) {
        self.sessionID = sessionID
        self.channel = channel
        self.clock = clock
    }

    public mutating func frame(_ stream: StreamType, payload: [UInt8], keyframe: Bool = false) throws -> [UInt8] {
        let sequence = sequences[stream, default: 0]
        sequences[stream] = sequence + 1
        if let channel {
            return try channel.wire(stream: stream, keyframe: keyframe, sessionID: sessionID, sequence: sequence,
                                    timestampNanos: clock(), payload: payload)
        }
        return try Frame(stream: stream, flags: keyframe ? [.keyframe] : [], sessionID: sessionID,
                         sequence: sequence, timestampNanos: clock(), payload: payload).encoded()
    }
}
