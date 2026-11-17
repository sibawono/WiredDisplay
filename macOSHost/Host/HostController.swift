import CoreGraphics
import CoreMedia
import Foundation
import IOKit.pwr_mgt
import os
import WDProtocol
import WDSession
import WDTransport
import WDUsbmux
import WDVideo

/// Session lifecycle on the Mac: wait for the iPad on USB, connect, handshake,
/// then run video (virtual display -> capture -> encode) and audio (loopback
/// devices <-> PCM) until the connection ends; tear everything down in a fixed
/// order and retry with backoff (R-REL-01).
///
/// Threads:
/// - `runLoop` (own thread): connection setup and final teardown.
/// - `queue`: incoming frames; owns `socket`, `peerHello`, `lastHeard`,
///   `encoder`, `injector`, `audio`.
/// - `videoQueue`: starts/stops the video pipeline (display, capture, encoder,
///   injector) so the client can pause video while audio continues (D-018).
/// Picture quality presets (menu bar "Quality", D-027). Each maps to the
/// encoder's chroma path and bit depth.
enum QualityPreset: String, CaseIterable, Sendable {
    case balanced, pro, ultra, highColor

    var chroma: ChromaMode {
        switch self {
        case .balanced: return .hybrid
        case .pro: return .c420
        case .ultra, .highColor: return .c444
        }
    }

    var tenBit: Bool { self != .highColor }

    var title: String {
        switch self {
        case .balanced: return "Balanced — Hybrid"
        case .pro: return "Pro — 4:2:0 10-bit"
        case .ultra: return "Ultra — 4:4:4 10-bit"
        case .highColor: return "High Color — 4:4:4 8-bit"
        }
    }

    var detail: String {
        switch self {
        case .balanced: return "4:2:0 while moving, 4:4:4 when still. Smooth cursor, sharp text."
        case .pro: return "Lowest latency, smooth gradients. Coloured text edges slightly soft."
        case .ultra: return "Sharpest colour and gradients. The cursor can lag in fast motion."
        case .highColor: return "Full colour detail, 8-bit. Some gradient banding; cursor can lag."
        }
    }

    init?(chroma: ChromaMode, tenBit: Bool) {
        guard let match = Self.allCases.first(where: { $0.chroma == chroma && $0.tenBit == tenBit }) else { return nil }
        self = match
    }

    static let defaultsKey = "qualityPreset"
    static var saved: QualityPreset? {
        UserDefaults.standard.string(forKey: defaultsKey).flatMap(QualityPreset.init(rawValue:))
    }
}

final class HostController: @unchecked Sendable {
    struct Options: Sendable {
        var allowInput = false
        /// Diagnostics (D-031): act as if the iPad reported a decode failure
        /// 8 s into each session, to exercise the automatic step-down.
        var testDecodeFallback = false
        /// HEVC by default (D-019: user A/B test); used only when the client
        /// advertises it, with automatic H.264 fallback. `--codec h264` forces H.264.
        var codec: VideoCodec? = .hevc
        /// 80 Mbit/s: the measured link carries >1 Gbit/s per direction
        /// (BUG-032 correction); higher bitrate keeps desktop text crisp.
        var bitrateMbps = 80
        var fps = 60
        /// sRGB by default (BUG-033): the iPad renders P3-tagged frames as if
        /// sRGB (measured 29 % less saturation). `--color p3` stays experimental.
        var displayP3 = false
        /// Chroma path (BUG-034, D-022): hybrid by default (user test: smooth
        /// cursor and sharp colour); `--chroma 420|444|hybrid`.
        var chroma: ChromaMode = .hybrid
        /// 10-bit HEVC against gradient banding (BUG-035); `--depth 8|10`.
        var tenBit = true
        /// Default "looks like" size: one step more space than native @2x
        /// (user request); `--space native|more|most`. All three stay selectable
        /// in System Settings › Displays.
        var space: VirtualDisplayController.Space = .more
    }

    enum State: Equatable, Sendable {
        case waitingForDevice
        case connecting
        case streaming(String)
        case audioOnly(String)
        case backingOff(String)
        /// An unknown iPad wants to pair; the code is shown on both screens.
        case pairing(String)
        case stopped
    }

