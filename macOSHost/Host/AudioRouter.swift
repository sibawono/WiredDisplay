import CoreAudio
import Foundation
import os
import WDMacAudio

/// Automatic audio device switching (D-034, user request): headphones that
/// connect to the Mac (AirPods and other Bluetooth, USB-C earphones and
/// headsets, the headphone jack) become the output, and their microphone the
/// input; when they go away, sound returns to the iPad ("iPad Speaker" /
/// "iPad Microphone") if the iPad has that direction on.
///
/// It acts only on changes (a device appears or disappears, the iPad turns a
/// direction on), never when the user picks a device by hand, so it does not
/// fight manual choices. All work happens on its own serial queue.
final class AudioRouter: @unchecked Sendable {
    static let enabledKey = "autoSwitchAudio"
    static let microphoneKey = "autoSwitchMicrophone"

    private let queue = DispatchQueue(label: "wireddisplay.audio-router")
    private var known: [AudioDeviceID: AudioDeviceInfo] = [:]
    private var iPadSpeaker = false
    private var iPadMicrophone = false
    private var listening = false
    /// When headphones last arrived; macOS may move the input to their mic
    /// shortly after, which "output only" undoes within this window.
    private var headphonesArrived = Date.distantPast
    /// The last default input that was not a headset microphone.
    private var lastOtherInput: AudioDeviceID?
    /// The last default output / input that was not a WiredDisplay device:
    /// where sound goes back to when the iPad stops carrying it.
    private let lastRealOutput = OSAllocatedUnfairLock<AudioDeviceID?>(initialState: nil)
    private var lastRealInput: AudioDeviceID?

    var isEnabled: Bool {
        get { UserDefaults.standard.object(forKey: Self.enabledKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: Self.enabledKey) }
    }

    /// Off = "output only": headphones get the sound, the microphone stays
    /// on the iPad (or whatever it was). Keeps AirPods out of the lower-quality
    /// Bluetooth headset mode.
    var usesHeadsetMicrophone: Bool {
        get { UserDefaults.standard.object(forKey: Self.microphoneKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: Self.microphoneKey) }
    }

