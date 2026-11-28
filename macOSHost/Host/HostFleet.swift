import Foundation
import os
import WDSession
import WDTransport
import WDUsbmux

/// Several iPads at once (D-041): one HostController per cabled device, each
/// with its own display, encoder and input. Global settings go to all of
/// them; audio goes to the first iPad that asks (one driver); the menu panel
/// shows the iPad in focus (the first one streaming).
final class HostFleet: @unchecked Sendable {
    /// Launch options, kept current with the menu's choices (input, quality)
    /// so an iPad plugged in later starts with what the user chose since,
    /// never with input that was switched off after launch (D-006).
    private let currentOptions: OSAllocatedUnfairLock<HostController.Options>
    var options: HostController.Options { currentOptions.withLock { $0 } }
    let audioRouter = AudioRouter()
    let cameraBridge = CameraBridge()
    private var pamBridge: PamBridgeServer?
    private let activeLockscreen = OSAllocatedUnfairLock<PamBridgeServer.LockscreenSession?>(initialState: nil)
    /// Suppresses rapid re-arm loops (e.g. a stale `WiredDisplayAuth:admin` mechanism in `authorizationhost`
    /// reconnecting every 500 ms and spamming Touch ID prompts on the iPad).
    private let adminLoopGuard = OSAllocatedUnfairLock<(lastEndedAt: TimeInterval, suppressedUntil: TimeInterval)>(
        initialState: (0, 0))
    private let confirmPairing: @Sendable (SecureChannel.Peer) -> Bool
    private let lock = OSAllocatedUnfairLock(initialState: (controllers: [HostController](), states: [ObjectIdentifier: HostController.State]()))
    private let stopping = OSAllocatedUnfairLock(initialState: false)
    /// Main queue: a controller was added or changed state.
    var onChange: (@Sendable () -> Void)?
    /// Main queue: a controller was created (for per-iPad brightness keys).
    var onControllerAdded: (@Sendable (HostController) -> Void)?
    /// Main queue: an unplugged idle controller was removed.
    var onControllerRemoved: (@Sendable (HostController) -> Void)?

    init(options: HostController.Options, confirmPairing: @escaping @Sendable (SecureChannel.Peer) -> Bool) {
        currentOptions = OSAllocatedUnfairLock(initialState: options)
        self.confirmPairing = confirmPairing
    }

    var controllers: [HostController] { lock.withLock { $0.controllers } }

    func state(of controller: HostController) -> HostController.State {
        lock.withLock { $0.states[ObjectIdentifier(controller)] } ?? .waitingForDevice
    }

    /// The iPad the menu shows: the first streaming, else the first one.
    var focus: HostController? {
        let all = controllers
        return all.first { $0.status.iPadName != nil } ?? all.first
    }

    static let pamAllowWiFiKey = "pamAllowWiFi"
    private let pamAllowWiFiLock = OSAllocatedUnfairLock<Bool>(
        initialState: UserDefaults.standard.bool(forKey: HostFleet.pamAllowWiFiKey))
    var pamAllowWiFi: Bool { pamAllowWiFiLock.withLock { $0 } }

    func setPamAllowWiFi(_ allow: Bool) {
        pamAllowWiFiLock.withLock { $0 = allow }
        UserDefaults.standard.set(allow, forKey: Self.pamAllowWiFiKey)
        changed()
    }

    func start() {
        audioRouter.start()
        cameraBridge.onStatusChange = { [weak self] _ in
            self?.changed()
        }
        cameraBridge.onNeedKeyframe = { [weak self] in
            self?.focus?.requestCameraKeyframe()
        }
        let bridge = PamBridgeServer(
            handler: { [weak self] request in
                guard let self else { return PamBridgeServer.Response(status: 2, signature: []) }
                let allowWiFi = self.pamAllowWiFi
                for controller in self.controllers {
                    if let response = controller.requestBiometricAuth(request, allowWiFi: allowWiFi) {
                        return response
                    }
                }
                return PamBridgeServer.Response(status: 2, signature: [])
            },
            onLockscreenStart: { [weak self] session in
                guard let self else { return }
                let now = ProcessInfo.processInfo.systemUptime
                if session.service == "admin" {
                    let suppressed: Bool = self.adminLoopGuard.withLock { guardState in
                        if now < guardState.suppressedUntil { return true }
                        if guardState.lastEndedAt > 0 && (now - guardState.lastEndedAt) < 5.0 {
                            guardState.suppressedUntil = now + 30.0
                            return true
                        }
                        return false
                    }
                    if suppressed {
                        Log.warn("pam: suppressed rapid repeated admin session #\(session.requestID) (cooldown active)")
                        return
                    }
                }
                self.activeLockscreen.withLock { $0 = session }
                let allowWiFi = self.pamAllowWiFi
                for controller in self.controllers {
                    controller.pushLockscreenChallenge(
                        requestID: session.requestID, service: session.service, username: session.username,
                        reason: session.reason, nonce: session.nonce, allowWiFi: allowWiFi
                    )
                }
            },
            onLockscreenEnd: { [weak self] requestID in
                guard let self else { return }
                let endedService: String? = self.activeLockscreen.withLock { current in
                    guard current?.requestID == requestID else { return nil }
                    let svc = current?.service
                    current = nil
                    return svc
                }
                if endedService == "admin" {
                    let now = ProcessInfo.processInfo.systemUptime
                    self.adminLoopGuard.withLock { $0.lastEndedAt = now }
                }
                if endedService != nil {
                    for controller in self.controllers {
                        controller.clearLockscreenChallenge()
                    }
                }
            }
        )
        bridge.start()
        pamBridge = bridge
        if options.transportMode.allowsWiFi && controllers.isEmpty {
            add(serial: nil)
        }
        Thread.detachNewThread { [self] in watchDevices() }
    }

