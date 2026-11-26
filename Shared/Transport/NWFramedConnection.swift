import Foundation
import Network
import WDProtocol
import WDSession

/// Full-duplex framed transport over Apple Network.framework (`NWConnection`) for local Wi-Fi.
/// Uses the same FrameParser, SequenceValidator, SecureChannel (AES-256-GCM), and SendScheduler
/// priority queue as `FramedSocket`, with TCP_NODELAY, no proxies, no TFO, and interactiveVideo QoS.
public final class NWFramedConnection: FramedTransport, @unchecked Sendable {
    private let connection: NWConnection
    private let ioQueue: DispatchQueue
    private let lock = NSLock()
    private var scheduler: SendScheduler
    private var framer: SessionFramer
    private var parser = FrameParser()
    private var validator: SequenceValidator?
    private var closed = false
    private var started = false
    private var isReady = false
    private var sending = false
    private var dialTimer: DispatchSourceTimer?

    private let channel: SecureChannel?
    private let onVerified: @Sendable (SecureChannel.Peer, NWFramedConnection) -> Void
    private let onFrame: @Sendable (Frame, NWFramedConnection) -> Void
    private let onClose: @Sendable (String) -> Void
    public let transportKind: ActiveTransportKind

    public static func tcpParameters() -> NWParameters {
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        // TCP Fast Open causes .preparing hangs on hotspots and middleboxes.
        tcp.enableFastOpen = false
        let params = NWParameters(tls: nil, tcp: tcp)
        params.allowLocalEndpointReuse = true
        // Bypass local proxy apps (e.g. Clash/Surge) that hijack LAN Bonjour connections.
        params.preferNoProxies = true
        params.serviceClass = .interactiveVideo
        return params
    }

    public convenience init(endpoint: NWEndpoint, sessionID: UInt64, maxVideoFrames: Int = 4,
                            channel: SecureChannel? = nil, transportKind: ActiveTransportKind = .wifi,
                            onVerified: @escaping @Sendable (SecureChannel.Peer, NWFramedConnection) -> Void = { _, _ in },
                            onFrame: @escaping @Sendable (Frame, NWFramedConnection) -> Void,
                            onClose: @escaping @Sendable (String) -> Void) {
        let conn = NWConnection(to: endpoint, using: Self.tcpParameters())
        self.init(connection: conn, sessionID: sessionID, maxVideoFrames: maxVideoFrames,
                  channel: channel, transportKind: transportKind,
                  onVerified: onVerified, onFrame: onFrame, onClose: onClose)
    }

    public init(connection: NWConnection, sessionID: UInt64, maxVideoFrames: Int = 4,
                channel: SecureChannel? = nil, transportKind: ActiveTransportKind = .wifi,
                onVerified: @escaping @Sendable (SecureChannel.Peer, NWFramedConnection) -> Void = { _, _ in },
                onFrame: @escaping @Sendable (Frame, NWFramedConnection) -> Void,
                onClose: @escaping @Sendable (String) -> Void) {
        self.connection = connection
        self.ioQueue = DispatchQueue(label: "wireddisplay.nw.transport", qos: .userInteractive)
        self.scheduler = SendScheduler(maxVideoFrames: maxVideoFrames)
        self.framer = SessionFramer(sessionID: sessionID, channel: channel,
                                    clock: { clock_gettime_nsec_np(CLOCK_UPTIME_RAW) })
        self.channel = channel
        self.transportKind = transportKind
        self.onVerified = onVerified
        self.onFrame = onFrame
        self.onClose = onClose
    }

    public var isClosed: Bool { lock.withLock { closed } }
    public var droppedVideoFrames: Int { lock.withLock { scheduler.stats.videoDropped } }

    public func start() {
        let timer = DispatchSource.makeTimerSource(queue: ioQueue)
        timer.schedule(deadline: .now() + TransportConstants.wifiDialTimeout)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            let stillConnecting = self.lock.withLock { !self.isReady && !self.closed }
            if stillConnecting {
                self.close("Wi-Fi dial timed out after \(Int(TransportConstants.wifiDialTimeout)) s")
            }
        }

