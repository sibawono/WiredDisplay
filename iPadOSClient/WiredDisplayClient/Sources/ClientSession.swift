import AVFoundation
import CoreMedia
import Foundation
import Network
import os
import UIKit
import WDProtocol
import WDSession
import WDVideo

/// Observable connection state for the UI. Main actor only.
@MainActor @Observable
final class ConnectionModel {
    enum Phase: Equatable {
        case starting
        case waitingForMac
        case connecting
        case streaming
        case failed(String)
    }

    var phase: Phase = .starting
    var macName = ""
    var streamConfig: StreamConfig?
    var lastError: String?
    var framesShown = 0
    var framesDropped = 0
    var liveFPS = 0
    var liveLatencyMs: Double?
    /// Current Mac Display Space (0 = Default, 1 = More, 2 = Most); nil if unknown.
    var displaySpace: Int?
    /// Current Mac Quality preset (0 = Balanced, 1 = Pro, 2 = Ultra, 3 = High Color); nil if unknown.
    var qualityPreset: Int?
    var speakerOn = false
    var microphoneOn = false
    /// Set while an unknown Mac waits for the user to confirm pairing (D-023).
    var pairingCode: String?
    var pairedMacs: [TrustStore.TrustedPeer] = []
    /// Brightness indicator (D-033): the value and a token that changes on
    /// every Mac-driven change, so the overlay can hide after a moment.
    var brightnessHUD: (value: Float, token: Int)?
    /// Live iPad screen brightness (0...1), kept in sync with Mac brightness keys and slider.
    var screenBrightness: Float = 0.7
}

/// Client side of a session (iPad). Listens on 127.0.0.1:9100; the Mac dials in
/// through usbmuxd over the cable (D-002, D-004, D-014). One Mac at a time.
///
/// Concurrency: all mutable state below is confined to `queue`; that is the
/// invariant behind `@unchecked Sendable`. UI updates hop to the main actor.
final class ClientSession: @unchecked Sendable {
    private let queue = DispatchQueue(label: "wireddisplay.client.session", qos: .userInteractive)
    private let model: ConnectionModel
    private let renderer: SwitchableSink
    private var decodeFailures = DecodeFailureDetector()
    private var hello: Hello

    private var listener: NWListener?
    private var connection: NWConnection?
    private var parser = FrameParser()
    private var validator: SequenceValidator?
    private var framer = SessionFramer(sessionID: 0, clock: { 0 })
    private var peerHello: Hello?
    private var config: StreamConfig?
    private var format: CMVideoFormatDescription?
    private var formatSets: [[UInt8]] = []
    private var lastKeyframeRequest = Date.distantPast
    private var lastHeard = Date()
    /// D-023: this iPad's identity and the Macs it trusts (Keychain).
    let trust = TrustStore(keychainService: "dev.wireddisplay.client")
    private var channel: SecureChannel?
    /// The Mac proved its identity but the user has not confirmed it yet.
    private var pendingPeer: SecureChannel.Peer?
    private var trustedPeer: SecureChannel.Peer?
    /// The Mac's hello can arrive before the user confirms pairing.
    private var pendingHostHello: Hello?
    private var outstandingSends = 0
    private var watchdog: DispatchSourceTimer?
    private var running = false
    /// What the user enabled; re-sent to the host on every new connection.
    private var audioRoute = (speaker: false, microphone: false)
    /// False while the app is in the background with audio running (D-018).
    private var videoActive = true
    private let speakerSink: AudioJitterBuffer
    private var speakerPackets = 0
    private let presentMeter = FrameRateMeter()
    /// Latency diagnostics: host clock minus iPad clock, estimated from pings
    /// (the largest sample is closest, since one-way delay only lowers it).
    private var clockOffset: Int64?
    /// Recent offset samples (one per ping, every 2 s). The offset is the max
    /// over the last 8 only: the Mac and iPad clocks drift ~20 ppm apart, and
    /// an all-time max made "sent->enqueued" climb 1.2 ms a minute (soak test,
    /// audit). Cleared on every connection.
    private var offsetSamples: [Int64] = []
    private var transitSamples: [Double] = []
    private var droppedMicrophone = 0

