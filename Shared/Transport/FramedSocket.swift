import Darwin
import Foundation
import WDProtocol
import WDSession

/// Full-duplex framed transport over a connected stream socket (the usbmuxd
/// tunnel on the Mac; a socketpair in tests).
///
/// - Reader thread: poll + read, bounded `FrameParser`, peer session/sequence
///   validation, then `onFrame(frame, self)`. Malformed input closes.
/// - Writer thread: drains a `SendScheduler` (control > input > video, stale
///   video dropped) with a per-frame write deadline.
/// - Frames are numbered and queued under ONE lock, so sequence order equals
///   wire order even with several sending threads (review finding 11).
/// - `close` is idempotent; `onClose` fires exactly once; frames are not
///   delivered once closed. The descriptor is closed in deinit, after both
///   threads (which retain self) have exited.
public final class FramedSocket: FramedTransport, @unchecked Sendable {
    public let transportKind: ActiveTransportKind = .usb
    private let fd: Int32
    private let condition = NSCondition() // guards scheduler, closed
    private var scheduler: PendingSendScheduler
    private var framer: SessionFramer // owned exclusively by writeLoop()
    private var closed = false
    private var started = false
    private let onFrame: @Sendable (Frame, FramedSocket) -> Void
    private let onClose: @Sendable (String) -> Void
    private let channel: SecureChannel?
    private let onVerified: @Sendable (SecureChannel.Peer, FramedSocket) -> Void
    public static let writeDeadline: TimeInterval = 5

    /// Takes ownership of `descriptor` (must be connected; set non-blocking
    /// and SO_NOSIGPIPE by the caller).
    /// With a `channel` (D-023) the socket sends our authHello first, answers
    /// the peer's with our proof, reports `onVerified` once the peer proved its
    /// identity, and delivers only decrypted frames to `onFrame`.
    public init(descriptor: Int32, sessionID: UInt64, maxVideoFrames: Int = 6, channel: SecureChannel? = nil,
                onVerified: @escaping @Sendable (SecureChannel.Peer, FramedSocket) -> Void = { _, _ in },
                onFrame: @escaping @Sendable (Frame, FramedSocket) -> Void,
                onClose: @escaping @Sendable (String) -> Void) {
        fd = descriptor
        scheduler = PendingSendScheduler(maxVideoFrames: maxVideoFrames)
        framer = SessionFramer(sessionID: sessionID, channel: channel,
                               clock: { clock_gettime_nsec_np(CLOCK_UPTIME_RAW) })
        self.channel = channel
        self.onVerified = onVerified
        self.onFrame = onFrame
        self.onClose = onClose
    }

    deinit { Darwin.close(fd) }

    public func start() {
        let shouldStart = condition.withLock {
            guard !started, !closed else { return false }
            started = true
            if let channel {
                scheduler.enqueue(urgent: PendingFrame(stream: .control, payload: channel.authHelloPayload))
            }
            return true
        }
        guard shouldStart else { return }
        Thread.detachNewThread { [self] in readLoop() }
        Thread.detachNewThread { [self] in writeLoop() }
    }

    public var isClosed: Bool { condition.withLock { closed } }

    /// Control or input. Returns false if the socket is closed or payload exceeds stream cap.
    @discardableResult
    public func send(_ stream: StreamType, payload: [UInt8]) -> Bool {
        let cap = Int(stream.maxPayloadLength) - (channel != nil ? SecureChannel.tagLength : 0)
        guard payload.count <= cap else { return false }
        return condition.withLock {
            guard !closed else { return false }
            scheduler.enqueue(urgent: PendingFrame(stream: stream, payload: payload))
            condition.signal()
            return true
        }
    }

    public enum VideoResult: Equatable, Sendable {
        case queued
        /// Video was dropped; the encoder must produce a keyframe.
        case needKeyframe
        case closed
    }

    public func sendVideo(_ payload: [UInt8], isKeyframe: Bool, timestampNanos: UInt64? = nil) -> VideoResult {
        let cap = Int(StreamType.video.maxPayloadLength) - (channel != nil ? SecureChannel.tagLength : 0)
        return condition.withLock {
            guard !closed else { return .closed }
            guard payload.count <= cap else {
                scheduler.discardVideoReference()
                return .needKeyframe
            }
            let needKeyframe = scheduler.enqueue(video: PendingFrame(stream: .video, payload: payload,
                                                                     isKeyframe: isKeyframe, timestampNanos: timestampNanos))
            condition.signal()
            return needKeyframe ? .needKeyframe : .queued
        }
    }