    private let options: Options
    private let queue = DispatchQueue(label: "wireddisplay.host.session")
    private let videoQueue = DispatchQueue(label: "wireddisplay.host.video")
    /// Audio engines start/stop here: starting one can block on a TCC prompt,
    /// which must never stall frames, input or video (BUG-024).
    private let audioQueue = DispatchQueue(label: "wireddisplay.host.audio")
    private let stopping = OSAllocatedUnfairLock(initialState: false)
    private let inputEnabled: OSAllocatedUnfairLock<Bool>
    /// Chroma path and bit depth used by the next encoder (live-switchable).
    private let quality: OSAllocatedUnfairLock<(chroma: ChromaMode, tenBit: Bool)>
    private let onState: @Sendable (State) -> Void
    /// Identity and paired iPads (D-023), in the login Keychain.
    let trust = TrustStore(keychainService: "dev.wireddisplay.host")
    /// Asks the user to pair an unknown iPad when one is already paired.
    /// Blocks the caller (the session thread) until answered; false = reject.
    private let confirmPairing: @Sendable (SecureChannel.Peer) -> Bool
    /// This connection's pairing code, for the menu (compare with the iPad).
    let connectionCode = OSAllocatedUnfairLock<String?>(initialState: nil)

    // Owned by `queue`.
    private var injector: InputInjector?
    private var encoder: VideoEncoder?
    private var socket: FramedSocket?
    private var peerHello: Hello?
    private var lastHeard = Date()
    private var audio: HostAudioBridge?
    private let helloArrived = DispatchSemaphore(value: 0)
    /// The client's proven identity, and whether WE trust it yet. Until then,
    /// control messages wait in `pendingControl` and media/input are dropped.
    private var verifiedPeer: SecureChannel.Peer?
    /// Formats the connected iPad cannot decode (D-031), from `decodeLimitsKey`.
    private let peerLimits = OSAllocatedUnfairLock<(fingerprint: String?, limits: DecodeLimits)>(initialState: (nil, []))
    private var lastDecodeStepDown = Date.distantPast
    private var trusted = false
    private var pendingControl: [ControlMessage] = []

    // Owned by `videoQueue`.
    private var video: VideoPipeline?

    init(options: Options, confirmPairing: @escaping @Sendable (SecureChannel.Peer) -> Bool,
         onState: @escaping @Sendable (State) -> Void) {
        self.options = options
        self.confirmPairing = confirmPairing
        self.onState = onState
        inputEnabled = OSAllocatedUnfairLock(initialState: options.allowInput)
        quality = OSAllocatedUnfairLock(initialState: (options.chroma, options.tenBit))
    }

    /// The preset matching the current chroma and depth, or nil for a custom
    /// combination given on the command line.
    var qualityPreset: QualityPreset? {
        let current = quality.withLock { $0 }
        return QualityPreset(chroma: current.chroma, tenBit: current.tenBit)
    }

    // MARK: status for the menu

    /// What the menu shows about the session; updated as things change.
    struct SessionStatus: Sendable {
        var iPadName: String?
        var pixelSize: String?
        var pointSize: String?
        var refreshHz: Int?
        var codec: String?
        var encoding: String?
        var speaker = false
        var microphone = false
        var streamingSince: Date?
    }

    private let sessionStatus = OSAllocatedUnfairLock(initialState: SessionStatus())
    var status: SessionStatus { sessionStatus.withLock { $0 } }

    // MARK: iPad brightness (D-033)

    /// Last brightness the iPad reported (0...1); nil = no iPad connected.
    private let iPadBrightness = OSAllocatedUnfairLock<Float?>(initialState: nil)
    /// Called on the main queue when the iPad's brightness changes (for the menu slider).
    var onBrightnessChange: (@Sendable (Float?) -> Void)?

    var brightness: Float? { iPadBrightness.withLock { $0 } }

    /// Sets the iPad's real screen brightness. False if no iPad is connected.
    @discardableResult
    func setBrightness(_ value: Float) -> Bool {
        let value = min(max(value, 0), 1)
        guard iPadBrightness.withLock({ current -> Bool in
            guard current != nil else { return false }
            current = value
            return true
        }) else { return false }
        queue.async { [self] in
            guard trusted, let socket, !socket.isClosed else { return }
            send(.brightness(value), on: socket)
        }
        return true
    }

    /// A brightness key: one macOS step. False if no iPad is connected (the
    /// key then goes on to macOS as usual).
    func stepBrightness(up: Bool, fine: Bool) -> Bool {
        guard let current = brightness else { return false }
        return setBrightness(BrightnessStep.next(from: current, up: up, fine: fine))
    }

    // MARK: decode limits (D-031)