    init(model: ConnectionModel, renderer: SwitchableSink, hello: Hello, speakerSink: AudioJitterBuffer) {
        self.model = model
        self.renderer = renderer
        self.hello = hello
        self.speakerSink = speakerSink
        refreshPairedMacs()
    }

    /// The user answered the pairing prompt for the current connection.
    func answerPairing(code: String, accept: Bool) {
        queue.async { [self] in
            guard let peer = pendingPeer, peer.pairingCode == code, let connection else { return }
            pendingPeer = nil
            ui { $0.pairingCode = nil }
            guard accept else { return endConnection(reason: "pairing declined on the iPad", sendBye: true) }
            do {
                try trust.trust(peer.identityKey, name: "Mac")
            } catch {
                return endConnection(reason: "could not save pairing: \(error)", sendBye: true)
            }
            ClientLog.write("paired with Mac \(peer.fingerprint)")
            refreshPairedMacs()
            becomeTrusted(peer, on: connection)
        }
    }

    func forgetPairedMacs() {
        queue.async { [self] in
            trust.forgetAllPeers()
            refreshPairedMacs()
        }
    }

    private func refreshPairedMacs() {
        let peers = trust.peers
        ui { $0.pairedMacs = peers }
    }

    /// The Mac set the iPad's brightness (keys or menu slider, D-033). Main actor.
    var onBrightness: (@MainActor @Sendable (Float) -> Void)?
    /// Local cursor (D-038), delivered on the main queue.
    var onCursor: (@MainActor @Sendable (Float, Float, Bool) -> Void)?
    var onCursorImage: (@MainActor @Sendable (CursorImage) -> Void)?
    private var reportedBrightness: Float?

    /// The iPad rotated (D-039): the next hello carries the new shape, and a
    /// live session tells the Mac now so it rebuilds the display.
    func setPanelSize(width: UInt32, height: UInt32) {
        queue.async { [self] in
            guard hello.pixelWidth != width || hello.pixelHeight != height else { return }
            hello.pixelWidth = width
            hello.pixelHeight = height
            ClientLog.write("panel now \(width)x\(height) (\(height > width ? "portrait" : "landscape"))")
            guard let connection, peerHello != nil else { return }
            send(stream: .control, payload: SessionCodec.encode(.panelSize(width: width, height: height)), on: connection)
        }
    }

    /// Tell the Mac the iPad's current brightness (connect, Control Center).
    func sendBrightness(_ value: Float) {
        queue.async { [self] in
            reportedBrightness = value
            guard let connection, peerHello != nil else { return }
            send(stream: .control, payload: SessionCodec.encode(.brightness(value)), on: connection)
        }
    }

    func setAudioRoute(speaker: Bool, microphone: Bool) {
        queue.async { [self] in
            audioRoute = (speaker, microphone)
            guard let connection, peerHello != nil else { return }
            send(stream: .control, payload: SessionCodec.encode(.audioRoute(speaker: speaker, microphone: microphone)),
                 on: connection)
        }
    }

    /// Background with audio: keep the connection, pause video (D-018).
    func setVideoActive(_ active: Bool) {
        queue.async { [self] in
            guard videoActive != active else { return }
            videoActive = active
            if !active {
                config = nil
                format = nil
                renderer.flush(removingImage: true)
            }
            guard let connection, peerHello != nil else { return }
            send(stream: .control, payload: SessionCodec.encode(.videoActive(active)), on: connection)
        }
    }

    func sendMicrophone(_ packet: AudioPacket) {
        queue.async { [self] in
            guard let connection, peerHello != nil, audioRoute.microphone else {
                droppedMicrophone += 1
                if droppedMicrophone == 1 || droppedMicrophone % 500 == 0 {
                    ClientLog.write("microphone packet not sent (connected \(self.connection != nil), " +
                                    "hello \(peerHello != nil), route \(audioRoute.microphone)) x\(droppedMicrophone)")
                }
                return
            }
            // Bounded: never let microphone audio pile up behind a slow link.
            guard outstandingSends <= 64 else { return }
            send(stream: .microphone, payload: packet.encoded(), on: connection)
        }
    }