        let shouldStart = lock.withLock { () -> Bool in
            guard !started, !closed else { return false }
            started = true
            dialTimer = timer
            // Queue authHello first so it always takes seq 0 before any application frame.
            if let channel, let wire = try? framer.frame(.control, payload: channel.authHelloPayload) {
                scheduler.enqueue(urgent: wire, stream: .control)
            }
            return true
        }
        guard shouldStart else {
            timer.cancel()
            return
        }
        timer.resume()

        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                let shouldProceed = self.lock.withLock { () -> Bool in
                    guard !self.closed else { return false }
                    self.isReady = true
                    self.dialTimer?.cancel()
                    self.dialTimer = nil
                    return true
                }
                guard shouldProceed else { return }
                self.receiveNext()
                self.drainSendQueue()
            case .failed(let error):
                self.close("NWConnection failed: \(error)")
            case .waiting(let error):
                if case .posix(let code) = error, code == .ECONNREFUSED {
                    self.close("peer refused connection")
                }
            case .cancelled:
                self.close("NWConnection cancelled")
            default:
                break
            }
        }
        if !isClosed {
            connection.start(queue: ioQueue)
        }
    }

    @discardableResult
    public func send(_ stream: StreamType, payload: [UInt8]) -> Bool {
        let (enqueued, triggerDrain): (Bool, Bool) = lock.withLock {
            guard !closed, let wire = try? framer.frame(stream, payload: payload) else { return (false, false) }
            scheduler.enqueue(urgent: wire, stream: stream)
            return (true, isReady && !sending)
        }
        if triggerDrain {
            ioQueue.async { [weak self] in self?.drainSendQueue() }
        }
        return enqueued
    }

    public func sendVideo(_ payload: [UInt8], isKeyframe: Bool, timestampNanos: UInt64? = nil) -> FramedSocket.VideoResult {
        let (result, triggerDrain): (FramedSocket.VideoResult, Bool) = lock.withLock {
            guard !closed else { return (.closed, false) }
            if scheduler.dropVideoIfWaiting(isKeyframe: isKeyframe) { return (.queued, false) }
            guard let wire = try? framer.frame(.video, payload: payload, keyframe: isKeyframe, timestampNanos: timestampNanos) else {
                return (.needKeyframe, false)
            }
            let needKeyframe = scheduler.enqueue(video: wire, isKeyframe: isKeyframe)
            return (needKeyframe ? .needKeyframe : .queued, isReady && !sending)
        }
        if triggerDrain {
            ioQueue.async { [weak self] in self?.drainSendQueue() }
        }
        return result
    }

    public func close(_ reason: String) {
        let first = lock.withLock { () -> Bool in
            guard !closed else { return false }
            closed = true
            dialTimer?.cancel()
            dialTimer = nil
            return true
        }
        guard first else { return }
        connection.stateUpdateHandler = nil
        connection.cancel()
        onClose(reason)
    }

    private func drainSendQueue() {
        let nextWire: [UInt8]? = lock.withLock {
            guard !closed, isReady, !sending else { return nil }
            guard let wire = scheduler.next() else { return nil }
            sending = true
            return wire
        }
        guard let wire = nextWire else { return }
        connection.send(content: Data(wire), completion: .contentProcessed { [weak self] error in
            guard let self else { return }
            if let error {
                self.close("NWConnection write failed: \(error)")
                return
            }
            self.lock.withLock { self.sending = false }
            self.drainSendQueue()
        })
    }

    private func receiveNext() {
        guard !isClosed else { return }
        connection.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1024) { [weak self] data, _, isComplete, error in
            guard let self, !self.isClosed else { return }
            if let error {
                self.close("NWConnection read failed: \(error)")
                return
            }
            if let data, !data.isEmpty {
                do {
                    try self.parser.append(data)
                    while let frame = try self.parser.next() {
                        if self.validator == nil {
                            guard frame.header.stream == .control else {
                                self.close("first frame was not control")
                                return
                            }
                            self.validator = SequenceValidator(sessionID: frame.header.sessionID)
                        }
                        try self.validator?.accept(frame.header)
                        if self.isClosed { return }
                        guard let channel = self.channel else {
                            self.onFrame(frame, self)
                            continue
                        }
                        switch try channel.receive(frame) {
                        case .none: break
                        case .sendProof(let proof):
                            guard self.send(.control, payload: proof) else {
                                self.close("could not send auth proof")
                                return
                            }
                        case .verified(let peer):
                            self.onVerified(peer, self)
                        case .message(let opened):
                            self.onFrame(opened, self)
                        }
                    }
                } catch {
                    self.close("protocol error: \(error)")
                    return
                }
            }
            if isComplete {
                self.close("peer closed the connection")
                return
            }
            self.receiveNext()
        }
    }
}