    func stop() {
        stopping.withLock { $0 = true }
        pamBridge?.stop()
        pamBridge = nil
        for controller in controllers { controller.stop() }
    }

    /// Every 2 s: add a controller for each new cabled device (Apple usbmuxd or Android ADB),
    /// and remove idle controllers whose USB device has been absent for at least 10 s.
    private func watchDevices() {
        var lastSeen: [String: TimeInterval] = [:]
        while !stopping.withLock({ $0 }) {
            let now = ProcessInfo.processInfo.systemUptime
            var discoveredSerials: [String] = []
            if let devices = try? UsbmuxConnection().listDevices() {
                discoveredSerials.append(contentsOf: UsbmuxDevice.wiredOnly(devices).map(\.serialNumber))
            }
            let aoaDevices = AoaClient.listDevices()
            let approvedAoa = HostController.aoaApprovedSerials()
            for dev in aoaDevices where dev.inAccessoryMode || approvedAoa.contains(dev.serial) {
                discoveredSerials.append(dev.fleetSerial)
            }
            if let adbDevices = try? AdbClient.listDevices() {
                for dev in AdbDevice.wiredOnly(adbDevices) {
                    if !aoaDevices.contains(where: { $0.inAccessoryMode && $0.serial == dev.serial }) {
                        discoveredSerials.append(dev.fleetSerial)
                    }
                }
            }
            let present = Set(discoveredSerials)
            for serial in present { lastSeen[serial] = now }
            let known = Set(controllers.compactMap(\.deviceSerial))
            let unbound = controllers.first { $0.deviceSerial == nil }
            for serial in discoveredSerials where !known.contains(serial) {
                if let unbound {
                    switch state(of: unbound) {
                    case .waitingForDevice, .backingOff, .stopped:
                        if !options.transportMode.allowsWiFi {
                            remove(unbound)
                        }
                    case .connecting, .streaming, .paused, .audioOnly, .pairing:
                        // Skip only the specific USB device that the unbound controller is already serving.
                        if unbound.activeUSBSerial == serial { continue }
                    }
                }
                add(serial: serial)
            }
            if options.transportMode.allowsWiFi && !controllers.contains(where: { $0.deviceSerial == nil }) {
                add(serial: nil)
            }
            let stale = controllers.filter { controller in
                guard let serial = controller.deviceSerial, !present.contains(serial) else { return false }
                guard now - (lastSeen[serial] ?? 0) >= 10 else { return false }
                switch state(of: controller) {
                case .waitingForDevice, .backingOff, .stopped: return true
                case .connecting, .streaming, .paused, .audioOnly, .pairing: return false
                }
            }
            for controller in stale {
                if let serial = controller.deviceSerial { lastSeen.removeValue(forKey: serial) }
                remove(controller)
            }
            Thread.sleep(forTimeInterval: 2)
        }
    }

    /// Adds a controller unless one for `serial` (or another unbound one) already exists.
    /// Check and append happen under one lock: the watcher thread and the main thread both add (audit BUG-03).
    private func add(serial: String?) {
        let controller = HostController(options: options, deviceSerial: serial, audioRouter: audioRouter,
                                        cameraBridge: cameraBridge,
                                        confirmPairing: confirmPairing) { _ in }
        controller.onCameraStateChange = { [weak self] in self?.changed() }
        // The state closure above cannot see the controller; record states and notify here.
        controller.onStateRecorded = { [weak self, weak controller] state in
            guard let self, let controller else { return }
            self.lock.withLock { $0.states[ObjectIdentifier(controller)] = state }
            self.changed()
        }
        controller.onQualityChanged = { [weak self] preset in
            guard let self else { return }
            self.currentOptions.withLock { $0.chroma = preset.chroma; $0.tenBit = preset.tenBit }
            self.changed()
        }
        controller.onSessionReady = { [weak self] readyController in
            guard let self, let session = self.activeLockscreen.withLock({ $0 }),
                  session.service == "lockscreen" else { return }
            readyController.pushLockscreenChallenge(
                requestID: session.requestID, service: session.service, username: session.username,
                reason: session.reason, nonce: session.nonce, allowWiFi: self.pamAllowWiFi
            )
        }
        controller.onLockscreenAuthResponse = { [weak self] requestID, status, signature in
            guard let self, status == 0 else { return }
            if let session = self.activeLockscreen.withLock({ $0 }), session.requestID == requestID {
                session.resolve(PamBridgeServer.Response(status: status, signature: signature))
            }
        }
        let appended: Bool = lock.withLock {
            guard !$0.controllers.contains(where: { $0.deviceSerial == serial }) else { return false }
            $0.controllers.append(controller)
            return true
        }
        guard appended else { return }
        if let serial {
            Log.info("fleet: serving cabled device \(serial.prefix(8))… (\(controllers.count) total)")
        } else {
            Log.info("fleet: serving wireless/auto controller (\(controllers.count) total)")
        }
        let added = onControllerAdded
        DispatchQueue.main.async { added?(controller) }
        controller.start()
        changed()
    }