    func start() {
        queue.async { [self] in
            guard !listening else { return }
            listening = true
            known = Dictionary(uniqueKeysWithValues: AudioDevices.all().map { ($0.id, $0) })
            var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
                                                     mScope: kAudioObjectPropertyScopeGlobal,
                                                     mElement: kAudioObjectPropertyElementMain)
            AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, queue) { [weak self] _, _ in
                self?.devicesChanged()
            }
            var input = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice,
                                                   mScope: kAudioObjectPropertyScopeGlobal,
                                                   mElement: kAudioObjectPropertyElementMain)
            AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &input, queue) { [weak self] _, _ in
                self?.defaultInputChanged()
                self?.noteRealDefault(input: true)
            }
            var output = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                                    mScope: kAudioObjectPropertyScopeGlobal,
                                                    mElement: kAudioObjectPropertyElementMain)
            AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &output, queue) { [weak self] _, _ in
                self?.noteRealDefault(input: false)
            }
            defaultInputChanged()
            noteRealDefault(input: false)
            noteRealDefault(input: true)
            // Left over from a session that ended while the host was not
            // running: no iPad carries audio yet, so do not keep a dead
            // default. With switching on, the iPad gets it back on connect.
            if isEnabled {
                if !iPadSpeaker { restoreFromIPad(input: false) }
                if !iPadMicrophone { restoreFromIPad(input: true) }
            }
        }
    }

    /// Best physical Mac output device for "Both Speakers" mirroring (any thread).
    /// Prefers the last non-WiredDisplay output, then built-in speakers, then any real output.
    func preferredMacSpeaker() -> AudioDeviceID? {
        let devices = AudioDevices.all()
        let usable: (AudioDeviceInfo) -> Bool = { info in
            WiredAudioDevice(rawValue: info.uid) == nil && info.outputChannels > 0
        }
        let remembered = lastRealOutput.withLock { $0 }
        let target = devices.first { $0.id == remembered && usable($0) }
            ?? devices.first { usable($0) && $0.transport == kAudioDeviceTransportTypeBuiltIn }
            ?? devices.first(where: usable)
        return target?.id
    }

    /// Remembers the default device when it is a real one (not ours).
    private func noteRealDefault(input: Bool) {
        let current = AudioDevices.defaultDevice(input: input)
        guard current != 0, !isWired(current) else { return }
        if input { lastRealInput = current } else { lastRealOutput.withLock { $0 = current } }
    }

    private func isWired(_ id: AudioDeviceID) -> Bool {
        WiredAudioDevice.allCases.contains { (try? AudioDevices.find($0)) == id }
    }

    /// The iPad stopped carrying a direction (switched off, unplugged, app
    /// closed). The driver's devices never disappear, so macOS would keep a
    /// silent "iPad Speaker" / deaf "iPad Microphone" as the default: move it
    /// back to the device used before, or any real device. Applies even with
    /// automatic switching off, since a dead default helps nobody.
    private func restoreFromIPad(input: Bool) {
        let current = AudioDevices.defaultDevice(input: input)
        guard current != 0, isWired(current) else { return }
        let devices = AudioDevices.all()
        let usable: (AudioDeviceInfo) -> Bool = { info in
            WiredAudioDevice(rawValue: info.uid) == nil && (input ? info.inputChannels > 0 : info.outputChannels > 0)
        }
        let remembered = input ? lastRealInput : lastRealOutput.withLock { $0 }
        let target = devices.first { $0.id == remembered && usable($0) }
            ?? devices.first { usable($0) && $0.transport == kAudioDeviceTransportTypeBuiltIn }
            ?? devices.first(where: usable)
        guard let target else {
            Log.info("audio: the iPad stopped its \(input ? "microphone" : "speaker"); no other \(input ? "input" : "output") to switch to")
            return
        }
        setDefault(target.id, input: input, reason: "the iPad stopped its \(input ? "microphone" : "speaker")")
    }

    /// The host is quitting: nothing will carry "iPad Speaker" / "iPad
    /// Microphone" any more, so move the defaults off them now, before the
    /// process ends (audit C-4: the asynchronous session teardown did not
    /// always get there in time).
    func handBackBeforeQuit() {
        queue.sync {
            iPadSpeaker = false
            iPadMicrophone = false
            restoreFromIPad(input: false)
            restoreFromIPad(input: true)
        }
    }

    /// The iPad turned its speaker / microphone on or off (or disconnected).
    func iPadRoute(speaker: Bool, microphone: Bool) {
        queue.async { [self] in
            let speakerTurnedOn = speaker && !iPadSpeaker
            let microphoneTurnedOn = microphone && !iPadMicrophone
            let speakerTurnedOff = !speaker && iPadSpeaker
            let microphoneTurnedOff = !microphone && iPadMicrophone
            iPadSpeaker = speaker
            iPadMicrophone = microphone
            if speakerTurnedOff { restoreFromIPad(input: false) }
            if microphoneTurnedOff { restoreFromIPad(input: true) }
            guard isEnabled else { return }
            let devices = AudioDevices.all()
            // The iPad is the fallback: use it unless headphones are connected.
            if speakerTurnedOn, !devices.contains(where: isHeadphoneOutput) {
                select(.speaker, input: false, reason: "the iPad turned its speaker on")
            }
            if microphoneTurnedOn, !usesHeadsetMicrophone || !devices.contains(where: { isHeadsetInput($0, among: devices) }) {
                select(.microphone, input: true, reason: "the iPad turned its microphone on")
            }
        }
    }

    // MARK: on the queue

    private func devicesChanged() {
        let now = AudioDevices.all()
        let current = Dictionary(uniqueKeysWithValues: now.map { ($0.id, $0) })
        let added = now.filter { known[$0.id] == nil }
        let removed = known.values.filter { current[$0.id] == nil }
        known = current
        guard isEnabled else { return }

        if let headphones = added.first(where: isHeadphoneOutput) {
            headphonesArrived = Date()
            setDefault(headphones.id, input: false, reason: "\(headphones.name) connected")
            if !usesHeadsetMicrophone {
                // macOS may already have moved the input, or do it a moment later.
                defaultInputChanged()
                queue.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.defaultInputChanged() }
            }
        }
        if usesHeadsetMicrophone, let headset = added.first(where: { isHeadsetInput($0, among: added, sameChange: true) }) {
            setDefault(headset.id, input: true, reason: "\(headset.name) connected")
        }
        guard !removed.isEmpty else { return }
        let gone = removed.map(\.name).joined(separator: ", ")
        // Back to the iPad when the headphones were the reason it was not used.
        if removed.contains(where: isHeadphoneOutput), iPadSpeaker, !now.contains(where: isHeadphoneOutput) {
            select(.speaker, input: false, reason: "\(gone) disconnected")
        }
        if usesHeadsetMicrophone, removed.contains(where: { isHeadsetInput($0, among: removed, sameChange: true) }), iPadMicrophone,
           !now.contains(where: { isHeadsetInput($0, among: now) }) {
            select(.microphone, input: true, reason: "\(gone) disconnected")
        }
    }

    /// "Output only": macOS itself often makes the headset microphone the
    /// input right after the headphones connect (AirPods always do). Undo that
    /// within a few seconds of their arrival; later, a manual choice stands.
    private func defaultInputChanged() {
        let current = AudioDevices.defaultDevice(input: true)
        let devices = AudioDevices.all()
        guard let info = devices.first(where: { $0.id == current }) else { return }
        guard isHeadsetInput(info, among: devices) else {
            lastOtherInput = current
            return
        }
        guard isEnabled, !usesHeadsetMicrophone, Date().timeIntervalSince(headphonesArrived) < 5 else { return }
        if iPadMicrophone, let iPad = try? AudioDevices.find(.microphone) {
            setDefault(iPad, input: true, reason: "output only: keeping the iPad microphone")
        } else if let previous = lastOtherInput, devices.contains(where: { $0.id == previous }) {
            setDefault(previous, input: true, reason: "output only: keeping the previous microphone")
        }
    }

    private func select(_ device: WiredAudioDevice, input: Bool, reason: String) {
        guard let id = try? AudioDevices.find(device) else { return }
        setDefault(id, input: input, reason: reason)
    }

    private func setDefault(_ id: AudioDeviceID, input: Bool, reason: String) {
        guard AudioDevices.defaultDevice(input: input) != id else { return }
        let name = known[id]?.name ?? "device \(id)"
        if AudioDevices.setDefaultDevice(id, input: input) {
            Log.info("audio: default \(input ? "input" : "output") -> \(name) (\(reason))")
        } else {
            Log.warn("audio: could not make \(name) the default \(input ? "input" : "output")")
        }
    }

    /// USB audio that belongs to a dock or monitor (DisplayLink docks expose
    /// one) is not a pair of headphones: plugging in a dock must not move the
    /// sound away from the iPad (D-036).
    static func isDisplayOrDock(_ device: AudioDeviceInfo) -> Bool {
        let name = device.name.lowercased()
        return ["displaylink", "dock", "display", "monitor", "hdmi", "displayport", "thunderbolt"].contains { name.contains($0) }
    }

    /// Personal listening devices: Bluetooth (AirPods, headphones), USB
    /// (USB-C earphones, headsets, dongles) and the headphone jack. Not
    /// speakers, displays, virtual or aggregate devices.
    private func isHeadphoneOutput(_ device: AudioDeviceInfo) -> Bool {
        guard device.outputChannels > 0, WiredAudioDevice(rawValue: device.uid) == nil,
              !Self.isDisplayOrDock(device) else { return false }
        switch device.transport {
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE, kAudioDeviceTransportTypeUSB:
            return true
        case kAudioDeviceTransportTypeBuiltIn:
            return AudioDevices.isHeadphoneJack(device.id)
        default:
            return false
        }
    }

    /// A microphone that belongs to headphones, so a USB webcam or a lone USB
    /// microphone does not take over the input. macOS often publishes the
    /// headset's microphone as its own input-only device: AirPods as
    /// "<address>:input" next to "<address>:output", a USB-C dongle as
    /// "Headset" next to "CtoL Audio". It counts when it has an output itself,
    /// shares the UID prefix with a headphone output, or comes and goes in the
    /// same change as one (`among`).
    private func isHeadsetInput(_ device: AudioDeviceInfo, among others: [AudioDeviceInfo], sameChange: Bool = false) -> Bool {
        guard device.inputChannels > 0, WiredAudioDevice(rawValue: device.uid) == nil,
              !Self.isDisplayOrDock(device) else { return false }
        switch device.transport {
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE, kAudioDeviceTransportTypeUSB:
            break
        default:
            return false
        }
        if device.outputChannels > 0 { return true }
        let prefix = device.uid.split(separator: ":").first.map(String.init) ?? device.uid
        return others.contains { other in
            other.id != device.id && isHeadphoneOutput(other)
                && (other.uid.hasPrefix(prefix) || (sameChange && other.transport == device.transport))
        }
    }
}