    // MARK: lifecycle (call from main)

    func start() {
        queue.async { [self] in
            guard !running else { return }
            running = true
            startListener()
        }
    }

    /// App leaving the foreground or user disconnect: iPadOS suspends us, so
    /// close cleanly instead of pretending to stay connected.
    func stop(reason: String) {
        queue.async { [self] in
            running = false
            endConnection(reason: reason, sendBye: true)
            listener?.cancel()
            listener = nil
            ui { $0.phase = .starting }
        }
    }

    func send(_ event: InputEvent) {
        queue.async { [self] in
            guard let connection, peerHello != nil else { return }
            // Bounded: if the link backs up, drop pointer moves first; never
            // drop button changes or releaseAll.
            if case .pointer(.move, _, _, _) = event, outstandingSends > 64 { return }
            send(stream: .input, payload: SessionCodec.encode(event), on: connection)
        }
    }

    // MARK: listener

    private func startListener() {
        guard let port = NWEndpoint.Port(rawValue: SessionConstants.clientPort) else { return }
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: port) // BUG-011
        parameters.allowLocalEndpointReuse = true
        parameters.acceptLocalOnly = true
        if let options = parameters.defaultProtocolStack.transportProtocol as? NWProtocolTCP.Options {
            options.noDelay = true
        }
        do {
            let created = try NWListener(using: parameters)
            created.stateUpdateHandler = { [weak self, weak created] state in
                guard let self, let created else { return }
                self.listenerChanged(created, state)
            }
            created.newConnectionHandler = { [weak self, weak created] connection in
                guard let self, let created, self.listener === created else { return connection.cancel() }
                self.accept(connection)
            }
            listener = created
            created.start(queue: queue)
        } catch {
            ui { $0.phase = .failed("listener: \(error)") }
        }
    }

    private func listenerChanged(_ source: NWListener, _ state: NWListener.State) {
        guard listener === source else { return }
        ClientLog.write("listener \(state)")
        switch state {
        case .ready:
            ui { $0.phase = .waitingForMac }
        case .failed(let error):
            listener = nil
            source.cancel()
            ui { $0.phase = .failed("listener: \(error)") }
            // Retry while the app is in front.
            queue.asyncAfter(deadline: .now() + 2) { [weak self] in
                guard let self, self.running, self.listener == nil else { return }
                self.startListener()
            }
        default:
            break
        }
    }

    private func accept(_ incoming: NWConnection) {
        guard connection == nil else {
            ClientLog.write("incoming connection refused: a session is still open (one Mac at a time)")
            return incoming.cancel()
        }
        ClientLog.write("incoming connection from the Mac")
        let channel: SecureChannel
        do {
            channel = SecureChannel(role: .client, identity: try trust.identity())
        } catch {
            ClientLog.write("identity unavailable: \(error)")
            ui { $0.lastError = "Keychain: \(error)" }
            return incoming.cancel()
        }
        connection = incoming
        self.channel = channel
        pendingPeer = nil
        trustedPeer = nil
        pendingHostHello = nil
        parser = FrameParser()
        validator = nil
        peerHello = nil
        config = nil
        format = nil
        formatSets = []
        outstandingSends = 0
        clockOffset = nil
        offsetSamples = []
        transitSamples = []
        var generator = SystemRandomNumberGenerator()
        framer = SessionFramer(sessionID: generator.next(), channel: channel,
                               clock: { clock_gettime_nsec_np(CLOCK_UPTIME_RAW) })
        lastHeard = Date()
        incoming.stateUpdateHandler = { [weak self, weak incoming] state in
            guard let self, let incoming, self.connection === incoming else { return }
            switch state {
            case .ready:
                self.ui { $0.phase = .connecting }
                // Handshake first (D-023); our hello follows once we trust the Mac.
                self.send(stream: .control, payload: channel.authHelloPayload, on: incoming)
                self.receive(on: incoming)
                self.startWatchdog()
            case .failed(let error):
                self.endConnection(reason: "connection failed: \(error)", sendBye: false)
            case .cancelled:
                self.endConnection(reason: "connection closed", sendBye: false)
            default:
                break
            }
        }
        incoming.start(queue: queue)
    }

    private func startWatchdog() {
        watchdog?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 2, repeating: 2)
        timer.setEventHandler { [weak self] in
            guard let self, self.connection != nil else { return }
            if Date().timeIntervalSince(self.lastHeard) > 6 {
                self.endConnection(reason: "no traffic from Mac for 6 s", sendBye: false)
            }
        }
        timer.resume()
        watchdog = timer
    }

    private func endConnection(reason: String, sendBye: Bool) {
        watchdog?.cancel()
        watchdog = nil
        guard let current = connection else { return }
        connection = nil
        channel = nil
        pendingPeer = nil
        trustedPeer = nil
        pendingHostHello = nil
        current.stateUpdateHandler = nil
        if sendBye, peerHello != nil, let wire = try? framer.frame(.control, payload: SessionCodec.encode(.bye(reason))) {
            current.send(content: Data(wire), completion: .contentProcessed { _ in current.cancel() })
        } else {
            current.cancel()
        }
        renderer.flush(removingImage: true)
        let wasStreaming = config != nil
        config = nil
        let stillRunning = running // read on `queue`, not on the main actor
        ui {
            $0.streamConfig = nil
            $0.pairingCode = nil
            $0.lastError = reason
            if case .failed = $0.phase { return }
            $0.phase = stillRunning ? .waitingForMac : .starting
        }
        ClientLog.write("connection ended (streaming \(wasStreaming)): \(reason)")
    }

    // MARK: receive

    private func receive(on current: NWConnection) {
        current.receive(minimumIncompleteLength: 1, maximumLength: 512 * 1024) { [weak self] data, _, isComplete, error in
            guard let self, self.connection === current else { return }
            if let error { return self.endConnection(reason: "receive: \(error)", sendBye: false) }
            if let data, !data.isEmpty {
                do {
                    try self.parser.append(data)
                    while let frame = try self.parser.next() {
                        if self.validator == nil {
                            guard frame.header.stream == .control else {
                                return self.endConnection(reason: "first frame was not control", sendBye: false)
                            }
                            self.validator = SequenceValidator(sessionID: frame.header.sessionID)
                        }
                        try self.validator?.accept(frame.header)
                        self.lastHeard = Date()
                        guard let channel = self.channel else { return }
                        switch try channel.receive(frame) {
                        case .none: break
                        case .sendProof(let proof): self.send(stream: .control, payload: proof, on: current)
                        case .verified(let peer): self.verified(peer, on: current)
                        case .message(let opened): try self.handle(opened, on: current)
                        }
                        guard self.connection === current else { return }
                    }
                } catch {
                    return self.endConnection(reason: "protocol error: \(error)", sendBye: false)
                }
            }
            if isComplete { return self.endConnection(reason: "Mac closed the connection", sendBye: false) }
            self.receive(on: current)
        }
    }

    /// The Mac proved its identity: pinned Macs connect at once; an unknown
    /// Mac waits for the user (the code is shown on both screens).
    private func verified(_ peer: SecureChannel.Peer, on current: NWConnection) {
        if trust.isTrusted(peer.identityKey) {
            ClientLog.write("Mac authenticated: paired key \(peer.fingerprint)")
            return becomeTrusted(peer, on: current)
        }
        ClientLog.write("unknown Mac \(peer.fingerprint): asking the user (code \(peer.pairingCode))")
        pendingPeer = peer
        ui { $0.pairingCode = peer.pairingCode }
    }

    private func becomeTrusted(_ peer: SecureChannel.Peer, on current: NWConnection) {
        trustedPeer = peer
        send(stream: .control, payload: SessionCodec.encode(.hello(hello)), on: current)
        if let host = pendingHostHello {
            pendingHostHello = nil
            do { try acceptHostHello(host, on: current) } catch {
                endConnection(reason: "protocol error: \(error)", sendBye: false)
            }
        }
    }

    private func handle(_ frame: Frame, on current: NWConnection) throws {
        switch frame.header.stream {
        case .control:
            switch try SessionCodec.decodeControl(frame.payload) {
            case .hello(let host):
                guard peerHello == nil, pendingHostHello == nil, host.role == .host else {
                    throw WireError.invalidValue("unexpected hello")
                }
                guard trustedPeer != nil else {
                    pendingHostHello = host
                    ui { $0.macName = host.deviceName } // shown in the pairing prompt
                    return
                }
                try acceptHostHello(host, on: current)
            case .streamConfig(let streamConfig):
                guard peerHello != nil else { throw WireError.invalidValue("config before hello") }
                guard videoActive else { return } // late config from before a pause
                // A new point size alone (the Mac's "looks like" changed) keeps
                // the decoder; a new codec or pixel size starts over.
                if config?.codec != streamConfig.codec || config?.pixelWidth != streamConfig.pixelWidth
                    || config?.pixelHeight != streamConfig.pixelHeight {
                    format = nil
                }
                config = streamConfig
                ui {
                    $0.streamConfig = streamConfig
                    $0.phase = .streaming
                    $0.lastError = nil
                }
            case .ping(let value):
                send(stream: .control, payload: SessionCodec.encode(.pong(value)), on: current)
                let estimate = Int64(bitPattern: value) &- Int64(bitPattern: clock_gettime_nsec_np(CLOCK_UPTIME_RAW))
                offsetSamples.append(estimate)
                if offsetSamples.count > 8 { offsetSamples.removeFirst() }
                clockOffset = offsetSamples.max()
            case .brightness(let value):
                if let apply = onBrightness { Task { @MainActor in apply(value) } }
            case .cursor(let x, let y, let visible):
                if let apply = onCursor { DispatchQueue.main.async { MainActor.assumeIsolated { apply(x, y, visible) } } }
            case .cursorImage(let image):
                if let apply = onCursorImage { DispatchQueue.main.async { MainActor.assumeIsolated { apply(image) } } }
            case .displaySpace(let raw):
                ui { $0.displaySpace = Int(raw) }
            case .qualityPreset(let raw):
                ui { $0.qualityPreset = Int(raw) }
            case .pong, .requestKeyframe, .audioRoute, .videoActive, .decodeFailed, .panelSize:
                break
            case .authHello, .authProof:
                throw WireError.invalidValue("handshake message after handshake")
            case .bye(let reason):
                endConnection(reason: "Mac: \(reason)", sendBye: false)
            }
        case .video:
            guard trustedPeer != nil else { throw WireError.invalidValue("video before pairing") }
            guard videoActive else { return } // frames in flight when video paused
            guard let config else {
                // A frame can overtake its config (start, resume, rotation):
                // drop it and ask for a keyframe instead of ending the session (D-042).
                requestKeyframe(on: current)
                return
            }
            present(AccessUnit(codec: config.codec == .hevc ? .hevc : .h264, annexB: frame.payload),
                    wireBytes: frame.payload.count, timestamp: frame.header.timestampNanos, on: current)
        case .speaker:
            guard trustedPeer != nil else { throw WireError.invalidValue("audio before pairing") }
            speakerSink.push(try AudioPacket.decode(frame.payload, expectedChannels: SessionConstants.speakerChannels))
            speakerPackets += 1
            if speakerPackets == 1 || speakerPackets % 500 == 0 {
                ClientLog.write("speaker packets received \(speakerPackets), jitter \(speakerSink.stats)")
            }
        case .input, .microphone, .camera:
            throw WireError.invalidValue("unexpected \(frame.header.stream) stream from Mac")
        }
    }

    /// Ask the Mac to change its Display Space (0 = Default, 1 = More, 2 = Most).
    func setDisplaySpace(_ index: Int) {
        guard (0...2).contains(index) else { return }
        queue.async { [self] in
            guard trustedPeer != nil, let connection else { return }
            send(stream: .control, payload: SessionCodec.encode(.displaySpace(UInt8(index))), on: connection)
        }
    }

    /// Ask the Mac to change its Quality preset (0 = Balanced, 1 = Pro, 2 = Ultra, 3 = High Color).
    func setQualityPreset(_ index: Int) {
        guard (0...3).contains(index) else { return }
        queue.async { [self] in
            guard trustedPeer != nil, let connection else { return }
            send(stream: .control, payload: SessionCodec.encode(.qualityPreset(UInt8(index))), on: connection)
        }
    }

    private func acceptHostHello(_ host: Hello, on current: NWConnection) throws {
        guard host.protocolVersion == SessionConstants.protocolVersion else {
            throw WireError.invalidValue("Mac protocol \(host.protocolVersion)")
        }
        peerHello = host
        ui { $0.macName = host.deviceName }
        // Tell the host what to start: audio directions, and whether
        // video is wanted right now.
        send(stream: .control, payload: SessionCodec.encode(.audioRoute(speaker: audioRoute.speaker,
                                                                         microphone: audioRoute.microphone)),
             on: current)
        if !videoActive {
            send(stream: .control, payload: SessionCodec.encode(.videoActive(false)), on: current)
        }
        if let reportedBrightness {
            send(stream: .control, payload: SessionCodec.encode(.brightness(reportedBrightness)), on: current)
        }
        if let peer = trustedPeer { trust.rename(peer.identityKey, to: host.deviceName); refreshPairedMacs() }
    }

    private func present(_ unit: AccessUnit, wireBytes: Int, timestamp: UInt64, on current: NWConnection) {
        if unit.isKeyframe {
            let sets = unit.parameterSets
            if format == nil || sets != formatSets {
                do {
                    format = try SampleBuffers.formatDescription(for: unit)
                    formatSets = sets
                } catch {
                    format = nil
                    NSLog("WiredDisplay: bad keyframe: \(error)")
                    if decodeFailures.failed(at: ProcessInfo.processInfo.systemUptime) {
                        ClientLog.write("keyframes keep failing; asking the Mac for a simpler format")
                        send(stream: .control, payload: SessionCodec.encode(.decodeFailed), on: current)
                    }
                }
            }
        }
        if renderer.takeSwitch() {
            // Renderer switched (D-040): start the new path at a keyframe.
            renderer.flush(removingImage: false)
            format = nil
            if !unit.isKeyframe { requestKeyframe(on: current); return }
            format = try? SampleBuffers.formatDescription(for: unit)
        }
        if renderer.isFailed {
            // Repeated failures = this iPad cannot decode the format (D-031):
            // ask the Mac to step down (no 4:4:4, then 8-bit).
            ClientLog.write("renderer failed: \(renderer.failureDescription ?? "no error")")
            if decodeFailures.failed(at: ProcessInfo.processInfo.systemUptime) {
                ClientLog.write("decode keeps failing; asking the Mac for a simpler format")
                send(stream: .control, payload: SessionCodec.encode(.decodeFailed), on: current)
            }
        }
        if renderer.needsFlush {
            // The flag only clears after a flush; without one video froze for
            // good (review finding 4). Resume at the next keyframe.
            NSLog("WiredDisplay: renderer needs flush; flushing")
            renderer.flush(removingImage: false)
            if !unit.isKeyframe { format = nil }
        }
        // Frames were dropped because the decoder fell behind: resume at a keyframe.
        // Repeated stalls count as decode failures, so the Mac steps down (D-031).
        let backlog = renderer.takeBacklogEvents()
        if backlog.keyframeWanted { requestKeyframe(on: current) }
        if backlog.stalls > 0 {
            ClientLog.write("decoder behind the stream (\(backlog.stalls) stall(s)); frames dropped until a keyframe")
            for _ in 0..<backlog.stalls where decodeFailures.failed(at: ProcessInfo.processInfo.systemUptime) {
                ClientLog.write("decoder keeps falling behind; asking the Mac for a lighter format")
                send(stream: .control, payload: SessionCodec.encode(.decodeFailed), on: current)
            }
        }
        guard let format else {
            requestKeyframe(on: current)
            countFrame(shown: false)
            return
        }
        do {
            let time = CMTime(value: CMTimeValue(timestamp), timescale: 1_000_000_000)
            let sample = try SampleBuffers.sampleBuffer(for: unit, format: format, presentationTime: time)
            if timestamp % 300 == 0, let offset = clockOffset { // about one sample every 5 s at 60 Hz
                let hostNow = Int64(bitPattern: clock_gettime_nsec_np(CLOCK_UPTIME_RAW)) &+ offset
                let transit = Double(hostNow &- Int64(bitPattern: timestamp)) / 1e6
                CMSetAttachment(sample, key: "WiredDisplayTransitMS" as CFString,
                                value: NSNumber(value: transit), attachmentMode: kCMAttachmentMode_ShouldNotPropagate)
            }
            renderer.enqueue(sample)
            if let offset = clockOffset {
                // Mac sent it -> iPad hands it to the display layer (transport,
                // decryption, parsing); excludes encode and the final vsync.
                let local = Int64(bitPattern: clock_gettime_nsec_np(CLOCK_UPTIME_RAW)) &+ offset
                let ms = Double(local &- Int64(bitPattern: timestamp)) / 1_000_000
                transitSamples.append(ms)
                hudTransitSamples.append(ms)
            }
            countFrame(shown: true)
            if let report = presentMeter.tick(bytes: wireBytes) {
                var line = "video presented: \(report)"
                if !transitSamples.isEmpty {
                    let sorted = transitSamples.sorted()
                    line += String(format: ", sent->enqueued p50 %.1f p95 %.1f ms", sorted[sorted.count / 2], sorted[sorted.count * 95 / 100])
                    transitSamples.removeAll(keepingCapacity: true)
                }
                ClientLog.write(line)
            }
        } catch {
            requestKeyframe(on: current)
            countFrame(shown: false)
        }
    }

    /// Frame counters & live HUD stats, published at most once a second
    /// instead of one main-actor hop per video frame (audit B-11).
    private var framesShown = 0, framesDropped = 0, shownInWindow = 0
    private var hudTransitSamples: [Double] = []
    private var countersPublished: TimeInterval = 0

    private func countFrame(shown: Bool) {
        if shown { framesShown += 1; shownInWindow += 1 } else { framesDropped += 1 }
        let now = ProcessInfo.processInfo.systemUptime
        let elapsed = now - countersPublished
        guard elapsed >= 1 else { return }
        let fps = countersPublished > 0 ? Int((Double(shownInWindow) / elapsed).rounded()) : shownInWindow
        let latency: Double? = hudTransitSamples.isEmpty ? nil : hudTransitSamples.sorted()[hudTransitSamples.count / 2]
        countersPublished = now
        shownInWindow = 0
        hudTransitSamples.removeAll(keepingCapacity: true)
        let (shownTotal, droppedTotal) = (framesShown, framesDropped)
        ui {
            $0.framesShown = shownTotal
            $0.framesDropped = droppedTotal
            $0.liveFPS = fps
            if let latency, latency >= 0, latency < 500 { $0.liveLatencyMs = latency }
        }
    }

    private func requestKeyframe(on current: NWConnection) {
        guard Date().timeIntervalSince(lastKeyframeRequest) > 0.5 else { return }
        lastKeyframeRequest = Date()
        send(stream: .control, payload: SessionCodec.encode(.requestKeyframe), on: current)
    }

    private func send(stream: StreamType, payload: [UInt8], on current: NWConnection) {
        guard let wire = try? framer.frame(stream, payload: payload) else { return }
        outstandingSends += 1
        current.send(content: Data(wire), completion: .contentProcessed { [weak self] error in
            guard let self else { return }
            self.queue.async {
                // Completions from an old connection must not touch the new one
                // (review finding 10).
                guard self.connection === current else { return }
                self.outstandingSends -= 1
                if let error { self.endConnection(reason: "send: \(error)", sendBye: false) }
            }
        })
    }

    private func ui(_ update: @escaping @MainActor (ConnectionModel) -> Void) {
        let model = model
        Task { @MainActor in update(model) }
    }
}