    public var droppedVideoFrames: Int { condition.withLock { scheduler.stats.videoDropped } }
    public var congestionDroppedVideoFrames: Int { condition.withLock { scheduler.stats.videoCongestionDropped } }
    public var queuedVideoFrames: Int { condition.withLock { scheduler.queuedVideoFrames } }

    public func close(_ reason: String) {
        let first = condition.withLock { () -> Bool in
            guard !closed else { return false }
            closed = true
            condition.broadcast()
            return true
        }
        guard first else { return }
        shutdown(fd, SHUT_RDWR) // wakes the reader's poll
        onClose(reason)
    }

    private func readLoop() {
        pthread_set_qos_class_self_np(QOS_CLASS_USER_INTERACTIVE, 0)
        var parser = FrameParser()
        var validator: SequenceValidator?
        var buffer = [UInt8](repeating: 0, count: 256 * 1024)
        while !isClosed {
            var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let ready = poll(&descriptor, 1, 250)
            if ready == 0 { continue }
            if ready < 0 {
                if errno == EINTR { continue }
                return close("poll failed: errno \(errno)")
            }
            // Drain all immediately readable bytes before returning to poll().
            while !isClosed {
                let (count, code): (Int, Int32) = buffer.withUnsafeMutableBytes { raw in
                    let n = Darwin.read(fd, raw.baseAddress!, raw.count)
                    return (n, errno)
                }
                if count == 0 { return close("peer closed the connection") }
                if count < 0 {
                    if code == EAGAIN || code == EWOULDBLOCK { break }
                    if code == EINTR { continue }
                    return close("read failed: errno \(code)")
                }
                do {
                    try parser.append(buffer[0..<count])
                    while let frame = try parser.next() {
                        if validator == nil {
                            // The first frame must be the peer's control hello; it
                            // fixes the peer session ID for this connection.
                            guard frame.header.stream == .control else { return close("first frame was not control") }
                            validator = SequenceValidator(sessionID: frame.header.sessionID)
                        }
                        try validator?.accept(frame.header)
                        if isClosed { return }
                        guard let channel else {
                            onFrame(frame, self)
                            continue
                        }
                        switch try channel.receive(frame) {
                        case .none: break
                        case .sendProof(let proof):
                            guard send(.control, payload: proof) else { return close("could not send auth proof") }
                        case .verified(let peer): onVerified(peer, self)
                        case .message(let opened): onFrame(opened, self)
                        }
                    }
                } catch {
                    return close("protocol error: \(error)")
                }
            }
        }
    }

    private func writeLoop() {
        pthread_set_qos_class_self_np(QOS_CLASS_USER_INTERACTIVE, 0)
        while true {
            condition.lock()
            while !closed && scheduler.isEmpty { condition.wait() }
            if closed { condition.unlock(); return }
            let pending = scheduler.next()
            condition.unlock()
            guard let pending else { continue }
            // Encrypt outside `condition` so AES-GCM never blocks audio/cursor/capture
            // and dropped frames are never encrypted.
            guard let wire = try? framer.frame(pending.stream, payload: pending.payload,
                                               keyframe: pending.isKeyframe,
                                               timestampNanos: pending.timestampNanos) else { continue }
            if let failure = writeAll(wire) { return close(failure) }
        }
    }

    private func writeAll(_ bytes: [UInt8]) -> String? {
        let deadlineNanos = clock_gettime_nsec_np(CLOCK_UPTIME_RAW) &+ UInt64(Self.writeDeadline * 1_000_000_000)
        var sent = 0
        while sent < bytes.count {
            if isClosed { return nil }
            // Optimistic non-blocking write first; only poll(POLLOUT) on EAGAIN.
            let (count, code): (Int, Int32) = bytes.withUnsafeBytes { raw in
                let n = Darwin.write(fd, raw.baseAddress! + sent, bytes.count - sent)
                return (n, errno)
            }
            if count > 0 { sent += count; continue }
            if code == EINTR { continue }
            if code != EAGAIN && code != EWOULDBLOCK {
                return "write failed: errno \(code)"
            }
            let now = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
            if now >= deadlineNanos { return "write timed out (peer not reading)" }
            let remainingMs = Int32(min((deadlineNanos - now) / 1_000_000, 250))
            var descriptor = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
            let ready = poll(&descriptor, 1, max(remainingMs, 1))
            if ready < 0 && errno != EINTR {
                return "poll failed: errno \(errno)"
            }
        }
        return nil
    }
}