    private func remove(_ controller: HostController) {
        let removed: Bool = lock.withLock {
            guard let index = $0.controllers.firstIndex(where: { $0 === controller }) else { return false }
            $0.controllers.remove(at: index)
            $0.states.removeValue(forKey: ObjectIdentifier(controller))
            return true
        }
        guard removed else { return }
        controller.stop()
        Log.info("fleet: stopped idle controller for unplugged device \(controller.deviceSerial?.prefix(8) ?? "?")… (\(controllers.count) remaining)")
        let notify = onControllerRemoved
        DispatchQueue.main.async { notify?(controller) }
        changed()
    }

    private func changed() {
        let notify = onChange
        DispatchQueue.main.async { notify?() }
    }

    // MARK: settings for every iPad

    func setQuality(_ preset: QualityPreset) {
        UserDefaults.standard.set(preset.rawValue, forKey: QualityPreset.defaultsKey)
        currentOptions.withLock { $0.chroma = preset.chroma; $0.tenBit = preset.tenBit }
        controllers.forEach { $0.setQuality(preset) }
    }
    func setTransportMode(_ mode: TransportMode) {
        UserDefaults.standard.set(mode.rawValue, forKey: HostController.transportModeKey)
        currentOptions.withLock { $0.transportMode = mode }
        if mode.allowsWiFi && !controllers.contains(where: { $0.deviceSerial == nil }) {
            add(serial: nil)
        }
        controllers.forEach { $0.setTransportMode(mode) }
        changed()
    }
    func setInputEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: HostController.allowInputKey)
        currentOptions.withLock { $0.allowInput = enabled }
        controllers.forEach { $0.setInputEnabled(enabled) }
    }
    func setRefreshFollowsIPad(_ follow: Bool) {
        UserDefaults.standard.set(follow, forKey: HostController.refreshKey)
        controllers.forEach { $0.setRefreshFollowsIPad(follow) }
    }
    func setLocalCursor(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: HostController.localCursorKey)
        controllers.forEach { $0.setLocalCursor(enabled) }
    }
    func forgetDecodeLimits() {
        UserDefaults.standard.removeObject(forKey: HostController.decodeLimitsKey)
        controllers.forEach { $0.forgetDecodeLimits() }
    }
    func resetDecodeLimits() {
        UserDefaults.standard.removeObject(forKey: HostController.decodeLimitsKey)
        controllers.forEach { $0.resetDecodeLimits() }
    }
    /// "Keep the display on" / "Keep the Mac awake" (General tab).
    func setKeepAwake(display: Bool? = nil, mac: Bool? = nil) {
        if let display { UserDefaults.standard.set(display, forKey: HostController.keepDisplayAwakeKey) }
        if let mac { UserDefaults.standard.set(mac, forKey: HostController.keepMacAwakeKey) }
        controllers.forEach { $0.updateAwakeAssertions() }
    }
    /// "Play on Mac speakers too" + sync delay (Audio tab).
    func setBothSpeakers(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: HostController.bothSpeakersKey)
        controllers.forEach { $0.updateBothSpeakers() }
    }
    func setBothSpeakersDelayMs(_ delayMs: Double) {
        let clamped = min(max(delayMs, 0), HostController.maxBothSpeakersDelayMs)
        UserDefaults.standard.set(clamped, forKey: HostController.bothSpeakersDelayMsKey)
        controllers.forEach { $0.updateBothSpeakers() }
    }
    func setBothSpeakersBalance(_ balance: Double) {
        let clamped = min(max(balance, 0), HostController.maxBothSpeakersBalance)
        UserDefaults.standard.set(clamped, forKey: HostController.bothSpeakersBalanceKey)
        controllers.forEach { $0.updateBothSpeakers() }
    }

    func setCamera(enabled: Bool, centerStage: Bool) {
        focus?.setCamera(enabled: enabled, centerStage: centerStage)
        changed()
    }

    /// Opt-in or opt-out a specific USB-C Android device for AOA accessory mode.
    func setAndroidAoaApproved(serial: String, approved: Bool) {
        HostController.setAoaApproved(serial, approved: approved)
        if approved {
            let fleetSerial = "\(AoaClient.serialPrefix)\(serial)"
            if !controllers.contains(where: { $0.deviceSerial == fleetSerial }) {
                add(serial: fleetSerial)
            }
        }
        changed()
    }
}