    static let decodeLimitsKey = "decodeLimits"

    private static func savedLimits() -> [String: Int] {
        UserDefaults.standard.dictionary(forKey: decodeLimitsKey) as? [String: Int] ?? [:]
    }

    /// What the connected iPad cannot decode, for the menu; nil if nothing.
    var decodeLimitNote: String? {
        let limits = peerLimits.withLock { $0.limits }
        return limits.isEmpty ? nil : limits.summary
    }

    func forgetDecodeLimits() {
        UserDefaults.standard.removeObject(forKey: Self.decodeLimitsKey)
        peerLimits.withLock { $0.limits = [] }
    }

    /// The quality actually encoded: the user's preset, within the iPad's limits.
    private func effectiveQuality() -> (chroma: ChromaMode, tenBit: Bool) {
        var current = quality.withLock { $0 }
        let limits = peerLimits.withLock { $0.limits }
        if limits.contains(.no444) { current.chroma = .c420 }
        if limits.contains(.no10Bit) { current.tenBit = false }
        return current
    }

    /// The iPad says it cannot decode the stream: drop 4:4:4, then 10-bit,
    /// remember it for this iPad, and restart the encoder. On `queue`.
    private func handleDecodeFailure(socket: FramedSocket) {
        guard Date().timeIntervalSince(lastDecodeStepDown) > 3 else { return } // a switch is under way
        let current = effectiveQuality()
        let (fingerprint, limits) = peerLimits.withLock { $0 }
        guard let next = DecodeLimits.next(after: limits, uses444: current.chroma != .c420, tenBit: current.tenBit) else {
            Log.warn("iPad cannot decode 4:2:0 8-bit either; nothing left to step down to")
            return
        }
        lastDecodeStepDown = Date()
        peerLimits.withLock { $0.limits = next }
        if let fingerprint {
            var saved = Self.savedLimits()
            saved[fingerprint] = next.rawValue
            UserDefaults.standard.set(saved, forKey: Self.decodeLimitsKey)
        }
        Log.warn("iPad cannot decode \(current.chroma.rawValue) \(current.tenBit ? 10 : 8)-bit; limiting it to \(next.summary)")
        videoQueue.async { [self] in
            do { try restartEncoding() } catch {
                Log.warn("format step-down failed: \(error)")
                queue.async { socket.close("format step-down failed: \(error)") }
            }
        }
    }

    /// Switches the encoder live (the display and the session stay up) and
    /// remembers the choice for the next launch.
    func setQuality(_ preset: QualityPreset) {
        quality.withLock { $0 = (preset.chroma, preset.tenBit) }
        UserDefaults.standard.set(preset.rawValue, forKey: QualityPreset.defaultsKey)
        Log.info("quality set to \(preset.rawValue) (\(preset.chroma.rawValue), \(preset.tenBit ? 10 : 8)-bit)")
        videoQueue.async { [self] in
            do { try restartEncoding() } catch {
                Log.warn("quality switch failed: \(error)")
                queue.async { [self] in socket?.close("quality switch failed: \(error)") }
            }
        }
    }

    func start() {
        Thread.detachNewThread { [self] in runLoop() }
    }

    func stop() {
        stopping.withLock { $0 = true }
        helloArrived.signal()
        queue.async { [self] in socket?.close("host stopping") }
    }

    private var isStopping: Bool { stopping.withLock { $0 } }

    var isInputEnabled: Bool { inputEnabled.withLock { $0 } }

    /// UserDefaults key: the menu's input choice, remembered across launches.
    static let allowInputKey = "allowInput"

