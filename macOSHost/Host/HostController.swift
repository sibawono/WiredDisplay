import CoreGraphics
import CoreMedia
import Foundation
import IOKit.pwr_mgt
import os
import WDHostCore
import WDMacAudio
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
        case .balanced: return "Balanced"
        case .pro: return "Pro"
        case .ultra: return "Ultra"
        case .highColor: return "High Color"
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
        /// Highest refresh the host offers; `--fps N` fixes it instead of
        /// following the iPad (ProMotion, D-036).
        var fps = 120
        var fpsOverride: Int?
        /// Diagnostics (D-036): run at this rate even above the iPad's own
        /// maximum, to test the high-refresh path on a 60 Hz iPad.
        var forceRefresh: Int?
        /// sRGB by default (BUG-033): the iPad renders P3-tagged frames as if
        /// sRGB (measured 29 % less saturation). `--color p3` stays experimental.
        var displayP3 = false
        /// Chroma path (BUG-034, D-022): hybrid by default (user test: smooth
        /// cursor and sharp colour); `--chroma 420|444|hybrid`.
        var chroma: ChromaMode = .hybrid
        /// 10-bit HEVC against gradient banding (BUG-035); `--depth 8|10`.
        var tenBit = true
        /// Default to native @2x so the desktop raster matches the iPad panel.
        /// `--space native|more|most`. All three stay selectable
        /// in System Settings › Displays.
        var space: VirtualDisplayController.Space = .native
        /// Transport selection: USB-C only (default), Automatic (USB-C preferred + Wi-Fi), or Wi-Fi only.
        var transportMode: TransportMode = .usbOnly
    }

    enum State: Equatable, Sendable {
        case waitingForDevice
        case connecting
        case streaming(String)
        /// Streaming, but the capture waits (the Mac's displays are asleep).
        case paused(String)
        case audioOnly(String)
        case backingOff(String)
        /// An unknown iPad wants to pair; the code is shown on both screens.
        case pairing(String)
        case stopped
    }

    static let transportModeKey = "transportMode"
    static var savedTransportMode: TransportMode {
        UserDefaults.standard.string(forKey: transportModeKey).flatMap(TransportMode.init(rawValue:)) ?? .usbOnly
    }

    /// USB serials of Android devices the user explicitly opted in for USB-C AOA mode.
    static let aoaApprovedSerialsKey = "aoaApprovedSerials"
    static func aoaApprovedSerials() -> Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: aoaApprovedSerialsKey) ?? [])
    }
    static func setAoaApproved(_ serial: String, approved: Bool) {
        var current = aoaApprovedSerials()
        if approved { current.insert(serial) } else { current.remove(serial) }
        UserDefaults.standard.set(Array(current).sorted(), forKey: aoaApprovedSerialsKey)
    }

    private let options: Options
    private let transportModeLock: OSAllocatedUnfairLock<TransportMode>
    var transportMode: TransportMode { transportModeLock.withLock { $0 } }

    func setTransportMode(_ mode: TransportMode) {
        let previous = transportModeLock.withLock { current -> TransportMode in
            defer { current = mode }
            return current
        }
        guard previous != mode else { return }
        Log.info("transport mode changed: \(previous.rawValue) -> \(mode.rawValue)")
        resetBackoff.withLock { $0 = true }
        runLoopWake.signal()
        queue.async { [self] in
            if let active = socket {
                if (active.transportKind == .wifi && !mode.allowsWiFi) ||
                   (active.transportKind == .usb && !mode.allowsUSB) {
                    active.close("transport mode changed to \(mode.rawValue)")
                }
            }
        }
    }
    private let queue = DispatchQueue(label: "wireddisplay.host.session")
    private let videoQueue = DispatchQueue(label: "wireddisplay.host.video")
    /// Audio engines start/stop here: starting one can block on a TCC prompt,
    /// which must never stall frames, input or video (BUG-024).
    private let audioQueue = DispatchQueue(label: "wireddisplay.host.audio")
    private let stopping = OSAllocatedUnfairLock(initialState: false)
    private let inputEnabled: OSAllocatedUnfairLock<Bool>
    /// Chroma path and bit depth used by the next encoder (live-switchable).
    private let quality: OSAllocatedUnfairLock<(chroma: ChromaMode, tenBit: Bool)>
    private let stateHandler: @Sendable (State) -> Void
    /// The fleet's record of this controller's state (D-041).
    var onStateRecorded: (@Sendable (State) -> Void)?
    /// Notifies the fleet when the iPad changes Quality so `HostFleet.options` stays in sync.
    var onQualityChanged: (@Sendable (QualityPreset) -> Void)?
    /// The USB serial currently served by this controller (non-nil while on a USB session).
    private let activeUSBSerialLock = OSAllocatedUnfairLock<String?>(initialState: nil)
    var activeUSBSerial: String? { activeUSBSerialLock.withLock { $0 } }
    /// Connected iPad's Secure Enclave P-256 public key (65 bytes X9.63), if enrolled for PAM.
    private let biometricKeyLock = OSAllocatedUnfairLock<[UInt8]?>(initialState: nil)
    var biometricPublicKey: [UInt8]? { biometricKeyLock.withLock { $0 } }
    private let pamPendingLock = OSAllocatedUnfairLock<(nextID: UInt32, waiters: [UInt32: (sem: DispatchSemaphore, response: PamBridgeServer.Response?)])>(initialState: (1, [:]))
    /// Called when a trusted session completes its Hello handshake (for pushing any active lockscreen challenge).
    var onSessionReady: (@Sendable (HostController) -> Void)?
    /// Called when the iPad responds to a long-lived Lock Screen biometric challenge (`requestID >= 0x8000_0001`).
    var onLockscreenAuthResponse: (@Sendable (UInt32, UInt8, [UInt8]) -> Void)?

    /// Sends a Lock Screen or Admin Touch ID / Face ID challenge to this iPad.
    func pushLockscreenChallenge(requestID: UInt32, service: String, username: String, reason: String, nonce: [UInt8], allowWiFi: Bool) {
        queue.async { [self] in
            guard trusted, let socket, !socket.isClosed else { return }
            if socket.transportKind == .wifi && !allowWiFi { return }
            send(.authChallenge(requestID: requestID, service: service, username: username,
                                reason: reason, nonce: nonce), on: socket)
        }
    }

    /// Tells this iPad to dismiss any displayed Lock Screen Unlock Mac pill.
    func clearLockscreenChallenge() {
        queue.async { [self] in
            guard trusted, let socket, !socket.isClosed else { return }
            send(.authChallenge(requestID: 0, service: "lockscreen-clear", username: "",
                                reason: "", nonce: [UInt8](repeating: 0, count: BiometricAuthMessage.nonceLength)),
                 on: socket)
        }
    }

    /// Sends a PAM Touch ID / Face ID challenge to this connected iPad and waits for its Secure Enclave signature.
    /// Returns nil immediately if this controller has no eligible trusted session.
    func requestBiometricAuth(_ request: PamBridgeServer.Request, allowWiFi: Bool = false) -> PamBridgeServer.Response? {
        let sem = DispatchSemaphore(value: 0)
        let reqID = pamPendingLock.withLock { state -> UInt32 in
            let id = state.nextID
            state.nextID &+= 1
            if state.nextID == 0 { state.nextID = 1 }
            state.waiters[id] = (sem, nil)
            return id
        }
        let sent: Bool = queue.sync {
            guard trusted, let socket, !socket.isClosed else { return false }
            if socket.transportKind == .wifi && !allowWiFi { return false }
            send(.authChallenge(requestID: reqID, service: request.service, username: request.username,
                                reason: request.reason, nonce: request.nonce), on: socket)
            return true
        }
        guard sent else {
            _ = pamPendingLock.withLock { $0.waiters.removeValue(forKey: reqID) }
            return nil
        }
        let waited = sem.wait(timeout: .now() + request.timeoutSeconds)
        let entry = pamPendingLock.withLock { $0.waiters.removeValue(forKey: reqID) }
        guard waited == .success, let response = entry?.response else {
            return PamBridgeServer.Response(status: 2, signature: [])
        }
        return response
    }

    private func onState(_ state: State) {
        stateHandler(state)
        onStateRecorded?(state)
    }
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
    private var socket: (any FramedTransport)?
    private var abrController: AdaptiveBitrateController?
    private var lastObservedVideoDrops = 0
    private var smoothedRTTMs: Double?
    private var peerHello: Hello?
    private var lastHeardUptime: TimeInterval = ProcessInfo.processInfo.systemUptime
    private var lastSentVolume: (level: Float, muted: Bool)?
    private var audio: HostAudioBridge?
    private static let cachedHostName: String = Host.current().localizedName ?? "Mac"
    private let helloArrived = DispatchSemaphore(value: 0)
    /// The client's proven identity, and whether WE trust it yet. Until then,
    /// control messages wait in `pendingControl` and media/input are dropped.
    private var verifiedPeer: SecureChannel.Peer?
    private struct PeerDecodeLimits {
        var fingerprint: String?
        /// Limits declared by the client in `Hello.codecs` (immutable for the session).
        var declared: DecodeLimits = []
        /// Limits learned from `.decodeFailed` during this session (cleared on Quality switch or Reset).
        var learned: DecodeLimits = []
        var effective: DecodeLimits { declared.union(learned) }
    }
    /// Formats the connected client cannot decode (D-031); learned limits stay session-scoped.
    private let peerLimits = OSAllocatedUnfairLock(initialState: PeerDecodeLimits())
    private var lastDecodeStepDown = Date.distantPast
    private var trusted = false
    private var pendingControl: [ControlMessage] = []
    /// Unknown control tags already logged this session (a newer iPad build).
    private var loggedUnknownControlTags: Set<UInt8> = []

    // Owned by `videoQueue`.
    private var video: VideoPipeline?

    init(options: Options, deviceSerial: String? = nil, audioRouter: AudioRouter = AudioRouter(),
         cameraBridge: CameraBridge = CameraBridge(),
         confirmPairing: @escaping @Sendable (SecureChannel.Peer) -> Bool,
         onState: @escaping @Sendable (State) -> Void) {
        self.options = options
        self.transportModeLock = OSAllocatedUnfairLock(initialState: options.transportMode)
        self.deviceSerial = deviceSerial
        self.audioRouter = audioRouter
        self.cameraBridge = cameraBridge
        self.confirmPairing = confirmPairing
        self.stateHandler = onState
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
        var iPadModel: String?
        var pixelSize: String?
        var pointSize: String?
        var displaySpace: VirtualDisplayController.Space?
        var displaySpaceError = false
        var refreshHz: Int?
        var codec: String?
        var encoding: String?
        var speaker = false
        var microphone = false
        var camera = false
        var cameraCenterStage = true
        var activeTransport: ActiveTransportKind?
        var streamingSince: Date?
    }

    private let sessionStatus = OSAllocatedUnfairLock(initialState: SessionStatus())
    var status: SessionStatus { sessionStatus.withLock { $0 } }

    /// The WiredDisplay screen while video runs (for brightness keys).
    private let currentDisplay = OSAllocatedUnfairLock<CGDirectDisplayID?>(initialState: nil)

    var canChangeDisplaySpace: Bool {
        currentDisplay.withLock { $0 }.map(VirtualDisplayController.canChangeSpace(on:)) ?? false
    }

    func setDisplaySpace(_ space: VirtualDisplayController.Space) {
        videoQueue.async { [self] in
            guard let pipeline = video, let hello = pipeline.hello,
                  pipeline.display.displayID == pipeline.captureID else { return }
            let applied = pipeline.display.setSpace(space, config: pipeline.config, hiDPI: hello.scale >= 2)
            sessionStatus.withLock { $0.displaySpaceError = !applied }
            if applied { followDisplayMode() }
            else { Log.warn("could not set WiredDisplay space to \(space.rawValue)") }
        }
    }

    /// Brightness keys belong to the iPad when it is the only display, or
    /// when the pointer is on it; otherwise they go to the display they are
    /// meant for (a DisplayLink monitor, a Sidecar iPad, …), D-036.
    var brightnessKeysTargetIPad: Bool {
        guard brightness != nil, let display = currentDisplay.withLock({ $0 }) else { return false }
        var count: UInt32 = 0
        CGGetActiveDisplayList(0, nil, &count)
        if count <= 1 { return true }
        let pointer = CGEvent(source: nil)?.location ?? .zero
        return CGDisplayBounds(display).contains(pointer)
    }

    // MARK: several iPads (D-041)

    /// A stable display serial per iPad: the first iPad ever seen keeps 1 (the
    /// identity WiredDisplay always used, so its arrangement and mode stay),
    /// later ones get 2, 3, …
    static func displaySerial(for device: String?) -> UInt32 {
        guard let device else { return 1 }
        let key = "displaySerials"
        var map = UserDefaults.standard.dictionary(forKey: key) as? [String: Int] ?? [:]
        if let known = map[device] { return UInt32(known) }
        let next = (map.values.max() ?? 0) + 1
        map[device] = next
        UserDefaults.standard.set(map, forKey: key)
        return UInt32(next)
    }

    /// Only one iPad can carry audio (one driver): the first to ask keeps it.
    private static let audioOwner = OSAllocatedUnfairLock<ObjectIdentifier?>(initialState: nil)
    private var ownsAudio: Bool { Self.audioOwner.withLock { $0 == ObjectIdentifier(self) } }

    private func claimAudio() -> Bool {
        Self.audioOwner.withLock { owner in
            if owner == nil { owner = ObjectIdentifier(self) }
            return owner == ObjectIdentifier(self)
        }
    }

    private func releaseAudio() {
        Self.audioOwner.withLock { if $0 == ObjectIdentifier(self) { $0 = nil } }
    }

    // MARK: local cursor (D-038)

    static let localCursorKey = "localCursor"
    private let localCursorEnabled = OSAllocatedUnfairLock(
        initialState: UserDefaults.standard.object(forKey: HostController.localCursorKey) as? Bool ?? true)
    var localCursor: Bool { localCursorEnabled.withLock { $0 } }
    private var cursorEcho: CursorEcho?

    /// On: the iPad draws the cursor (lower latency); off: it is in the video.
    func setLocalCursor(_ enabled: Bool) {
        localCursorEnabled.withLock { $0 = enabled }
        UserDefaults.standard.set(enabled, forKey: Self.localCursorKey)
        videoQueue.async { [self] in
            do { try restartEncoding() } catch {
                Log.warn("cursor mode switch failed: \(error)")
                queue.async { [self] in socket?.close("cursor mode switch failed: \(error)") }
            }
        }
    }

    /// Starts or stops the cursor stream to match the setting. On `videoQueue`.
    private func updateCursorEcho(_ pipeline: VideoPipeline) {
        cursorEcho?.stop()
        cursorEcho = nil
        guard let socket = pipeline.socket else { return }
        guard localCursor else {
            if !socket.isClosed {
                send(.cursor(x: 0, y: 0, visible: false), on: socket)
            }
            return
        }
        let display = pipeline.captureID != 0 ? pipeline.captureID : currentDisplay.withLock({ $0 })
        guard let display else { return }
        let echo = CursorEcho(displayID: display) { [weak self, weak socket] message in
            guard let self, let socket, !socket.isClosed else { return }
            self.send(message, on: socket)
        }
        echo.start()
        cursorEcho = echo
    }

    // MARK: refresh rate (D-036)

    static let refreshKey = "refreshFollowsIPad"
    private let followsIPadRefresh = OSAllocatedUnfairLock(
        initialState: UserDefaults.standard.object(forKey: HostController.refreshKey) as? Bool ?? true)
    var refreshFollowsIPad: Bool { followsIPadRefresh.withLock { $0 } }

    /// On: up to 120 Hz on ProMotion iPads; off: 60 Hz. Recreates the
    /// display (its refresh rate is part of its modes).
    func setRefreshFollowsIPad(_ follow: Bool) {
        let changed = followsIPadRefresh.withLock { current -> Bool in
            defer { current = follow }
            return current != follow
        }
        UserDefaults.standard.set(follow, forKey: Self.refreshKey)
        guard changed else { return }
        videoQueue.async { [self] in
            do { try restartVideo() } catch {
                Log.warn("refresh change failed: \(error)")
                queue.async { [self] in socket?.close("refresh change failed: \(error)") }
            }
        }
    }

    /// Recreates the display with the current settings; the session stays
    /// up and the iPad gets a new stream config. On `videoQueue`.
    private func restartVideo(hello newHello: Hello? = nil) throws {
        guard let pipeline = video, let hello = newHello ?? pipeline.hello, let socket = pipeline.socket else { return }
        Log.info("recreating the display")
        stopVideo()
        try startVideo(hello: hello, socket: socket)
    }

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
        let notify = onBrightnessChange
        DispatchQueue.main.async { notify?(value) }
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

    /// What the connected iPad cannot decode, for the menu; nil if nothing.
    var decodeLimitNote: String? {
        let limits = peerLimits.withLock { $0.effective }
        return limits.isEmpty ? nil : limits.summary
    }

    /// True when the active limit was learned dynamically (can be retried by the user).
    var canResetDecodeLimits: Bool {
        peerLimits.withLock { !$0.learned.isEmpty }
    }

    func forgetDecodeLimits() {
        UserDefaults.standard.removeObject(forKey: Self.decodeLimitsKey)
        peerLimits.withLock { $0.learned = [] }
    }

    /// Clears learned decode limits for the active session and retries the user's preset.
    func resetDecodeLimits() {
        UserDefaults.standard.removeObject(forKey: Self.decodeLimitsKey)
        let cleared = peerLimits.withLock { state -> Bool in
            guard !state.learned.isEmpty else { return false }
            state.learned = []
            return true
        }
        guard cleared else { return }
        Log.info("decode limits reset by the user; retrying selected quality")
        queue.async { [self] in lastDecodeStepDown = .distantPast }
        videoQueue.async { [self] in
            do { try restartEncoding() } catch {
                Log.warn("decode limit reset failed: \(error)")
                queue.async { [self] in socket?.close("decode limit reset failed: \(error)") }
            }
        }
    }

    /// The quality actually encoded: the user's preset, within the iPad's limits.
    private func effectiveQuality() -> (chroma: ChromaMode, tenBit: Bool) {
        var current = quality.withLock { $0 }
        let limits = peerLimits.withLock { $0.effective }
        if limits.contains(.no444) { current.chroma = .c420 }
        if limits.contains(.no10Bit) { current.tenBit = false }
        return current
    }

    /// The iPad says it cannot decode the stream: drop 4:4:4, then 10-bit
    /// for the current session, and restart the encoder. On `queue`.
    private func handleDecodeFailure(socket: any FramedTransport) {
        guard Date().timeIntervalSince(lastDecodeStepDown) > 3 else { return } // a switch is under way
        let current = effectiveQuality()
        let limits = peerLimits.withLock { $0.effective }
        guard let next = DecodeLimits.next(after: limits, uses444: current.chroma != .c420, tenBit: current.tenBit) else {
            Log.warn("iPad cannot decode 4:2:0 8-bit either; nothing left to step down to")
            return
        }
        lastDecodeStepDown = Date()
        peerLimits.withLock { state in
            state.learned.formUnion(next.subtracting(state.declared))
        }
        Log.warn("iPad cannot decode \(current.chroma.rawValue) \(current.tenBit ? 10 : 8)-bit; limiting session to \(next.summary)")
        videoQueue.async { [self] in
            do { try restartEncoding() } catch {
                Log.warn("format step-down failed: \(error)")
                queue.async { socket.close("format step-down failed: \(error)") }
            }
        }
    }

    /// Switches the encoder live (the display and the session stay up) and
    /// remembers the choice for the next launch. Explicitly picking a preset
    /// clears session-learned decode limits so the user can retry 4:4:4/10-bit.
    func setQuality(_ preset: QualityPreset) {
        quality.withLock { $0 = (preset.chroma, preset.tenBit) }
        UserDefaults.standard.set(preset.rawValue, forKey: QualityPreset.defaultsKey)
        let hadLearnedLimits = peerLimits.withLock { state -> Bool in
            let had = !state.learned.isEmpty
            state.learned = []
            return had
        }
        if hadLearnedLimits {
            UserDefaults.standard.removeObject(forKey: Self.decodeLimitsKey)
            Log.info("cleared session decode limits on explicit quality switch")
        }
        Log.info("quality set to \(preset.rawValue) (\(preset.chroma.rawValue), \(preset.tenBit ? 10 : 8)-bit)")
        queue.async { [self] in
            if hadLearnedLimits { lastDecodeStepDown = .distantPast }
            guard let idx = QualityPreset.allCases.firstIndex(of: preset),
                  trusted, let socket, !socket.isClosed else { return }
            send(.qualityPreset(UInt8(idx)), on: socket)
        }
        videoQueue.async { [self] in
            do { try restartEncoding() } catch {
                Log.warn("quality switch failed: \(error)")
                queue.async { [self] in socket?.close("quality switch failed: \(error)") }
            }
        }
    }

    /// Headphones in, iPad out (D-034). Shared by every iPad's controller;
    /// the fleet starts it.
    let audioRouter: AudioRouter
    let cameraBridge: CameraBridge
    /// The one cabled device this controller serves (several iPads, D-041);
    /// nil = any (single-iPad behaviour).
    let deviceSerial: String?
    /// The device of the current session (its display serial is derived from it).
    private var sessionDeviceSerial: String?
    /// Name and model of the connected iPad, read from lockdownd.
    private let sessionIdentity = OSAllocatedUnfairLock<(name: String, model: String?)?>(initialState: nil)

    /// The owner's device name when the app only knows the generic one.
    static func displayName(hello: String, identity: DeviceIdentity) -> String {
        let sent = hello.trimmingCharacters(in: .whitespacesAndNewlines)
        let generic = sent.isEmpty || sent == "iPad" || sent == identity.deviceClass
        if generic, let name = identity.name { return name }
        return sent.isEmpty ? "iPad" : sent
    }

    func start() {
        if deviceSerial == nil { audioRouter.start() }
        Thread.detachNewThread { [self] in runLoop() }
    }

    func stop() {
        stopping.withLock { $0 = true }
        wakeSignal.signal()
        runLoopWake.signal()
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

    // MARK: both speakers (Mac + iPad)

    static let bothSpeakersKey = "bothSpeakers"
    static let bothSpeakersDelayMsKey = "bothSpeakersDelayMs"
    static let bothSpeakersBalanceKey = "bothSpeakersBalance"
    static let defaultBothSpeakersDelayMs: Double = 45
    static let maxBothSpeakersDelayMs: Double = 120
    static let defaultBothSpeakersBalance: Double = 1.0
    static let maxBothSpeakersBalance: Double = 1.5
    static var bothSpeakers: Bool { UserDefaults.standard.bool(forKey: bothSpeakersKey) }
    static var bothSpeakersDelayMs: Double {
        let value = UserDefaults.standard.object(forKey: bothSpeakersDelayMsKey) as? Double ?? defaultBothSpeakersDelayMs
        return min(max(value, 0), maxBothSpeakersDelayMs)
    }
    static var bothSpeakersBalance: Double {
        let value = UserDefaults.standard.object(forKey: bothSpeakersBalanceKey) as? Double ?? defaultBothSpeakersBalance
        return min(max(value, 0), maxBothSpeakersBalance)
    }

    /// Updates the local Mac speaker mirror to match UserDefaults.
    func updateBothSpeakers() {
        let enabled = Self.bothSpeakers
        let delayMs = Self.bothSpeakersDelayMs
        let gain = Float(Self.bothSpeakersBalance)
        queue.async { [self] in
            guard let audio else { return }
            audioQueue.async { audio.setLocalMirror(enabled: enabled, delayMs: delayMs, gain: gain) }
        }
    }

    // MARK: staying awake while connected

    /// Default on: the Mac's displays do not sleep on their own while an iPad is connected.
    static let keepDisplayAwakeKey = "keepDisplayAwake"
    /// On: no idle system sleep while an iPad is connected, since the iPad cannot wake a sleeping Mac.
    /// A sleep the user asks for still happens.
    static let keepMacAwakeKey = "keepMacAwake"
    static var keepDisplayAwake: Bool { UserDefaults.standard.object(forKey: keepDisplayAwakeKey) as? Bool ?? true }
    static var keepMacAwake: Bool { UserDefaults.standard.object(forKey: keepMacAwakeKey) as? Bool ?? false }

    private struct AwakeState {
        /// The connected iPad's name while a session runs.
        var session: String?
        var display: IOPMAssertionID?
        var system: IOPMAssertionID?
    }
    private let awake = OSAllocatedUnfairLock(initialState: AwakeState())

    /// Holds or releases the two idle-sleep assertions to match the settings
    /// and whether an iPad is connected. Any thread.
    func updateAwakeAssertions() {
        let keepDisplay = Self.keepDisplayAwake, keepMac = Self.keepMacAwake
        awake.withLock { state in
            let active = state.session != nil
            let name = "WiredDisplay: \(state.session ?? "iPad") is connected" as CFString
            Self.hold(&state.display, active && keepDisplay, type: kIOPMAssertionTypePreventUserIdleDisplaySleep,
                      name: name, label: "display sleep")
            Self.hold(&state.system, active && keepMac, type: kIOPMAssertionTypePreventUserIdleSystemSleep,
                      name: name, label: "Mac sleep")
        }
    }

    private static func hold(_ id: inout IOPMAssertionID?, _ wanted: Bool, type: String, name: CFString, label: String) {
        if wanted, id == nil {
            var created = IOPMAssertionID(0)
            if IOPMAssertionCreateWithName(type as CFString, IOPMAssertionLevel(kIOPMAssertionLevelOn), name,
                                           &created) == kIOReturnSuccess {
                id = created
                Log.info("\(label) prevented while the iPad is connected")
            } else {
                Log.warn("could not prevent \(label)")
            }
        } else if !wanted, let held = id {
            IOPMAssertionRelease(held)
            id = nil
            Log.info("\(label) allowed again")
        }
    }

    // MARK: power, lock, sleep (docs/POWER_LOCK_WAKE.md)

    /// True from "will sleep" until "did wake": no session, no reconnects.
    private let systemAsleep = OSAllocatedUnfairLock(initialState: false)
    private let wakeSignal = DispatchSemaphore(value: 0)
    private let runLoopWake = DispatchSemaphore(value: 0)
    private let resetBackoff = OSAllocatedUnfairLock(initialState: false)
    /// Accessed on `audioQueue`: speaker tap paused during display sleep so
    /// coreaudiod releases its idle-sleep assertion (PLW-06).
    private var speakerPausedForDisplaySleep = false

    /// Main queue, from PowerMonitor (every controller of the fleet).
    func powerChanged(from old: PowerState, to new: PowerState) {
        if old.allowsInput && !new.allowsInput {
            // Nothing stays held while the Mac is locked, asleep or switched
            // away; the injector also drops every event until input is allowed.
            queue.async { [self] in injector?.releaseAll() }
        }
        if new.systemAsleep && !old.systemAsleep {
            systemAsleep.withLock { $0 = true }
            queue.async { [self] in socket?.close("Mac is going to sleep") }
        }
        if old.systemAsleep && !new.systemAsleep {
            systemAsleep.withLock { $0 = false }
            resetBackoff.withLock { $0 = true }
            wakeSignal.signal()
            runLoopWake.signal()
        }
        // PLW-06: pause the speaker IOProc while displays sleep so coreaudiod
        // does not block Mac idle sleep; resume seamlessly when displays wake.
        if new.displaysAsleep && !old.displaysAsleep {
            queue.async { [self] in
                guard let audio, let socket, !socket.isClosed, sessionStatus.withLock({ $0.speaker }) else { return }
                audioQueue.async {
                    guard audio.isSpeakerRunning else { return }
                    audio.stopSpeaker()
                    self.speakerPausedForDisplaySleep = true
                    Log.info("audio: paused speaker tap while displays sleep (PLW-06)")
                }
            }
        }
        if old.displaysAsleep && !new.displaysAsleep {
            queue.async { [self] in
                guard let audio, let socket, !socket.isClosed, sessionStatus.withLock({ $0.speaker }) else { return }
                audioQueue.async {
                    guard self.speakerPausedForDisplaySleep, !socket.isClosed else { return }
                    self.speakerPausedForDisplaySleep = false
                    do {
                        try audio.startSpeaker()
                        Log.info("audio: resumed speaker tap after display wake")
                    } catch {
                        Log.warn("audio: could not resume speaker tap after wake: \(error)")
                    }
                }
            }
        }
        if (old.displaysAsleep && !new.displaysAsleep) || (old.systemAsleep && !new.systemAsleep) {
            videoQueue.async { [self] in
                guard captureRestartPending, let socket = video?.socket else { return }
                captureRestartPending = false
                recoverCapture(attempt: 0, socket: socket)
            }
        }
        let visibleAgain = (old.locked && !new.locked) || (old.screensaver && !new.screensaver)
            || (old.displaysAsleep && !new.displaysAsleep)
        if visibleAgain && new.allowsInput {
            // Reconcile instead of assuming: the mode may have changed while
            // away, and a fresh keyframe replaces whatever the iPad holds.
            videoQueue.async { [self] in followDisplayMode() }
            queue.async { [self] in encoder?.requestKeyframe() }
        }
    }

    // MARK: capture loss and recovery (videoQueue)

    /// A capture stopped while the displays slept; restart it on wake.
    private var captureRestartPending = false

    /// ScreenCaptureKit stopped. The iPad gets a black frame at once (it must
    /// not keep showing the desktop while the Mac's displays are dark or
    /// locked), then the capture is restarted: now, with bounded backoff, or
    /// when the displays wake. Only a capture that cannot be restarted while
    /// the displays are on ends the session, as before.
    private func captureLost(_ reason: String, socket: any FramedTransport) {
        guard let pipeline = video, pipeline.socket === socket, !socket.isClosed else { return }
        // A capture that stops again right after each restart (it never
        // runs) must not restart without end: back off, then give up.
        let streak = captureFailures.failed(at: ProcessInfo.processInfo.systemUptime)
        guard streak < 4 else {
            Log.warn("capture stopped \(streak + 1) times right after recovering (\(reason)); ending the session")
            queue.async { socket.close("capture keeps stopping: \(reason)") }
            return
        }
        Log.warn("capture stopped (\(reason)); keeping the session and recovering the capture")
        pipeline.encoder?.encodeBlackFrame(width: Int(pipeline.config.pixelWidth), height: Int(pipeline.config.pixelHeight))
        if streak == 0 {
            recoverCapture(attempt: 0, socket: socket)
        } else {
            let delay = 0.5 * pow(2, Double(streak - 1)) // 0.5, 1, 2 s
            Log.info("capture stopped again soon after recovering; next restart in \(delay) s")
            videoQueue.asyncAfter(deadline: .now() + delay) { [weak self, weak socket] in
                guard let socket else { return }
                self?.recoverCapture(attempt: 0, socket: socket)
            }
        }
    }

    /// The panel state to return to after a pause (videoQueue).
    private var streamingState: State?

    /// Counts captures that stop again soon after a recovery (videoQueue).
    private var captureFailures = QuickFailureCounter(window: 2)

    /// `socket` is the session the recovery belongs to: a delayed retry must
    /// not restart the capture of a later session.
    private func recoverCapture(attempt: Int, socket expected: any FramedTransport) {
        guard let pipeline = video, let socket = pipeline.socket, socket === expected, !socket.isClosed else { return }
        let state = currentPowerState.withLock { $0 }
        if state.displaysAsleep || state.systemAsleep {
            captureRestartPending = true
            Log.info("capture recovery waits for the displays to wake")
            onState(.paused("Mac displays asleep"))
            return
        }
        do {
            try restartEncoding()
            captureFailures.recovered(at: ProcessInfo.processInfo.systemUptime)
            Log.info("capture recovered (attempt \(attempt + 1))")
            if let streamingState { onState(streamingState) }
        } catch {
            guard attempt < 4 else {
                Log.warn("capture could not be recovered: \(error)")
                queue.async { socket.close("capture could not be recovered: \(error)") }
                return
            }
            let delay = 0.5 * pow(2, Double(attempt)) // 0.5, 1, 2, 4 s
            Log.info("capture recovery attempt \(attempt + 1) failed (\(error)); retrying in \(delay) s")
            videoQueue.asyncAfter(deadline: .now() + delay) { [weak self, weak socket] in
                guard let socket else { return }
                self?.recoverCapture(attempt: attempt + 1, socket: socket)
            }
        }
    }

    /// Blocks the session thread while the Mac sleeps (bounded waits, so a
    /// missed signal only costs a minute, never a stuck controller).
    private func waitWhileAsleep() {
        guard systemAsleep.withLock({ $0 }) else { return }
        Log.info("session paused: Mac is asleep")
        while systemAsleep.withLock({ $0 }) && !isStopping { _ = wakeSignal.wait(timeout: .now() + 60) }
        Log.info("session resuming after wake")
    }

    // MARK: lifecycle

    private func runLoop() {
        var backoff: TimeInterval = 1
        var bonjour: BonjourBrowser?
        var aoaSwitchAttempted: [UInt32: Date] = [:]
        defer { bonjour?.stop() }

        while !isStopping {
            waitWhileAsleep()
            if resetBackoff.withLock({ value -> Bool in defer { value = false }; return value }) { backoff = 1 }

            let mode = transportMode
            let allowsWiFiHere = deviceSerial == nil && mode.allowsWiFi
            if allowsWiFiHere && bonjour == nil {
                let wake = runLoopWake
                let browser = BonjourBrowser { peers in
                    if !peers.isEmpty { wake.signal() }
                }
                browser.start()
                bonjour = browser
            } else if !allowsWiFiHere, let existing = bonjour {
                existing.stop()
                bonjour = nil
            }

            let started = Date()
            var sessionRan = false

            // Always prefer USB-C whenever allowed and available (Apple usbmuxd, Android AOA, or ADB).
            if mode.allowsUSB {
                let isAdbBound = deviceSerial.flatMap(AdbClient.stripPrefix) != nil
                let isAoaBound = deviceSerial.flatMap(AoaClient.stripPrefix) != nil
                let wired = (isAdbBound || isAoaBound) ? [] : pollWiredDevicesOnce()
                let mine = deviceSerial.map { serial in wired.filter { $0.serialNumber == serial } } ?? wired
                let aoaDevices = isAdbBound ? [] : pollAoaDevicesOnce()
                let adbDevices = isAoaBound ? [] : pollAdbDevicesOnce()

                if !mine.isEmpty {
                    let devices = UsbmuxDevice.preferring(serial: lastGoodSerial, in: mine)
                    onState(.connecting)
                    for device in devices where !isStopping && !systemAsleep.withLock({ $0 }) {
                        do {
                            try runSession(device)
                            sessionRan = true
                            onState(.backingOff("session ended"))
                        } catch SessionError.notListening {
                            continue
                        } catch {
                            sessionRan = true
                            Log.warn("USB session ended with error: \(error)")
                            onState(.backingOff("\(error)"))
                        }
                        break
                    }
                }
                if !sessionRan && !aoaDevices.isEmpty {
                    let activeLocations = Set(aoaDevices.map(\.locationID))
                    aoaSwitchAttempted = aoaSwitchAttempted.filter { activeLocations.contains($0.key) }
                    onState(.connecting)
                    for device in aoaDevices where !isStopping && !systemAsleep.withLock({ $0 }) {
                        if !device.inAccessoryMode {
                            // Opt-in only: never switch an Android phone out of MTP/charging unless user approved it.
                            guard Self.aoaApprovedSerials().contains(device.serial) else { continue }
                            if let last = aoaSwitchAttempted[device.locationID], Date().timeIntervalSince(last) < 30 {
                                continue
                            }
                            aoaSwitchAttempted[device.locationID] = Date()
                            do {
                                try AoaClient.switchToAccessory(device)
                                Log.info("AOA: switched approved Android device \(device.serial) to accessory mode; waiting for re-enumeration")
                                Thread.sleep(forTimeInterval: 1.5)
                            } catch {
                                Log.warn("AOA: switch failed for \(device.serial): \(error)")
                            }
                            continue
                        }
                        do {
                            try runAoaSession(device)
                            sessionRan = true
                            onState(.backingOff("Android USB AOA session ended"))
                        } catch {
                            sessionRan = true
                            Log.warn("Android USB AOA session ended with error: \(error)")
                            onState(.backingOff("\(error)"))
                        }
                        break
                    }
                }
                if !sessionRan && !adbDevices.isEmpty {
                    onState(.connecting)
                    for device in adbDevices where !isStopping && !systemAsleep.withLock({ $0 }) {
                        do {
                            try runAdbSession(device)
                            sessionRan = true
                            onState(.backingOff("Android USB session ended"))
                        } catch SessionError.notListening {
                            continue
                        } catch {
                            sessionRan = true
                            Log.warn("Android USB session ended with error: \(error)")
                            onState(.backingOff("\(error)"))
                        }
                        break
                    }
                }
                if !sessionRan && mode == .usbOnly {
                    if !mine.isEmpty || !aoaDevices.isEmpty || !adbDevices.isEmpty {
                        let total = mine.count + aoaDevices.count + adbDevices.count
                        let which = total == 1 ? "the device" : "any of the \(total) cabled devices"
                        noteWait("nothing listens on port \(SessionConstants.clientPort) on \(which) (WiredDisplay app not open or not in front?)")
                    } else {
                        if isStopping { break }
                        noteWait("waiting for device \(deviceSerial ?? "iPad or Android") on USB")
                    }
                    onState(.waitingForDevice)
                    _ = runLoopWake.wait(timeout: .now() + 1)
                    continue
                }
            }

            // Local Wi-Fi fallback or Wi-Fi-only mode (unbound controller only).
            if !sessionRan, allowsWiFiHere, let peers = bonjour?.peers, !peers.isEmpty {
                onState(.connecting)
                for peer in peers where !isStopping && !systemAsleep.withLock({ $0 }) {
                    do {
                        try runWiFiSession(peer)
                        sessionRan = true
                        onState(.backingOff("Wi-Fi session ended"))
                        break
                    } catch {
                        Log.warn("Wi-Fi session to \(peer.name) ended: \(error)")
                        // Try remaining discovered peers if this one failed before streaming.
                    }
                }
            }

            if !sessionRan {
                noteWait(mode == .wifiOnly
                         ? "waiting for WiredDisplay iPad on local Wi-Fi (_wireddisplay._tcp)"
                         : "waiting for iPad on USB-C or local Wi-Fi")
                onState(.waitingForDevice)
                _ = runLoopWake.wait(timeout: .now() + 1)
                continue
            }
            // Skip backoff sleep immediately if a mode switch, wake, or upgrade requested it.
            if resetBackoff.withLock({ value -> Bool in defer { value = false }; return value }) {
                backoff = 1
                continue
            }
            // Never reconnect in a tight loop (review finding 9).
            if Date().timeIntervalSince(started) > 10 { backoff = 1 }
            _ = runLoopWake.wait(timeout: .now() + backoff)
            backoff = min(backoff * 2, 8)
        }
        onState(.stopped)
    }

    private func pollWiredDevicesOnce() -> [UsbmuxDevice] {
        guard let connection = try? UsbmuxConnection(),
              let devices = try? connection.listDevices() else { return [] }
        let wired = UsbmuxDevice.wiredOnly(devices)
        if let serial = deviceSerial {
            return wired.filter { $0.serialNumber == serial }
        }
        return wired
    }

    private func pollAoaDevicesOnce() -> [AoaDevice] {
        let all = AoaClient.listDevices()
        if let serial = deviceSerial {
            guard let rawSerial = AoaClient.stripPrefix(serial) else { return [] }
            return all.filter { $0.serial == rawSerial }
        }
        return all
    }

    private func pollAdbDevicesOnce() -> [AdbDevice] {
        guard let devices = try? AdbClient.listDevices() else { return [] }
        let wired = AdbDevice.wiredOnly(devices)
        if let serial = deviceSerial {
            guard let rawSerial = AdbClient.stripPrefix(serial) else { return [] }
            return wired.filter { $0.serial == rawSerial }
        }
        return wired
    }

    /// Returns true only when a wired USB-C device (Apple or Android) has WiredDisplay listening on clientPort.
    private func hasListeningWiredDevice() -> Bool {
        for device in pollWiredDevicesOnce() {
            guard let probe = try? UsbmuxConnection() else { continue }
            if (try? probe.connect(to: device, port: SessionConstants.clientPort)) != nil {
                return true
            }
        }
        for device in pollAoaDevicesOnce() where device.inAccessoryMode {
            return true
        }
        for device in pollAdbDevicesOnce() {
            if let fd = try? AdbClient.connect(to: device.serial, clientPort: SessionConstants.clientPort) {
                Darwin.close(fd)
                return true
            }
        }
        return false
    }

    private enum SessionError: Swift.Error, CustomStringConvertible {
        case notListening
        case noHello
        case closedDuringSetup
        case incompatible(String)
        case notAuthenticated
        case pairingRejected
        case pairOverUSBFirst
        var description: String {
            switch self {
            case .notAuthenticated: return "iPad app not answering (in the background?)"
            case .pairingRejected: return "pairing with this iPad was not confirmed"
            case .pairOverUSBFirst: return "a new iPad must pair over USB-C first"
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
    /// Serial of the device the last session ran on (tried first next time).
    private var lastGoodSerial: String?
    private var lastWiredSeen: String?

    private func waitForWiredDevices() -> [UsbmuxDevice]? {
        onState(.waitingForDevice)
        while !isStopping {
            let seen: String
            do {
                let connection = try UsbmuxConnection()
                let devices = try connection.listDevices()
                let wired = UsbmuxDevice.wiredOnly(devices)
                if !wired.isEmpty {
                    // Logged only when the set of devices changes: alternating
                    // with "nothing listens" every second, it defeated
                    // noteWait's dedupe and wrote 2 lines/s (audit C-8).
                    let seenNow = wired.map { "device \($0.deviceID)" }.joined(separator: ", ")
                    if seenNow != lastWiredSeen {
                        lastWiredSeen = seenNow
                        Log.info("on USB: \(seenNow)")
                    }
                    return wired
                }
                lastWiredSeen = nil
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
        lastGoodSerial = device.serialNumber
        sessionDeviceSerial = device.serialNumber
        // Name and model from lockdownd, read while the handshake runs so a
        // slow answer never delays the picture (audit AUD-04).
        let identityResult = OSAllocatedUnfairLock<DeviceIdentity?>(initialState: nil)
        let identityRead = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .utility).async {
            let identity = Lockdown.readIdentity(of: device)
            identityResult.withLock { $0 = identity }
            identityRead.signal()
        }

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
            // At most 4 queued video frames (was 6: 100 ms at 60 Hz) when the
            // link backs up; beyond that the queue restarts at a keyframe, so a
            // stall costs less latency (audit B-6). Normally 0-1 are queued.
            descriptor: descriptor, sessionID: generator.next(), maxVideoFrames: 4, channel: channel,
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
        try runTransportSession(socket: socket, ended: ended, endReason: endReason, verified: verified,
                                identityResult: identityResult, identityRead: identityRead)
    }

    private func runAoaSession(_ device: AoaDevice) throws {
        let descriptor = try AoaClient.openBridge(device)
        Log.info("connected to Android device \(device.serial) over USB-C (AOA)")
        sessionDeviceSerial = device.fleetSerial
        let identityResult = OSAllocatedUnfairLock<DeviceIdentity?>(
            initialState: DeviceIdentity(name: nil, productType: device.product, deviceClass: "Android")
        )
        let identityRead = DispatchSemaphore(value: 0)
        identityRead.signal()

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
            descriptor: descriptor, sessionID: generator.next(), maxVideoFrames: 4, channel: channel,
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
        try runTransportSession(socket: socket, ended: ended, endReason: endReason, verified: verified,
                                identityResult: identityResult, identityRead: identityRead)
    }

    private func runAdbSession(_ device: AdbDevice) throws {
        let descriptor: Int32
        do {
            descriptor = try AdbClient.connect(to: device.serial, clientPort: SessionConstants.clientPort)
        } catch AdbClient.ClientError.failed {
            throw SessionError.notListening
        }
        Log.info("connected to Android device \(device.serial) over USB (ADB), port \(SessionConstants.clientPort)")
        sessionDeviceSerial = device.fleetSerial
        let identityResult = OSAllocatedUnfairLock<DeviceIdentity?>(
            initialState: DeviceIdentity(name: nil, productType: device.model, deviceClass: "Android")
        )
        let identityRead = DispatchSemaphore(value: 0)
        identityRead.signal()

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
            descriptor: descriptor, sessionID: generator.next(), maxVideoFrames: 4, channel: channel,
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
        try runTransportSession(socket: socket, ended: ended, endReason: endReason, verified: verified,
                                identityResult: identityResult, identityRead: identityRead)
    }

    private func runWiFiSession(_ bonjourPeer: BonjourPeer) throws {
        Log.info("connecting to \(bonjourPeer.name) over local Wi-Fi (\(bonjourPeer.id))")
        sessionDeviceSerial = "wifi-\(bonjourPeer.id)"

        let identityResult = OSAllocatedUnfairLock<DeviceIdentity?>(initialState: nil)
        let identityRead = DispatchSemaphore(value: 0)
        identityRead.signal() // Wi-Fi has no usbmuxd lockdownd lookup

        var generator = SystemRandomNumberGenerator()
        let ended = DispatchSemaphore(value: 0)
        let endReason = OSAllocatedUnfairLock(initialState: "")
        let verified = DispatchSemaphore(value: 0)
        let channel = SecureChannel(role: .host, identity: try trust.identity())
        let socket = NWFramedConnection(
            endpoint: bonjourPeer.endpoint, sessionID: generator.next(), maxVideoFrames: 4,
            channel: channel, transportKind: .wifi,
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
            }
        )
        try runTransportSession(socket: socket, ended: ended, endReason: endReason, verified: verified,
                                identityResult: identityResult, identityRead: identityRead)
    }

    private func runTransportSession(socket: any FramedTransport,
                                     ended: DispatchSemaphore,
                                     endReason: OSAllocatedUnfairLock<String>,
                                     verified: DispatchSemaphore,
                                     identityResult: OSAllocatedUnfairLock<DeviceIdentity?>,
                                     identityRead: DispatchSemaphore) throws {
        let audio = HostAudioBridge(
            macSpeaker: { [weak audioRouter] in audioRouter?.preferredMacSpeaker() },
            localMirrorEnabled: Self.bothSpeakers,
            localMirrorDelayMs: Self.bothSpeakersDelayMs,
            localMirrorGain: Float(Self.bothSpeakersBalance)
        ) { [weak socket] packet in
            socket?.send(.speaker, payload: packet.encoded())
        }
        let abr: AdaptiveBitrateController? = socket.transportKind == .wifi
            ? AdaptiveBitrateController(config: .wifi(ceilingMbps: options.bitrateMbps))
            : nil
        let notifyBrightnessNil = onBrightnessChange
        if let serial = sessionDeviceSerial, socket.transportKind == .usb {
            activeUSBSerialLock.withLock { $0 = serial }
        } else {
            activeUSBSerialLock.withLock { $0 = nil }
        }
        queue.sync {
            self.socket = socket
            self.audio = audio
            self.abrController = abr
            self.lastObservedVideoDrops = 0
            self.smoothedRTTMs = nil
            self.lastSentVolume = nil
            peerHello = nil
            verifiedPeer = nil
            trusted = false
            pendingControl = []
            loggedUnknownControlTags = []
            lastHeardUptime = ProcessInfo.processInfo.systemUptime
            iPadBrightness.withLock { $0 = nil }
            sessionStatus.withLock {
                $0 = SessionStatus()
                $0.activeTransport = socket.transportKind
            }
            sessionIdentity.withLock { $0 = nil }
            if ownsAudio { audioRouter.iPadRoute(speaker: false, microphone: false) }
            releaseAudio()
        }
        DispatchQueue.main.async { notifyBrightnessNil?(nil) }
        while helloArrived.wait(timeout: .now()) == .success {} // drain stale signals
        socket.start()

        let keepalive = DispatchSource.makeTimerSource(queue: queue)
        keepalive.schedule(deadline: .distantFuture)
        keepalive.resume()
        defer {
            socket.close("session teardown")
            keepalive.cancel()
            videoQueue.sync { stopVideo() }
            audioQueue.sync { audio.stopAll() }
            queue.sync {
                self.audio = nil
                self.socket = nil
                self.abrController = nil
                self.lastObservedVideoDrops = 0
                self.trusted = false
                self.pendingControl = []
                if ownsAudio { audioRouter.iPadRoute(speaker: false, microphone: false) }
                releaseAudio()
                let hadCamera = sessionStatus.withLock { s -> Bool in
                    let prev = s.camera
                    s.speaker = false
                    s.microphone = false
                    s.camera = false
                    return prev
                }
                if hadCamera { cameraBridge.stop() }
            }
            activeUSBSerialLock.withLock { $0 = nil }
            biometricKeyLock.withLock { $0 = nil }
            let pendingWaiters = pamPendingLock.withLock { state -> [DispatchSemaphore] in
                let sems = state.waiters.values.map(\.sem)
                for key in state.waiters.keys {
                    state.waiters[key]?.response = PamBridgeServer.Response(status: 2, signature: [])
                }
                return sems
            }
            pendingWaiters.forEach { $0.signal() }
            iPadBrightness.withLock { $0 = nil }
            let notifyEnd = onBrightnessChange
            DispatchQueue.main.async { notifyEnd?(nil) }
            Log.info("session cleaned up (\(socket.transportKind.rawValue)): \(endReason.withLock { $0 })")
            connectionCode.withLock { $0 = nil }
        }

        // 1. The iPad proves its identity (handshake, D-023).
        _ = verified.wait(timeout: .now() + 5)
        if isStopping || socket.isClosed { throw SessionError.closedDuringSetup }
        guard let peer = queue.sync(execute: { verifiedPeer }) else { throw SessionError.notAuthenticated }
        Log.info("iPad authenticated over \(socket.transportKind.rawValue): key \(peer.fingerprint), pairing code \(peer.pairingCode)")
        // Purge any legacy persisted decode limits so capable iPads are never permanently stuck.
        if UserDefaults.standard.object(forKey: Self.decodeLimitsKey) != nil {
            UserDefaults.standard.removeObject(forKey: Self.decodeLimitsKey)
        }
        peerLimits.withLock { $0 = PeerDecodeLimits(fingerprint: peer.fingerprint) }
        connectionCode.withLock { $0 = peer.pairingCode }

        let isWiFi = socket.transportKind == .wifi
        let pingInterval: TimeInterval = isWiFi ? 0.5 : 2.0
        var keepaliveTicks = 0
        keepalive.setEventHandler { [weak self, weak socket] in
            guard let self, let socket else { return }
            let now = ProcessInfo.processInfo.systemUptime
            if now - self.lastHeardUptime > 6 { return socket.close("no traffic from client for 6 s") }
            self.send(.ping(clock_gettime_nsec_np(CLOCK_UPTIME_RAW)), on: socket)
            keepaliveTicks += 1
            // Follow display mode and sync live Mac volume/mute back to the iPad (~1-2 s).
            if !isWiFi || keepaliveTicks % 2 == 0 {
                self.videoQueue.async { self.followDisplayMode() }
                if self.trusted {
                    let defaultOut = AudioDevices.defaultDevice(input: false)
                    if let level = AudioDevices.outputVolume(defaultOut) {
                        let muted = AudioDevices.outputMuted(defaultOut)
                        if let last = self.lastSentVolume {
                            if abs(last.level - level) >= 0.005 || last.muted != muted {
                                self.lastSentVolume = (level, muted)
                                self.send(.volume(level: level, muted: muted), on: socket)
                            }
                        } else {
                            self.lastSentVolume = (level, muted)
                            self.send(.volume(level: level, muted: muted), on: socket)
                        }
                    }
                }
            }
        }
        keepalive.schedule(deadline: .now() + pingInterval, repeating: pingInterval)

        // 2. Do WE trust it? Nothing from the iPad is acted on before this.
        try authorize(peer, over: socket.transportKind)
        if socket.isClosed { throw SessionError.closedDuringSetup }
        queue.sync {
            trusted = true
            let pending = pendingControl
            pendingControl = []
            for message in pending { try? handleControl(message, socket: socket) }
        }

        // 3. Hello both ways. The iPad sends its hello once ITS user trusts us.
        send(.hello(Hello(role: .host, deviceName: Self.cachedHostName, pixelWidth: 1, pixelHeight: 1,
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
        let readyCallback = onSessionReady
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            readyCallback?(self)
        }
        // Apply client-declared decode limits upfront (e.g. Android without 4:4:4 or 10-bit).
        var declaredLimits: DecodeLimits = []
        if hello.codecs.contains(.no444) { declaredLimits.insert(.no444) }
        if hello.codecs.contains(.no10Bit) { declaredLimits.insert(.no10Bit) }
        let immutableLimits = declaredLimits
        if !immutableLimits.isEmpty {
            peerLimits.withLock { $0.declared = immutableLimits }
            Log.info("client declared decode limits: \(immutableLimits.summary)")
        }
        // The iPad app can only send the generic "iPad" (iPadOS 16+), so the
        // name and model come from the device's lockdownd over the same USB.
        _ = identityRead.wait(timeout: .now() + 1)
        let identity = identityResult.withLock { $0 } ?? DeviceIdentity()
        let name = Self.displayName(hello: hello.deviceName, identity: identity)
        trust.update(peer.identityKey, name: name, model: identity.modelName)
        sessionIdentity.withLock { $0 = (name, identity.modelName) }
        Log.info("iPad identity: model \(identity.productType ?? "unknown") (\(identity.modelName ?? "-"))")

        // Idle-sleep assertions as chosen in the General tab, released when the session ends.
        awake.withLock { $0.session = name }
        updateAwakeAssertions()
        defer {
            awake.withLock { $0.session = nil }
            updateAwakeAssertions()
        }

        try videoQueue.sync { try startVideo(hello: hello, socket: socket) }
        ended.wait()
    }

    /// Pinned iPads pass. Over USB-C with no iPad paired yet, the first one is paired
    /// without asking so a headless Mac works without a screen (D-023). Over Wi-Fi,
    /// only paired iPads connect: anyone on the network could otherwise raise a pairing alert (audit SEC-01).
    private func authorize(_ peer: SecureChannel.Peer, over transport: ActiveTransportKind) throws {
        if trust.isTrusted(peer.identityKey) { return }
        if transport != .usb {
            Log.info("unknown iPad over \(transport.rawValue) (key \(peer.fingerprint)) refused: pair over USB-C first")
            throw SessionError.pairOverUSBFirst
        }
        if transport == .usb && trust.peers.isEmpty {
            try trust.trust(peer.identityKey, name: "iPad")
            Log.info("no iPad paired yet: paired this USB-C iPad on first use (key \(peer.fingerprint), code \(peer.pairingCode))")
            return
        }
        Log.info("unknown iPad over \(transport.rawValue) (key \(peer.fingerprint)); asking the user to confirm code \(peer.pairingCode)")
        onState(.pairing(peer.pairingCode))
        guard confirmPairing(peer) else {
            Log.warn("pairing with iPad \(peer.fingerprint) rejected or timed out")
            throw SessionError.pairingRejected
        }
        try trust.trust(peer.identityKey, name: "iPad")
        Log.info("iPad \(peer.fingerprint) paired by the user")
    }

    // MARK: video pipeline (on `videoQueue`)

    private func startVideo(hello: Hello, socket: any FramedTransport) throws {
        guard video == nil, !socket.isClosed else { return }
        let pipeline = VideoPipeline()
        // ProMotion (D-036): follow the iPad (120 Hz on iPad Pro) unless the
        // user chose 60 Hz or the command line fixed a rate.
        let cap = options.fpsOverride ?? (refreshFollowsIPad ? 120 : 60)
        let fps = options.forceRefresh ?? max(min(cap, Int(hello.maxRefreshHz)), 24)
        Log.info("refresh: iPad up to \(hello.maxRefreshHz) Hz, \(options.fpsOverride != nil ? "fixed" : refreshFollowsIPad ? "following the iPad" : "60 Hz chosen") -> \(fps) Hz")
        var config = try pipeline.display.create(for: hello, refreshHz: Double(fps), wideColor: options.displayP3,
                                                 space: Self.rememberedSpace(for: sessionDeviceSerial) ?? options.space,
                                                 serialNumber: Self.displaySerial(for: sessionDeviceSerial))
        guard let displayID = pipeline.display.displayID else {
            pipeline.display.destroy()
            throw SessionError.incompatible("display vanished")
        }
        currentDisplay.withLock { $0 = displayID }
        // Follow mirroring (user decision): if macOS or another tool put our
        // display in a mirror set, ScreenCaptureKit does not offer it; capture
        // the set's primary display instead, which is exactly what is shown.
        // The arrangement itself is never changed (D-015).
        Thread.sleep(forTimeInterval: 0.3) // let WindowServer apply a remembered arrangement
        let captureID = CGDisplayPrimaryDisplay(displayID)
        let source = CGDisplayBounds(captureID)
        if source.width > 0, source.height > 0 {
            config.pointWidth = UInt32(source.width.rounded())
            config.pointHeight = UInt32(source.height.rounded())
        }
        if captureID != displayID {
            Log.info("WiredDisplay is mirroring display \(captureID) (\(source.size)); capturing that display")
        }

        pipeline.config = config
        pipeline.captureID = captureID
        pipeline.fps = fps
        pipeline.hello = hello
        pipeline.socket = socket

        let inputEnabled = inputEnabled
        let injector = InputInjector(displayID: captureID, queue: queue,
                                     isEnabled: { inputEnabled.withLock { $0 } },
                                     power: { currentPowerState.withLock { $0 } })
        queue.sync { self.injector = injector }
        video = pipeline
        do {
            try startEncoding(pipeline)
        } catch {
            stopVideo()
            throw error
        }
        let codec = pipeline.config.codec
        let streaming = State.streaming("\(hello.deviceName) · \(config.pixelWidth)×\(config.pixelHeight) \(codec)")
        streamingState = streaming
        onState(streaming)
        let streamed = pipeline.config
        let matchedSpace = Self.displaySpace(for: streamed, hiDPI: hello.scale >= 2)
        sessionStatus.withLock {
            $0.iPadName = sessionIdentity.withLock { $0?.name } ?? hello.deviceName
            $0.iPadModel = sessionIdentity.withLock { $0?.model }
            $0.pixelSize = "\(streamed.pixelWidth) × \(streamed.pixelHeight)"
            $0.pointSize = "\(streamed.pointWidth) × \(streamed.pointHeight)"
            $0.displaySpace = matchedSpace
            $0.displaySpaceError = false
            $0.refreshHz = Int(streamed.refreshHz)
            $0.streamingSince = Date()
        }
        if let matchedSpace, let idx = VirtualDisplayController.Space.allCases.firstIndex(of: matchedSpace) {
            send(.displaySpace(UInt8(idx)), on: socket)
        }
        if let preset = qualityPreset, let idx = QualityPreset.allCases.firstIndex(of: preset) {
            send(.qualityPreset(UInt8(idx)), on: socket)
        }
        let defaultOut = AudioDevices.defaultDevice(input: false)
        if let vol = AudioDevices.outputVolume(defaultOut) {
            send(.volume(level: vol, muted: AudioDevices.outputMuted(defaultOut)), on: socket)
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
        let onUnit: @Sendable (SampleBuffers.EncodedFrame, UInt64) -> Void = { [weak self, weak socket] unit, sent in
            guard let self, let socket else { return }
            if let report = encodeMeter.tick(bytes: unit.annexB.count) { Log.info("video encoded: \(report)") }
            if socket.sendVideo(unit.annexB, isKeyframe: unit.isKeyframe, timestampNanos: sent) == .needKeyframe {
                self.queue.async {
                    self.encoder?.requestKeyframe()
                    self.encoder?.requestDropReplay()
                }
            }
        }
        var codec: VideoCodec = (options.codec == .hevc && hello.codecs.contains(VideoCodec.hevc)) ? .hevc : .h264
        let initialBitrate = queue.sync { self.abrController?.currentMbps } ?? options.bitrateMbps
        let encoder: VideoEncoder
        do {
            encoder = try VideoEncoder(codec: codec, width: Int(config.pixelWidth), height: Int(config.pixelHeight),
                                       fps: fps, bitrateMbps: initialBitrate,
                                       displayP3: options.displayP3, chroma: current.chroma,
                                       tenBit: current.tenBit, cursorInVideo: !localCursor, onUnit: onUnit)
        } catch where codec == .hevc {
            Log.warn("HEVC encoder unavailable (\(error)); falling back to H.264")
            codec = .h264
            encoder = try VideoEncoder(codec: codec, width: Int(config.pixelWidth), height: Int(config.pixelHeight),
                                       fps: fps, bitrateMbps: initialBitrate,
                                       displayP3: options.displayP3, chroma: current.chroma,
                                       tenBit: current.tenBit, cursorInVideo: !localCursor, onUnit: onUnit)
        }
        pipeline.config.codec = codec
        pipeline.encoder = encoder
        queue.sync { self.encoder = encoder }
        // Config before the first frame can be captured (D-042): the iPad
        // needs it to place the video, and frames must not overtake it.
        send(.streamConfig(pipeline.config), on: socket)
        let captureSize = Self.captureSize(for: pipeline, wantsBGRA: encoder.wantsBGRA)
        pipeline.captureSize = captureSize
        if Int(captureSize.width) != Int(config.pixelWidth) {
            Log.info("capture \(Int(captureSize.width))x\(Int(captureSize.height)) (HiDPI framebuffer) -> " +
                     "encode \(config.pixelWidth)x\(config.pixelHeight) with the area-filter downscale")
        }
        try pipeline.capture.start(displayID: pipeline.captureID, pixelWidth: Int(captureSize.width),
                                   pixelHeight: Int(captureSize.height), fps: fps, displayP3: options.displayP3,
                                   bgra: encoder.wantsBGRA, showsCursor: !localCursor,
                                   onFrame: { buffer, time, dirty, deliveredAt in
                                       if let report = captureMeter.tick() { Log.info("video captured: \(report)") }
                                       encoder.encode(buffer, presentationTime: time, dirtyFraction: dirty, captureTime: deliveredAt)
                                   },
                                   onStop: { [weak self, weak socket] reason in
                                       // Not fatal (docs/POWER_LOCK_WAKE.md): display sleep stops
                                       // ScreenCaptureKit ("no displays to capture"), measured to
                                       // arrive before screensDidSleep. Keep the session and
                                       // display; recover the capture instead.
                                       guard let self, let socket else { return }
                                       self.videoQueue.async { self.captureLost(reason, socket: socket) }
                                   })
        let chroma = current.chroma == .c420 ? "4:2:0" : current.chroma == .c444 ? "4:4:4" : "4:2:0 + 4:4:4"
        let codecName = codec == .hevc ? "HEVC" : "H.264"
        sessionStatus.withLock {
            $0.codec = codecName
            $0.encoding = "\(chroma) · \(current.tenBit ? 10 : 8)-bit"
        }
        updateCursorEcho(pipeline)
        Log.info("encoding \(codec) \(current.chroma.rawValue) \(current.tenBit ? 10 : 8)-bit, cursor \(localCursor ? "drawn on the iPad" : "in the video")")
    }

    /// The user can pick another "looks like" size in System Settings during a
    /// session; tell the iPad (its labels and scroll scale use the point size).
    /// The pixel stream does not change. On `videoQueue`.
    private func followDisplayMode() {
        guard let pipeline = video, let socket = pipeline.socket, let hello = pipeline.hello,
              pipeline.captureID != 0 else { return }
        let bounds = CGDisplayBounds(pipeline.captureID)
        let width = UInt32(bounds.width.rounded()), height = UInt32(bounds.height.rounded())
        guard width > 0, height > 0,
              width != pipeline.config.pointWidth || height != pipeline.config.pointHeight else { return }
        pipeline.config.pointWidth = width
        pipeline.config.pointHeight = height
        let space = Self.displaySpace(for: pipeline.config, hiDPI: hello.scale >= 2)
        if let space { Self.rememberSpace(space, for: sessionDeviceSerial) }
        sessionStatus.withLock {
            $0.pointSize = "\(width) × \(height)"
            $0.displaySpace = space
            $0.displaySpaceError = false
        }
        Log.info("display mode changed: now looks like \(width)x\(height) pt; telling the iPad")
        send(.streamConfig(pipeline.config), on: socket)
        if let space, let idx = VirtualDisplayController.Space.allCases.firstIndex(of: space) {
            send(.displaySpace(UInt8(idx)), on: socket)
        }
        // A new "looks like" mode has a new framebuffer size: capture it at
        // its own size again (own downscale).
        if let encoder = pipeline.encoder,
           Self.captureSize(for: pipeline, wantsBGRA: encoder.wantsBGRA) != pipeline.captureSize {
            do { try restartEncoding() } catch {
                Log.warn("capture resize after the mode change failed: \(error)")
                queue.async { socket.close("capture resize failed: \(error)") }
            }
        }
    }

    /// What to capture: the display's full HiDPI framebuffer when it is
    /// larger than the panel ("more/most space"), so the downscale to the
    /// panel happens in the encoder's area filter (ChromaConverter, or
    /// VideoToolbox's averaging downsampler on 4:4:4 lanes) instead of
    /// ScreenCaptureKit's scaler. Otherwise, or when the aspect differs
    /// (mirroring another display), or `--own-downscale off`, the panel size.
    private static func captureSize(for pipeline: VideoPipeline, wantsBGRA: Bool) -> CGSize {
        let panel = CGSize(width: Int(pipeline.config.pixelWidth), height: Int(pipeline.config.pixelHeight))
        let framebuffer = CGDisplayCopyDisplayMode(pipeline.captureID).map { CGSize(width: $0.pixelWidth, height: $0.pixelHeight) }
        return CaptureSizing.size(panel: panel, framebuffer: framebuffer, ownDownscale: VideoEncoder.ownDownscale, wantsBGRA: wantsBGRA)
    }

    /// The "looks like" space the user last chose for each iPad (System
    /// Settings or the panel). A display recreated after sleep, rotation or a
    /// replug comes back in it instead of the default (user report: after
    /// waking, the iPad was back at native and looked zoomed). `--space`
    /// on the command line still wins.
    private static let spacesKey = "displaySpaces"

    static func rememberedSpace(for device: String?) -> VirtualDisplayController.Space? {
        guard !CommandLine.arguments.contains("--space"), let device,
              let raw = (UserDefaults.standard.dictionary(forKey: spacesKey) as? [String: String])?[device] else { return nil }
        return VirtualDisplayController.Space(rawValue: raw)
    }

    private static func rememberSpace(_ space: VirtualDisplayController.Space, for device: String?) {
        guard let device else { return }
        var map = UserDefaults.standard.dictionary(forKey: spacesKey) as? [String: String] ?? [:]
        guard map[device] != space.rawValue else { return }
        map[device] = space.rawValue
        UserDefaults.standard.set(map, forKey: spacesKey)
        Log.info("remembered \(space.rawValue) space for this iPad")
    }

    private static func displaySpace(for config: StreamConfig, hiDPI: Bool) -> VirtualDisplayController.Space? {
        DisplaySpace.matching(points: CGSize(width: Int(config.pointWidth), height: Int(config.pointHeight)),
                              panelWidth: config.pixelWidth, panelHeight: config.pixelHeight, hiDPI: hiDPI)
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

    /// Rotates the virtual display in place when supported (preserving window placement),
    /// falling back to a full display rebuild if macOS rejects the mode update. On `videoQueue`.
    private func rotateVideo(hello: Hello) throws {
        guard let pipeline = video, let socket = pipeline.socket, !socket.isClosed,
              let displayID = pipeline.display.displayID,
              VirtualDisplayController.canChangeSpace(on: displayID) else {
            try restartVideo(hello: hello)
            return
        }
        let space = Self.rememberedSpace(for: sessionDeviceSerial) ?? options.space
        let serial = Self.displaySerial(for: sessionDeviceSerial)
        guard var newConfig = pipeline.display.resizeInPlace(for: hello, refreshHz: Double(pipeline.fps),
                                                             wideColor: options.displayP3, space: space,
                                                             serialNumber: serial) else {
            try restartVideo(hello: hello)
            return
        }
        pipeline.capture.stop()
        queue.sync {
            encoder?.invalidate()
            encoder = nil
        }
        pipeline.encoder = nil
        Thread.sleep(forTimeInterval: 0.15)
        let source = CGDisplayBounds(pipeline.captureID)
        if source.width > 0, source.height > 0 {
            newConfig.pointWidth = UInt32(source.width.rounded())
            newConfig.pointHeight = UInt32(source.height.rounded())
        }
        pipeline.config = newConfig
        pipeline.hello = hello
        try startEncoding(pipeline)
        let streamed = pipeline.config
        let matchedSpace = Self.displaySpace(for: streamed, hiDPI: hello.scale >= 2)
        sessionStatus.withLock {
            $0.pixelSize = "\(streamed.pixelWidth) × \(streamed.pixelHeight)"
            $0.pointSize = "\(streamed.pointWidth) × \(streamed.pointHeight)"
            $0.displaySpace = matchedSpace
            $0.displaySpaceError = false
        }
        let streaming = State.streaming("\(hello.deviceName) · \(streamed.pixelWidth)×\(streamed.pixelHeight) \(streamed.codec)")
        streamingState = streaming
        onState(streaming)
    }

    /// Releases input first, then capture, encoder and display. Idempotent.
    private func stopVideo() {
        guard let pipeline = video else { return }
        video = nil
        // Recovery state belongs to this session only.
        captureRestartPending = false
        captureFailures.reset()
        streamingState = nil
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
        cursorEcho?.stop()
        cursorEcho = nil
        currentDisplay.withLock { $0 = nil }
        sessionStatus.withLock {
            $0.pixelSize = nil; $0.pointSize = nil; $0.refreshHz = nil; $0.codec = nil; $0.encoding = nil
            $0.streamingSince = nil
            $0.displaySpace = nil
            $0.displaySpaceError = false
        }
        Log.info("video stopped")
    }

    private final class VideoPipeline {
        let display = VirtualDisplayController()
        let capture = CaptureEngine()
        var encoder: VideoEncoder?
        var config = StreamConfig(pixelWidth: 1, pixelHeight: 1, pointWidth: 1, pointHeight: 1, refreshHz: 60, codec: .h264)
        var captureID: CGDirectDisplayID = 0
        /// Pixels ScreenCaptureKit delivers (panel size, or the framebuffer).
        var captureSize = CGSize.zero
        var fps = 60
        var hello: Hello?
        weak var socket: (any FramedTransport)?
    }

    // MARK: frames (on `queue`)

    private func handle(_ frame: Frame, from origin: any FramedTransport) {
        // Frames from a connection that is no longer current are ignored.
        guard let socket, socket === origin, !socket.isClosed else { return }
        lastHeardUptime = ProcessInfo.processInfo.systemUptime
        do {
            switch frame.header.stream {
            case .control:
                if SessionCodec.hasUnknownControlTag(frame.payload) {
                    let tag = frame.payload[0]
                    if loggedUnknownControlTags.insert(tag).inserted {
                        Log.info("ignoring control message \(tag) from the iPad (a newer app version?)")
                    }
                    return
                }
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
            case .camera:
                guard trusted, peerHello != nil else { return }
                cameraBridge.decodeAndPush(
                    payload: frame.payload,
                    isKeyframe: frame.header.flags.contains(.keyframe),
                    timestampNanos: frame.header.timestampNanos
                )
            case .video, .speaker:
                socket.close("protocol error: unexpected \(frame.header.stream) stream from client")
            }
        } catch {
            socket.close("protocol error: \(error)")
        }
    }

    private func handleControl(_ message: ControlMessage, socket: any FramedTransport) throws {
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
            let ewma = smoothedRTTMs.map { $0 * 0.7 + rtt * 0.3 } ?? rtt
            smoothedRTTMs = ewma
            let totalDrops = socket.congestionDroppedVideoFrames
            let deltaDrops = max(0, totalDrops - lastObservedVideoDrops)
            lastObservedVideoDrops = totalDrops
            if var abr = abrController {
                if let nextMbps = abr.observe(rttMs: ewma, droppedFrames: deltaDrops,
                                              queueDepth: socket.queuedVideoFrames,
                                              now: ProcessInfo.processInfo.systemUptime) {
                    encoder?.updateBitrate(nextMbps)
                }
                abrController = abr
            }
            if Int.random(in: 0..<30) == 0 {
                Log.info(String(format: "control RTT %.2f ms (ewma %.2f), video dropped %d", rtt, ewma, socket.droppedVideoFrames))
            }
        case .bye(let reason):
            socket.close("client said bye: \(reason)")
        case .cursor, .cursorImage:
            socket.close("protocol error: unexpected \(message) from client")
        case .panelSize(let width, let height):
            // Portrait / landscape (D-039): rebuild the display for the new shape.
            guard var hello = peerHello, hello.pixelWidth != width || hello.pixelHeight != height else { return }
            hello.pixelWidth = width
            hello.pixelHeight = height
            peerHello = hello
            let updatedHello = hello
            Log.info("iPad rotated: panel now \(width)x\(height) (\(height > width ? "portrait" : "landscape"))")
            videoQueue.async { [self] in
                do { try rotateVideo(hello: updatedHello) } catch {
                    Log.warn("rotation rebuild failed: \(error)")
                    queue.async { socket.close("rotation rebuild failed: \(error)") }
                }
            }
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
            if speaker || microphone {
                guard claimAudio() else {
                    Log.info("audio stays with the other iPad; ignoring this one's audio route")
                    return
                }
            } else {
                guard ownsAudio else { return }
            }
            sessionStatus.withLock { $0.speaker = speaker; $0.microphone = microphone }
            audioRouter.iPadRoute(speaker: speaker, microphone: microphone)
            if !speaker && !microphone { releaseAudio() }
            guard let audio else { return }
            Log.info("audio route from iPad: speaker \(speaker), microphone \(microphone)")
            audioQueue.async {
                // The session may have ended since: never start audio for it.
                guard !socket.isClosed else { return }
                self.speakerPausedForDisplaySleep = false
                // Each direction independently: one failing must not block the
                // other, and audio failing never takes the display down (spec §7).
                do {
                    if speaker { try audio.startSpeaker() } else { audio.stopSpeaker() }
                } catch { Log.warn("speaker route not applied: \(error)") }
                do {
                    if microphone { try audio.startMicrophone() } else { audio.stopMicrophone() }
                } catch { Log.warn("microphone route not applied: \(error)") }
            }
        case .displaySpace(let raw):
            let spaces = VirtualDisplayController.Space.allCases
            guard spaces.indices.contains(Int(raw)) else { return }
            setDisplaySpace(spaces[Int(raw)])
        case .qualityPreset(let raw):
            let presets = QualityPreset.allCases
            guard presets.indices.contains(Int(raw)) else { return }
            let preset = presets[Int(raw)]
            setQuality(preset)
            onQualityChanged?(preset)
        case .volume(let level, let muted):
            let defaultOut = AudioDevices.defaultDevice(input: false)
            AudioDevices.setOutputVolume(defaultOut, level)
            AudioDevices.setOutputMuted(defaultOut, muted)
        case .sleepMac:
            let state = currentPowerState.withLock { $0 }
            guard !state.systemAsleep, state.sessionActive else {
                Log.info("sleepMac ignored (Mac \(state))")
                return
            }
            Log.info("sleepMac requested from iPad")
            let port = IOPMFindPowerManagement(kIOMainPortDefault)
            if port != 0 {
                let kr = IOPMSleepSystem(port)
                IOServiceClose(port)
                if kr != kIOReturnSuccess {
                    Log.warn("IOPMSleepSystem failed: 0x\(String(kr, radix: 16))")
                }
            }
        case .authResponse(let requestID, let status, let signature):
            if requestID >= 0x8000_0001 {
                onLockscreenAuthResponse?(requestID, status, signature)
                return
            }
            let sem: DispatchSemaphore? = pamPendingLock.withLock { state in
                guard var entry = state.waiters[requestID] else { return nil }
                entry.response = PamBridgeServer.Response(status: status, signature: signature)
                state.waiters[requestID] = entry
                return entry.sem
            }
            sem?.signal()
        case .biometricPublicKey(let key):
            biometricKeyLock.withLock { $0 = key }
            PamBridgeServer.recordBiometricPublicKey(key)
            Log.info("pam: received iPad biometric public key (fingerprint \(SecureChannel.fingerprint(key)))")
        case .authChallenge:
            socket.close("protocol error: unexpected authChallenge from client")
        case .cameraState(let enabled, let centerStage):
            sessionStatus.withLock {
                $0.camera = enabled
                $0.cameraCenterStage = centerStage
            }
            Log.info("camera state from iPad: enabled \(enabled), centerStage \(centerStage)")
            if enabled {
                cameraBridge.start()
            } else {
                cameraBridge.stop()
            }
            onCameraStateChange?()
        case .cameraRequestKeyframe:
            break
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

    /// Main queue: iPad camera enabled/Center Stage state changed.
    var onCameraStateChange: (@Sendable () -> Void)?

    func setCamera(enabled: Bool, centerStage: Bool) {
        queue.async { [self] in
            if enabled {
                cameraBridge.start()
            } else {
                cameraBridge.stop()
            }
            sessionStatus.withLock {
                $0.camera = enabled
                $0.cameraCenterStage = centerStage
            }
            if let socket, !socket.isClosed, trusted {
                send(.cameraState(enabled: enabled, centerStage: centerStage), on: socket)
            }
            onCameraStateChange?()
        }
    }

    func requestCameraKeyframe() {
        queue.async { [self] in
            guard let socket, !socket.isClosed, trusted else { return }
            send(.cameraRequestKeyframe, on: socket)
        }
    }

    private func send(_ message: ControlMessage, on socket: any FramedTransport) {
        if !socket.send(.control, payload: SessionCodec.encode(message)) && !socket.isClosed {
            Log.warn("control message not sent: \(message)")
        }
    }
}
