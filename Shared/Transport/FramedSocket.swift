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
public final class FramedSocket: @unchecked Sendable {
    private let fd: Int32
    private let condition = NSCondition() // guards scheduler, framer, closed
    private var scheduler: SendScheduler
    private var framer: SessionFramer
    private var closed = false
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
        scheduler = SendScheduler(maxVideoFrames: maxVideoFrames)
        framer = SessionFramer(sessionID: sessionID, channel: channel,
                               clock: { clock_gettime_nsec_np(CLOCK_UPTIME_RAW) })
        self.channel = channel
        self.onVerified = onVerified
        self.onFrame = onFrame
        self.onClose = onClose
    }

    deinit { Darwin.close(fd) }

    public func start() {
        if let channel { send(.control, payload: channel.authHelloPayload) }
        Thread.detachNewThread { [self] in readLoop() }
        Thread.detachNewThread { [self] in writeLoop() }
    }

    public var isClosed: Bool { condition.withLock { closed } }

    /// Control or input. Returns false if the socket is closed or framing failed.
    @discardableResult
    public func send(_ stream: StreamType, payload: [UInt8]) -> Bool {
        condition.withLock {
            guard !closed, let wire = try? framer.frame(stream, payload: payload) else { return false }
            scheduler.enqueue(urgent: wire, stream: stream)
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

    public func sendVideo(_ payload: [UInt8], isKeyframe: Bool) -> VideoResult {
        condition.withLock {
            guard !closed else { return .closed }
            guard let wire = try? framer.frame(.video, payload: payload, keyframe: isKeyframe) else {
                return .needKeyframe // e.g. over the 8 MiB cap: later P-frames would be orphans
            }
            let needKeyframe = scheduler.enqueue(video: wire, isKeyframe: isKeyframe)
            condition.signal()
            return needKeyframe ? .needKeyframe : .queued
        }
    }

    public var droppedVideoFrames: Int { condition.withLock { scheduler.stats.videoDropped } }

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
            let (count, code): (Int, Int32) = buffer.withUnsafeMutableBytes { raw in
                let n = Darwin.read(fd, raw.baseAddress!, raw.count)
                return (n, errno)
            }
            if count == 0 { return close("peer closed the connection") }
            if count < 0 {
                if code == EAGAIN || code == EWOULDBLOCK || code == EINTR { continue }
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

    private func writeLoop() {
        while true {
            condition.lock()
            while !closed && scheduler.isEmpty { condition.wait() }
            if closed { condition.unlock(); return }
            let wire = scheduler.next()
            condition.unlock()
            guard let wire else { continue }
            if let failure = writeAll(wire) { return close(failure) }
        }
    }

    private func writeAll(_ bytes: [UInt8]) -> String? {
        let deadline = Date().addingTimeInterval(Self.writeDeadline)
        var sent = 0
        while sent < bytes.count {
            if isClosed { return nil }
            let remaining = deadline.timeIntervalSinceNow
            if remaining <= 0 { return "write timed out (peer not reading)" }
            var descriptor = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
            let ready = poll(&descriptor, 1, Int32(min(remaining * 1000, 250)))
            if ready == 0 { continue }
            if ready < 0 {
                if errno == EINTR { continue }
                return "poll failed: errno \(errno)"
            }
            let (count, code): (Int, Int32) = bytes.withUnsafeBytes { raw in
                let n = Darwin.write(fd, raw.baseAddress! + sent, bytes.count - sent)
                return (n, errno)
            }
            if count > 0 { sent += count; continue }
            if code == EAGAIN || code == EWOULDBLOCK || code == EINTR { continue }
            return "write failed: errno \(code)"
        }
        return nil
    }
}
