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
        /// Video drops caused by backpressure/overflow (excludes keyframe supersedes).
        public var videoCongestionDropped = 0
        public var urgentDropped = 0
        public var audioDropped = 0
    }

    public let maxVideoFrames: Int
    public let maxUrgentFrames: Int
    private var control = Deque<[UInt8]>()
    private var input = Deque<[UInt8]>()
    private var audio = Deque<[UInt8]>()
    private var video = Deque<[UInt8]>()
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

    /// True (and counted as dropped) when a non-keyframe would be discarded
    /// while waiting for a keyframe; callers can skip encrypting it.
    public mutating func dropVideoIfWaiting(isKeyframe: Bool) -> Bool {
        guard waitingForKeyframe && !isKeyframe else { return false }
        stats.videoDropped += 1
        stats.videoCongestionDropped += 1
        return true
    }

    /// Returns true when the caller must force the encoder to emit a keyframe.
    @discardableResult
    public mutating func enqueue(video wire: [UInt8], isKeyframe: Bool) -> Bool {
        if dropVideoIfWaiting(isKeyframe: isKeyframe) {
            return false // already asked for one
        }
        if isKeyframe {
            // A keyframe makes everything queued before it pointless (not a congestion drop).
            stats.videoDropped += video.count
            video.removeAll()
            waitingForKeyframe = false
            video.append(wire)
            return false
        }
        if video.count >= maxVideoFrames {
            let dropped = video.count + 1
            stats.videoDropped += dropped
            stats.videoCongestionDropped += dropped
            video.removeAll()
            waitingForKeyframe = true
            return true
        }
        video.append(wire)
        return false
    }

    public mutating func next() -> [UInt8]? {
        if let item = control.popFirst() { return item }
        if let item = input.popFirst() { return item }
        if let item = audio.popFirst() { return item }
        if let item = video.popFirst() { return item }
        return nil
    }

    private static func push(_ queue: inout Deque<[UInt8]>, _ wire: [UInt8], cap: Int, dropped: inout Int) {
        if queue.count >= cap {
            _ = queue.popFirst()
            dropped += 1
        }
        queue.append(wire)
    }
}

/// Unencrypted frame queued for serialization on the transport writer thread.
/// Deferring AES-256-GCM encryption until dequeue keeps queue locks at nanoseconds,
/// guarantees wire order == sequence order, and avoids encrypting dropped frames.
public struct PendingFrame: Sendable {
    public let stream: StreamType
    public let payload: [UInt8]
    public let isKeyframe: Bool
    public let timestampNanos: UInt64?

    public init(stream: StreamType, payload: [UInt8], isKeyframe: Bool = false, timestampNanos: UInt64? = nil) {
        self.stream = stream
        self.payload = payload
        self.isKeyframe = isKeyframe
        self.timestampNanos = timestampNanos
    }
}

/// Priority scheduler for unencrypted `PendingFrame`s, with `.cursor` coalescing
/// and separate congestion-drop accounting for ABR.
public struct PendingSendScheduler: Sendable {
    public let maxVideoFrames: Int
    public let maxUrgentFrames: Int
    private var control = Deque<PendingFrame>()
    private var input = Deque<PendingFrame>()
    private var audio = Deque<PendingFrame>()
    private var video = Deque<PendingFrame>()
    /// Latest coalesced cursor position (control tag 13); always supersedes older cursor moves.
    private var pendingCursor: PendingFrame?
    private var waitingForKeyframe = false
    public private(set) var stats = SendScheduler.Stats()

    public init(maxVideoFrames: Int = 3, maxUrgentFrames: Int = 512) {
        precondition(maxVideoFrames >= 1 && maxUrgentFrames >= 1)
        self.maxVideoFrames = maxVideoFrames
        self.maxUrgentFrames = maxUrgentFrames
    }

    public var isEmpty: Bool {
        control.isEmpty && pendingCursor == nil && input.isEmpty && audio.isEmpty && video.isEmpty
    }
    public var queuedVideoFrames: Int { video.count }

    public mutating func enqueue(urgent frame: PendingFrame) {
        switch frame.stream {
        case .control:
            // ControlTag.cursor == 13: keep only the newest cursor coordinates.
            if frame.payload.first == 13 {
                pendingCursor = frame
                return
            }
            Self.push(&control, frame, cap: maxUrgentFrames, dropped: &stats.urgentDropped)
        case .input:
            Self.push(&input, frame, cap: maxUrgentFrames, dropped: &stats.urgentDropped)
        case .speaker, .microphone, .camera, .video:
            Self.push(&audio, frame, cap: SendScheduler.maxAudioPackets, dropped: &stats.audioDropped)
        }
    }

    /// A frame rejected before queueing can still be a reference for later frames.
    public mutating func discardVideoReference() {
        stats.videoDropped += video.count + 1
        video.removeAll()
        waitingForKeyframe = true
    }

    @discardableResult
    public mutating func enqueue(video frame: PendingFrame) -> Bool {
        if waitingForKeyframe && !frame.isKeyframe {
            stats.videoDropped += 1
            stats.videoCongestionDropped += 1
            return false
        }
        if frame.isKeyframe {
            stats.videoDropped += video.count
            video.removeAll()
            waitingForKeyframe = false
            video.append(frame)
            return false
        }
        if video.count >= maxVideoFrames {
            let dropped = video.count + 1
            stats.videoDropped += dropped
            stats.videoCongestionDropped += dropped
            video.removeAll()
            waitingForKeyframe = true
            return true
        }
        video.append(frame)
        return false
    }

    public mutating func next() -> PendingFrame? {
        if let item = control.popFirst() { return item }
        if let cursor = pendingCursor { pendingCursor = nil; return cursor }
        if let item = input.popFirst() { return item }
        if let item = audio.popFirst() { return item }
        if let item = video.popFirst() { return item }
        return nil
    }

    private static func push(_ queue: inout Deque<PendingFrame>, _ item: PendingFrame, cap: Int, dropped: inout Int) {
        if queue.count >= cap {
            _ = queue.popFirst()
            dropped += 1
        }
        queue.append(item)
    }
}

/// Amortized O(1) FIFO queue avoiding `Array.removeFirst()` O(N) shifts.
private struct Deque<Element: Sendable>: Sendable {
    private var storage: [Element?] = []
    private var head = 0

    var isEmpty: Bool { head >= storage.count }
    var count: Int { storage.count - head }

    mutating func append(_ element: Element) {
        storage.append(element)
    }

    mutating func popFirst() -> Element? {
        guard head < storage.count else { return nil }
        let element = storage[head]
        storage[head] = nil
        head += 1
        if head == storage.count {
            storage.removeAll(keepingCapacity: true)
            head = 0
        } else if head >= 64 && head * 2 >= storage.count {
            storage.removeFirst(head)
            head = 0
        }
        return element
    }

    mutating func removeAll() {
        storage.removeAll(keepingCapacity: true)
        head = 0
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

    public mutating func frame(_ stream: StreamType, payload: [UInt8], keyframe: Bool = false, timestampNanos: UInt64? = nil) throws -> [UInt8] {
        let sequence = sequences[stream, default: 0]
        sequences[stream] = sequence + 1
        if let channel {
            return try channel.wire(stream: stream, keyframe: keyframe, sessionID: sessionID, sequence: sequence,
                                    timestampNanos: timestampNanos ?? clock(), payload: payload)
        }
        return try Frame(stream: stream, flags: keyframe ? [.keyframe] : [], sessionID: sessionID,
                         sequence: sequence, timestampNanos: timestampNanos ?? clock(), payload: payload).encoded()
    }
}
