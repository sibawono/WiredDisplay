import Foundation
import os
import WDSession
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
    private let confirmPairing: @Sendable (SecureChannel.Peer) -> Bool
    private let lock = OSAllocatedUnfairLock(initialState: (controllers: [HostController](), states: [ObjectIdentifier: HostController.State]()))
    private let stopping = OSAllocatedUnfairLock(initialState: false)
    /// Main queue: a controller was added or changed state.
    var onChange: (@Sendable () -> Void)?
    /// Main queue: a controller was created (for per-iPad brightness keys).
    var onControllerAdded: (@Sendable (HostController) -> Void)?

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

    func start() {
        audioRouter.start()
        Thread.detachNewThread { [self] in watchDevices() }
    }

    func stop() {
        stopping.withLock { $0 = true }
        for controller in controllers { controller.stop() }
    }

    /// Every 2 s: a controller for each cabled device that has none yet.
    private func watchDevices() {
        while !stopping.withLock({ $0 }) {
            if let devices = try? UsbmuxConnection().listDevices() {
                let known = Set(controllers.compactMap(\.deviceSerial))
                for device in UsbmuxDevice.wiredOnly(devices) where !known.contains(device.serialNumber) {
                    add(serial: device.serialNumber)
                }
            }
            Thread.sleep(forTimeInterval: 2)
        }
    }

    private func add(serial: String) {
        let controller = HostController(options: options, deviceSerial: serial, audioRouter: audioRouter,
                                        confirmPairing: confirmPairing) { _ in }
        // The state closure above cannot see the controller; record states and notify here.
        controller.onStateRecorded = { [weak self, weak controller] state in
            guard let self, let controller else { return }
            self.lock.withLock { $0.states[ObjectIdentifier(controller)] = state }
            self.changed()
        }
        lock.withLock { $0.controllers.append(controller) }
        Log.info("fleet: serving cabled device \(serial.prefix(8))… (\(controllers.count) total)")
        let added = onControllerAdded
        DispatchQueue.main.async { added?(controller) }
        controller.start()
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
}
