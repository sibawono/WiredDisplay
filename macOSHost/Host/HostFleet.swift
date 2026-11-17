import Foundation
import os
import WDSession
import WDUsbmux

/// Several iPads at once (D-041): one HostController per cabled device, each
/// with its own display, encoder and input. Global settings go to all of
/// them; audio goes to the first iPad that asks (one driver); the menu panel
/// shows the iPad in focus (the first one streaming).
final class HostFleet: @unchecked Sendable {
    let options: HostController.Options
    let audioRouter = AudioRouter()
    private let confirmPairing: @Sendable (SecureChannel.Peer) -> Bool
    private let lock = OSAllocatedUnfairLock(initialState: (controllers: [HostController](), states: [ObjectIdentifier: HostController.State]()))
    private var stopping = false
    /// Main queue: a controller was added or changed state.
    var onChange: (@Sendable () -> Void)?
    /// Main queue: a controller was created (for per-iPad brightness keys).
    var onControllerAdded: (@Sendable (HostController) -> Void)?

    init(options: HostController.Options, confirmPairing: @escaping @Sendable (SecureChannel.Peer) -> Bool) {
        self.options = options
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
        stopping = true
        for controller in controllers { controller.stop() }
    }

    /// Every 2 s: a controller for each cabled device that has none yet.
    private func watchDevices() {
        while !stopping {
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
                                        confirmPairing: confirmPairing) { [weak self] _ in self?.changed() }
        // The state closure above cannot see the controller; record states here.
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

    func setQuality(_ preset: QualityPreset) { controllers.forEach { $0.setQuality(preset) } }
    func setInputEnabled(_ enabled: Bool) { controllers.forEach { $0.setInputEnabled(enabled) } }
    func setRefreshFollowsIPad(_ follow: Bool) { controllers.forEach { $0.setRefreshFollowsIPad(follow) } }
    func setLocalCursor(_ enabled: Bool) { controllers.forEach { $0.setLocalCursor(enabled) } }
    func forgetDecodeLimits() { controllers.forEach { $0.forgetDecodeLimits() } }
}