    func setInputEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: Self.allowInputKey)
        inputEnabled.withLock { $0 = enabled } // the injector reads this on every event
        if !enabled { queue.async { [self] in injector?.releaseAll() } }
        Log.info("touch input \(enabled ? "ENABLED" : "disabled") by user")
    }

    // MARK: lifecycle

    private func runLoop() {
        var backoff: TimeInterval = 1
        while !isStopping {
            guard let device = waitForWiredDevice() else { break }
            onState(.connecting)
            let started = Date()
            do {
                try runSession(device)
                onState(.backingOff("session ended"))
            } catch SessionError.notListening {
                noteWait("iPad on USB, but nothing listens on port \(SessionConstants.clientPort) (WiredDisplay app not open or not in front?)")
                onState(.waitingForDevice)
                Thread.sleep(forTimeInterval: 1)
                continue
            } catch {
                Log.warn("session ended with error: \(error)")
                onState(.backingOff("\(error)"))
            }
            // Never reconnect in a tight loop (review finding 9).
            if Date().timeIntervalSince(started) > 10 { backoff = 1 }
            Thread.sleep(forTimeInterval: backoff)
            backoff = min(backoff * 2, 8)
        }
        onState(.stopped)
    }

    private enum SessionError: Swift.Error, CustomStringConvertible {
        case notListening
        case noHello
        case closedDuringSetup
        case incompatible(String)
        case notAuthenticated
        case pairingRejected
        var description: String {
            switch self {
            case .notAuthenticated: return "client did not authenticate within 5 s (old app version?)"
            case .pairingRejected: return "pairing with this iPad was not confirmed"
            case .notListening: return "client not listening"
            case .noHello: return "client did not send hello (pairing not confirmed on the iPad?)"
            case .closedDuringSetup: return "connection closed during setup"
            case .incompatible(let why): return "incompatible client: \(why)"
            }
        }
    }

    /// Only USB-attached devices (Wired Only, D-003). Returns nil when stopping.
    /// Logs what it sees whenever that changes (BUG-037: after a reboot the
    /// host waited silently until the cable was re-plugged).
    private func waitForWiredDevice() -> UsbmuxDevice? {
        onState(.waitingForDevice)
        while !isStopping {
            let seen: String
            do {
                let connection = try UsbmuxConnection()
                let devices = try connection.listDevices()
                if let device = UsbmuxDevice.wiredOnly(devices).first {
                    noteWait("iPad on USB: device \(device.deviceID)")
                    return device
                }
                let listed = devices.isEmpty ? "usbmuxd lists no device"
                    : "usbmuxd lists only non-USB devices: " + devices.map { "\($0.deviceID) \($0.connectionType)" }.joined(separator: ", ")
                // Is the iPad on the USB bus at all? (BUG-037)
                let bus = UsbRegistry.appleMobileDevices()
                seen = listed + "; USB bus: " + (bus.isEmpty ? "no iPad" : bus.joined(separator: ", "))
            } catch {
                seen = "usbmuxd not reachable: \(error)"
            }
            noteWait(seen)
            Thread.sleep(forTimeInterval: 1)
        }
        return nil
    }

    /// Logs a wait-state line only when it differs from the previous one,
    /// with how long the previous state lasted.
    private var lastWait: (text: String, since: Date)?
    private func noteWait(_ text: String) {
        guard lastWait?.text != text else { return }
        if let lastWait {
            Log.info("wait: \(text) (previous state lasted \(String(format: "%.0f", Date().timeIntervalSince(lastWait.since))) s)")
        } else {
            Log.info("wait: \(text)")
        }
        lastWait = (text, Date())
    }

    private func runSession(_ device: UsbmuxDevice) throws {
        let connection = try UsbmuxConnection()
        do {
            try connection.connect(to: device, port: SessionConstants.clientPort)
        } catch UsbmuxConnection.ClientError.refused(.connectionRefused) {
            throw SessionError.notListening
        }
        let descriptor = try connection.detachTunnel()
        Log.info("connected to device \(device.deviceID) over USB, port \(SessionConstants.clientPort)")

        var generator = SystemRandomNumberGenerator()
        let ended = DispatchSemaphore(value: 0)
        let endReason = OSAllocatedUnfairLock(initialState: "")
        let verified = DispatchSemaphore(value: 0)
        let channel: SecureChannel
        do {
            channel = SecureChannel(role: .host, identity: try trust.identity())
        } catch {
            Darwin.close(descriptor)
            throw error
        }
        let socket = FramedSocket(
            descriptor: descriptor, sessionID: generator.next(), channel: channel,
            onVerified: { [weak self] peer, origin in
                guard let self else { return }
                self.queue.async {
                    guard self.socket === origin else { return }
                    self.verifiedPeer = peer
                    verified.signal()
                }
            },
            onFrame: { [weak self] frame, origin in
                guard let self else { return }
                self.queue.async { self.handle(frame, from: origin) }
            },
            onClose: { [weak self] reason in
                endReason.withLock { $0 = reason }
                ended.signal()
                verified.signal()
                self?.helloArrived.signal()
            })
        let audio = HostAudioBridge { [weak socket] packet in
            socket?.send(.speaker, payload: packet.encoded())
        }
        queue.sync {
            self.socket = socket
            self.audio = audio
            peerHello = nil
            verifiedPeer = nil
            trusted = false
            pendingControl = []
            lastHeard = Date()
            iPadBrightness.withLock { $0 = nil }
            sessionStatus.withLock { $0 = SessionStatus() }
        }
        while helloArrived.wait(timeout: .now()) == .success {} // drain stale signals
        socket.start()

        // Activated immediately: releasing a never-resumed dispatch source traps
        // (review finding 1).
        let keepalive = DispatchSource.makeTimerSource(queue: queue)
        keepalive.schedule(deadline: .distantFuture)
        keepalive.resume()
        defer {
            // Fixed teardown order: input, video, audio, socket.
            keepalive.cancel()
            videoQueue.sync { stopVideo() }
            audioQueue.sync { audio.stopAll() }
            queue.sync {
                self.audio = nil
                self.socket = nil
                self.trusted = false
                self.pendingControl = []
            }
            socket.close("session teardown")
            Log.info("session cleaned up: \(endReason.withLock { $0 })")
            connectionCode.withLock { $0 = nil }
        }

        // 1. The iPad proves its identity (handshake, D-023).
        _ = verified.wait(timeout: .now() + 5)
        if isStopping || socket.isClosed { throw SessionError.closedDuringSetup }
        guard let peer = queue.sync(execute: { verifiedPeer }) else { throw SessionError.notAuthenticated }
        Log.info("iPad authenticated: key \(peer.fingerprint), pairing code \(peer.pairingCode)")
        let known = DecodeLimits(rawValue: Self.savedLimits()[peer.fingerprint] ?? 0)
        peerLimits.withLock { $0 = (peer.fingerprint, known) }
        if !known.isEmpty { Log.info("this iPad's decode limits: \(known.summary)") }
        connectionCode.withLock { $0 = peer.pairingCode }

        // Pings from here on keep both watchdogs fed while someone confirms
        // pairing (the iPad asks its user on first contact).
        keepalive.setEventHandler { [weak self, weak socket] in
            guard let self, let socket else { return }
            if Date().timeIntervalSince(self.lastHeard) > 6 { return socket.close("no traffic from client for 6 s") }
            self.send(.ping(clock_gettime_nsec_np(CLOCK_UPTIME_RAW)), on: socket)
            self.videoQueue.async { self.followDisplayMode() }
        }
        keepalive.schedule(deadline: .now() + 2, repeating: 2)

        // 2. Do WE trust it? Nothing from the iPad is acted on before this.
        try authorize(peer)
        if socket.isClosed { throw SessionError.closedDuringSetup }
        queue.sync {
            trusted = true
            let pending = pendingControl
            pendingControl = []
            for message in pending { try? handleControl(message, socket: socket) }
        }

        // 3. Hello both ways. The iPad sends its hello once ITS user trusts us.
        send(.hello(Hello(role: .host, deviceName: Host.current().localizedName ?? "Mac", pixelWidth: 1, pixelHeight: 1,
                          scale: 1, maxRefreshHz: UInt16(options.fps), codecs: [.h264, .hevc])),
             on: socket)

        _ = helloArrived.wait(timeout: .now() + 120)
        if isStopping || socket.isClosed { throw SessionError.closedDuringSetup }
        guard let hello = queue.sync(execute: { peerHello }) else { throw SessionError.noHello }
        guard hello.role == .client else { throw SessionError.incompatible("role \(hello.role)") }
        guard hello.protocolVersion == SessionConstants.protocolVersion else {
            throw SessionError.incompatible("protocol \(hello.protocolVersion), expected \(SessionConstants.protocolVersion)")
        }
        guard hello.codecs.contains(VideoCodec.h264) else { throw SessionError.incompatible("client lacks H.264") }
        trust.rename(peer.identityKey, to: hello.deviceName)

        // Keep the Mac's displays awake while the iPad is connected; released
        // when the session ends (user request, step 1).
        var sleepAssertion = IOPMAssertionID(0)
        let assertion = IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
                                                    IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                                    "WiredDisplay session with \(hello.deviceName)" as CFString,
                                                    &sleepAssertion)
        if assertion == kIOReturnSuccess { Log.info("display sleep prevented for this session") }
        defer {
            if assertion == kIOReturnSuccess {
                IOPMAssertionRelease(sleepAssertion)
                Log.info("display sleep assertion released")
            }
        }

        try videoQueue.sync { try startVideo(hello: hello, socket: socket) }
        ended.wait()
    }

    /// Pinned iPads pass. With no iPad paired yet, the first one is paired
    /// without asking: a headless Mac has no screen to ask on (trust on first
    /// use, D-023). Any other unknown iPad needs the user's confirmation.
    private func authorize(_ peer: SecureChannel.Peer) throws {
        if trust.isTrusted(peer.identityKey) { return }
        if trust.peers.isEmpty {
            try trust.trust(peer.identityKey, name: "iPad")
            Log.info("no iPad paired yet: paired this one on first use (key \(peer.fingerprint), code \(peer.pairingCode))")
            return
        }
        Log.info("unknown iPad (key \(peer.fingerprint)); asking the user to confirm code \(peer.pairingCode)")
        onState(.pairing(peer.pairingCode))
        guard confirmPairing(peer) else {
            Log.warn("pairing with iPad \(peer.fingerprint) rejected or timed out")
            throw SessionError.pairingRejected
        }
        try trust.trust(peer.identityKey, name: "iPad")
        Log.info("iPad \(peer.fingerprint) paired by the user")
    }

    // MARK: video pipeline (on `videoQueue`)

    private func startVideo(hello: Hello, socket: FramedSocket) throws {
        guard video == nil, !socket.isClosed else { return }
        let pipeline = VideoPipeline()
        let fps = min(options.fps, Int(hello.maxRefreshHz))
        var config = try pipeline.display.create(for: hello, refreshHz: Double(fps), wideColor: options.displayP3,
                                                 space: options.space)
        guard let displayID = pipeline.display.displayID else {
            pipeline.display.destroy()
            throw SessionError.incompatible("display vanished")
        }
        // Follow mirroring (user decision): if macOS or another tool put our
        // display in a mirror set, ScreenCaptureKit does not offer it; capture
        // the set's primary display instead, which is exactly what is shown.
        // The arrangement itself is never changed (D-015).
        Thread.sleep(forTimeInterval: 0.3) // let WindowServer apply a remembered arrangement
        let captureID = CGDisplayPrimaryDisplay(displayID)
        if captureID != displayID {
            let source = CGDisplayBounds(captureID)
            config.pointWidth = UInt32(source.width.rounded())
            config.pointHeight = UInt32(source.height.rounded())
            Log.info("WiredDisplay is mirroring display \(captureID) (\(source.size)); capturing that display")
        }

        pipeline.config = config
        pipeline.captureID = captureID
        pipeline.fps = fps
        pipeline.hello = hello
        pipeline.socket = socket

        let inputEnabled = inputEnabled
        let injector = InputInjector(displayID: displayID, queue: queue, isEnabled: { inputEnabled.withLock { $0 } })
        queue.sync { self.injector = injector }
        video = pipeline
        do {
            try startEncoding(pipeline)
        } catch {
            stopVideo()
            throw error
        }
        send(.streamConfig(pipeline.config), on: socket)
        let codec = pipeline.config.codec
        onState(.streaming("\(hello.deviceName) · \(config.pixelWidth)×\(config.pixelHeight) \(codec)"))
        let streamed = pipeline.config
        sessionStatus.withLock {
            $0.iPadName = hello.deviceName
            $0.pixelSize = "\(streamed.pixelWidth) × \(streamed.pixelHeight)"
            $0.pointSize = "\(streamed.pointWidth) × \(streamed.pointHeight)"
            $0.refreshHz = Int(streamed.refreshHz)
            $0.streamingSince = Date()
        }
        Log.info("streaming to \(hello.deviceName): \(pipeline.config) input \(isInputEnabled ? "enabled" : "disabled")")
        if options.testDecodeFallback {
            queue.asyncAfter(deadline: .now() + 8) { [weak self, weak socket] in
                guard let self, let socket, !socket.isClosed else { return }
                Log.warn("--test-decode-fallback: simulating an iPad decode failure")
                self.handleDecodeFailure(socket: socket)
            }
        }
    }

    /// Encoder + capture for the pipeline's display, at the current quality.
    /// On `videoQueue`. The display is left as it is.
    private func startEncoding(_ pipeline: VideoPipeline) throws {
        guard let socket = pipeline.socket, let hello = pipeline.hello else { return }
        let config = pipeline.config, fps = pipeline.fps
        let current = effectiveQuality()
        // Diagnostics for stutter: capture cadence vs encoded output.
        let captureMeter = FrameRateMeter(), encodeMeter = FrameRateMeter()
        let onUnit: @Sendable (AccessUnit) -> Void = { [weak self, weak socket] unit in
            guard let self, let socket else { return }
            if let report = encodeMeter.tick(bytes: unit.annexB.count) { Log.info("video encoded: \(report)") }
            if socket.sendVideo(unit.annexB, isKeyframe: unit.isKeyframe) == .needKeyframe {
                self.queue.async { self.encoder?.requestKeyframe() }
            }
        }
        var codec: VideoCodec = (options.codec == .hevc && hello.codecs.contains(VideoCodec.hevc)) ? .hevc : .h264
        let encoder: VideoEncoder
        do {
            encoder = try VideoEncoder(codec: codec, width: Int(config.pixelWidth), height: Int(config.pixelHeight),
                                       fps: fps, bitrateMbps: options.bitrateMbps,
                                       displayP3: options.displayP3, chroma: current.chroma,
                                       tenBit: current.tenBit, onUnit: onUnit)
        } catch where codec == .hevc {
            Log.warn("HEVC encoder unavailable (\(error)); falling back to H.264")
            codec = .h264
            encoder = try VideoEncoder(codec: codec, width: Int(config.pixelWidth), height: Int(config.pixelHeight),
                                       fps: fps, bitrateMbps: options.bitrateMbps,
                                       displayP3: options.displayP3, chroma: current.chroma,
                                       tenBit: current.tenBit, onUnit: onUnit)
        }
        pipeline.config.codec = codec
        pipeline.encoder = encoder
        queue.sync { self.encoder = encoder }
        try pipeline.capture.start(displayID: pipeline.captureID, pixelWidth: Int(config.pixelWidth),
                                   pixelHeight: Int(config.pixelHeight), fps: fps, displayP3: options.displayP3,
                                   bgra: encoder.wantsBGRA,
                                   onFrame: { buffer, time, dirty in
                                       if let report = captureMeter.tick() { Log.info("video captured: \(report)") }
                                       encoder.encode(buffer, presentationTime: time, dirtyFraction: dirty)
                                   },
                                   onStop: { reason in socket.close("capture stopped: \(reason)") })
        let chroma = current.chroma == .c420 ? "4:2:0" : current.chroma == .c444 ? "4:4:4" : "4:2:0 + 4:4:4"
        let codecName = codec == .hevc ? "HEVC" : "H.264"
        sessionStatus.withLock {
            $0.codec = codecName
            $0.encoding = "\(chroma) · \(current.tenBit ? 10 : 8)-bit"
        }
        Log.info("encoding \(codec) \(current.chroma.rawValue) \(current.tenBit ? 10 : 8)-bit")
    }

    /// The user can pick another "looks like" size in System Settings during a
    /// session; tell the iPad (its labels and scroll scale use the point size).
    /// The pixel stream does not change. On `videoQueue`.
    private func followDisplayMode() {
        guard let pipeline = video, let socket = pipeline.socket, pipeline.captureID != 0 else { return }
        let bounds = CGDisplayBounds(pipeline.captureID)
        let width = UInt32(bounds.width.rounded()), height = UInt32(bounds.height.rounded())
        guard width > 0, height > 0,
              width != pipeline.config.pointWidth || height != pipeline.config.pointHeight else { return }
        pipeline.config.pointWidth = width
        pipeline.config.pointHeight = height
        sessionStatus.withLock { $0.pointSize = "\(width) × \(height)" }
        Log.info("display mode changed: now looks like \(width)x\(height) pt; telling the iPad")
        send(.streamConfig(pipeline.config), on: socket)
    }

    /// Quality switch: new encoder and capture on the same display. The iPad
    /// rebuilds its decoder from the next keyframe's parameter sets.
    private func restartEncoding() throws {
        guard let pipeline = video else { return } // not streaming: applies next time
        pipeline.capture.stop()
        queue.sync {
            encoder?.invalidate()
            encoder = nil
        }
        try startEncoding(pipeline)
    }

    /// Releases input first, then capture, encoder and display. Idempotent.
    private func stopVideo() {
        guard let pipeline = video else { return }
        video = nil
        queue.sync {
            injector?.releaseAll()
            injector = nil
        }
        pipeline.capture.stop()
        queue.sync {
            encoder?.invalidate()
            encoder = nil
        }
        pipeline.display.destroy()
        sessionStatus.withLock {
            $0.pixelSize = nil; $0.pointSize = nil; $0.refreshHz = nil; $0.codec = nil; $0.encoding = nil
            $0.streamingSince = nil
        }
        Log.info("video stopped")
    }

    private final class VideoPipeline {
        let display = VirtualDisplayController()
        let capture = CaptureEngine()
        var encoder: VideoEncoder?
        var config = StreamConfig(pixelWidth: 1, pixelHeight: 1, pointWidth: 1, pointHeight: 1, refreshHz: 60, codec: .h264)
        var captureID: CGDirectDisplayID = 0
        var fps = 60
        var hello: Hello?
        weak var socket: FramedSocket?
    }

    // MARK: frames (on `queue`)

    private func handle(_ frame: Frame, from origin: FramedSocket) {
        // Frames from a connection that is no longer current are ignored.
        guard let socket, socket === origin, !socket.isClosed else { return }
        lastHeard = Date()
        do {
            switch frame.header.stream {
            case .control:
                let message = try SessionCodec.decodeControl(frame.payload)
                switch message {
                case .ping, .pong, .bye: break
                default:
                    // Held until we trust the peer (pairing may be pending).
                    guard trusted else {
                        if pendingControl.count < 16 { pendingControl.append(message) }
                        return
                    }
                }
                try handleControl(message, socket: socket)
            case .input:
                // Input is only meaningful after the handshake.
                guard trusted, peerHello != nil, let injector else { return }
                let event = try SessionCodec.decodeInput(frame.payload)
                encoder?.noteInput() // keep feedback on the low-latency lane (typing)
                injector.handle(event)
            case .microphone:
                guard trusted, peerHello != nil else { return }
                let packet = try AudioPacket.decode(frame.payload, expectedChannels: SessionConstants.microphoneChannels)
                audio?.pushMicrophone(packet)
            case .video, .speaker, .camera:
                socket.close("protocol error: unexpected \(frame.header.stream) stream from client")
            }
        } catch {
            socket.close("protocol error: \(error)")
        }
    }

    private func handleControl(_ message: ControlMessage, socket: FramedSocket) throws {
        switch message {
        case .hello(let hello):
            guard peerHello == nil else { return socket.close("duplicate hello") }
            peerHello = hello
            helloArrived.signal()
        case .requestKeyframe:
            encoder?.requestKeyframe()
        case .ping(let value):
            send(.pong(value), on: socket)
        case .pong(let sent):
            let rtt = Double(clock_gettime_nsec_np(CLOCK_UPTIME_RAW) &- sent) / 1_000_000
            if Int.random(in: 0..<15) == 0 {
                Log.info(String(format: "control RTT %.2f ms, video dropped %d", rtt, socket.droppedVideoFrames))
            }
        case .bye(let reason):
            socket.close("client said bye: \(reason)")
        case .brightness(let value):
            iPadBrightness.withLock { $0 = value }
            let notify = onBrightnessChange
            DispatchQueue.main.async { notify?(value) }
        case .decodeFailed:
            Log.warn("iPad reports it cannot decode the video stream")
            handleDecodeFailure(socket: socket)
        case .streamConfig, .authHello, .authProof:
            socket.close("protocol error: unexpected \(message) from client")
        case .audioRoute(let speaker, let microphone):
            sessionStatus.withLock { $0.speaker = speaker; $0.microphone = microphone }
            guard let audio else { return }
            Log.info("audio route from iPad: speaker \(speaker), microphone \(microphone)")
            audioQueue.async {
                // Each direction independently: one failing must not block the
                // other, and audio failing never takes the display down (spec §7).
                do {
                    if speaker { try audio.startSpeaker() } else { audio.stopSpeaker() }
                } catch { Log.warn("speaker route not applied: \(error)") }
                do {
                    if microphone { try audio.startMicrophone() } else { audio.stopMicrophone() }
                } catch { Log.warn("microphone route not applied: \(error)") }
            }
        case .videoActive(let active):
            guard let hello = peerHello else { return }
            Log.info("iPad video \(active ? "resumed" : "paused (app in background)")")
            videoQueue.async { [self] in
                if active {
                    do { try startVideo(hello: hello, socket: socket) } catch {
                        Log.warn("video restart failed: \(error)")
                        socket.close("video restart failed: \(error)")
                    }
                } else {
                    stopVideo()
                    onState(.audioOnly(hello.deviceName))
                }
            }
        }
    }

    private func send(_ message: ControlMessage, on socket: FramedSocket) {
        if !socket.send(.control, payload: SessionCodec.encode(message)) && !socket.isClosed {
            Log.warn("control message not sent: \(message)")
        }
    }
}
