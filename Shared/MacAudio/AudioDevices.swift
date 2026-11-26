#if os(macOS)
import AudioToolbox
import AVFoundation
import CoreAudio
import Foundation

/// The devices published by WiredDisplayAudio.driver (D-017, D-032): two
/// loopback channels, each split into a visible one-way device for apps and a
/// hidden one for the host, so apps cannot pick them the wrong way round.
public enum WiredAudioDevice: String, CaseIterable, Sendable {
    /// Output only, visible: apps play here.
    case speaker = "dev.wireddisplay.audio.speaker"
    /// Input only, hidden: the host records what apps played into `speaker`.
    case speakerTap = "dev.wireddisplay.audio.speaker.tap"
    /// Input only, visible: apps record the iPad microphone here.
    case microphone = "dev.wireddisplay.audio.microphone"
    /// Output only, hidden: the host plays iPad microphone audio here.
    case microphoneFeed = "dev.wireddisplay.audio.microphone.feed"
}

public struct AudioDeviceInfo: Sendable, Equatable {
    public var id: AudioDeviceID
    public var name: String
    public var uid: String
    public var inputChannels: Int
    public var outputChannels: Int
    /// kAudioDeviceTransportType… (Bluetooth, USB, BuiltIn, Virtual, …).
    public var transport: UInt32 = 0
}

public enum AudioDevices {
    public enum Error: Swift.Error, CustomStringConvertible {
        case notInstalled(String)
        case coreAudio(String, OSStatus)

        public var description: String {
            switch self {
            case .notInstalled(let uid):
                return "audio device \(uid) not found: install WiredDisplayAudio.driver (scripts/build-audio-driver.sh)"
            case .coreAudio(let what, let status): return "CoreAudio \(what) failed: \(status)"
            }
        }
    }

    public static func all() -> [AudioDeviceInfo] {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr
        else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids) == noErr
        else { return [] }
        return ids.map { id in
            AudioDeviceInfo(id: id, name: string(id, kAudioObjectPropertyName) ?? "?",
                            uid: string(id, kAudioDevicePropertyDeviceUID) ?? "?",
                            inputChannels: channels(id, scope: kAudioObjectPropertyScopeInput),
                            outputChannels: channels(id, scope: kAudioObjectPropertyScopeOutput),
                            transport: uint(id, kAudioDevicePropertyTransportType))
        }
    }

    /// By UID, which also finds hidden devices (they are not in `all()`).
    public static func find(_ device: WiredAudioDevice) throws -> AudioDeviceID {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyTranslateUIDToDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var uid = device.rawValue as CFString
        var id = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = withUnsafePointer(to: &uid) { uidPointer in
            AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address,
                                       UInt32(MemoryLayout<CFString>.size), uidPointer, &size, &id)
        }
        guard status == noErr, id != kAudioObjectUnknown else { throw Error.notInstalled(device.rawValue) }
        return id
    }

    /// Points an AVAudioEngine's input or output node at a specific device.
    /// Must be called before the engine starts.
    public static func bind(_ node: AVAudioIONode, to device: AudioDeviceID) throws {
        guard let unit = node.audioUnit else { throw Error.coreAudio("node has no audio unit", -1) }
        var id = device
        let status = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                                          &id, UInt32(MemoryLayout<AudioDeviceID>.size))
        guard status == noErr else { throw Error.coreAudio("set current device", status) }
    }

    /// Requests a smaller IO buffer for this process's use of `device`
    /// (lower latency). The HAL clamps to the device's allowed range.
    @discardableResult
    public static func setBufferFrameSize(_ device: AudioDeviceID, frames: UInt32) -> UInt32 {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyBufferFrameSize,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var requested = frames
        _ = AudioObjectSetPropertyData(device, &address, 0, nil, UInt32(MemoryLayout<UInt32>.size), &requested)
        var actual: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        _ = AudioObjectGetPropertyData(device, &address, 0, nil, &size, &actual)
        return actual
    }

    /// The system default output (`input: false`) or input device.
    public static func defaultDevice(input: Bool) -> AudioDeviceID {
        uint(AudioObjectID(kAudioObjectSystemObject),
             input ? kAudioHardwarePropertyDefaultInputDevice : kAudioHardwarePropertyDefaultOutputDevice)
    }

    @discardableResult
    public static func setDefaultDevice(_ device: AudioDeviceID, input: Bool) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: input ? kAudioHardwarePropertyDefaultInputDevice : kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var id = device
        return AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil,
                                          UInt32(MemoryLayout<AudioDeviceID>.size), &id) == noErr
    }

    /// The built-in output's current data source is the headphone jack.
    public static func isHeadphoneJack(_ id: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDataSource,
                                                 mScope: kAudioObjectPropertyScopeOutput,
                                                 mElement: kAudioObjectPropertyElementMain)
        var source: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &source) == noErr else { return false }
        return source == 0x6864_706E // 'hdpn'
    }

    /// Reads an output device's scalar volume (0...1), trying VirtualMainVolume first.
    public static func outputVolume(_ id: AudioDeviceID) -> Float? {
        guard id != kAudioObjectUnknown else { return nil }
        var value: Float32 = 0
        var size = UInt32(MemoryLayout<Float32>.size)
        var virtual = AudioObjectPropertyAddress(mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
                                                 mScope: kAudioObjectPropertyScopeOutput,
                                                 mElement: kAudioObjectPropertyElementMain)
        if AudioObjectHasProperty(id, &virtual),
           AudioObjectGetPropertyData(id, &virtual, 0, nil, &size, &value) == noErr {
            return min(max(value, 0), 1)
        }
        for element: UInt32 in [kAudioObjectPropertyElementMain, 1, 2] {
            var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyVolumeScalar,
                                                  mScope: kAudioObjectPropertyScopeOutput,
                                                  mElement: element)
            if AudioObjectHasProperty(id, &addr),
               AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &value) == noErr {
                return min(max(value, 0), 1)
            }
        }
        return nil
    }

    /// Sets an output device's scalar volume (0...1).
    @discardableResult
    public static func setOutputVolume(_ id: AudioDeviceID, _ level: Float) -> Bool {
        guard id != kAudioObjectUnknown else { return false }
        var value = Float32(min(max(level, 0), 1))
        let size = UInt32(MemoryLayout<Float32>.size)
        var virtual = AudioObjectPropertyAddress(mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
                                                 mScope: kAudioObjectPropertyScopeOutput,
                                                 mElement: kAudioObjectPropertyElementMain)
        if AudioObjectHasProperty(id, &virtual),
           AudioObjectSetPropertyData(id, &virtual, 0, nil, size, &value) == noErr {
            return true
        }
        var applied = false
        for element: UInt32 in [kAudioObjectPropertyElementMain, 1, 2] {
            var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyVolumeScalar,
                                                  mScope: kAudioObjectPropertyScopeOutput,
                                                  mElement: element)
            var settable: DarwinBoolean = false
            if AudioObjectHasProperty(id, &addr),
               AudioObjectIsPropertySettable(id, &addr, &settable) == noErr, settable.boolValue,
               AudioObjectSetPropertyData(id, &addr, 0, nil, size, &value) == noErr {
                applied = true
                if element == kAudioObjectPropertyElementMain { break }
            }
        }
        return applied
    }

    /// Reads an output device's mute state.
    public static func outputMuted(_ id: AudioDeviceID) -> Bool {
        guard id != kAudioObjectUnknown else { return false }
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        for element: UInt32 in [kAudioObjectPropertyElementMain, 1] {
            var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyMute,
                                                  mScope: kAudioObjectPropertyScopeOutput,
                                                  mElement: element)
            if AudioObjectHasProperty(id, &addr),
               AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &value) == noErr {
                return value != 0
            }
        }
        return false
    }

    /// Sets an output device's mute state.
    @discardableResult
    public static func setOutputMuted(_ id: AudioDeviceID, _ muted: Bool) -> Bool {
        guard id != kAudioObjectUnknown else { return false }
        var value: UInt32 = muted ? 1 : 0
        let size = UInt32(MemoryLayout<UInt32>.size)
        var applied = false
        for element: UInt32 in [kAudioObjectPropertyElementMain, 1, 2] {
            var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyMute,
                                                  mScope: kAudioObjectPropertyScopeOutput,
                                                  mElement: element)
            var settable: DarwinBoolean = false
            if AudioObjectHasProperty(id, &addr),
               AudioObjectIsPropertySettable(id, &addr, &settable) == noErr, settable.boolValue,
               AudioObjectSetPropertyData(id, &addr, 0, nil, size, &value) == noErr {
                applied = true
                if element == kAudioObjectPropertyElementMain { break }
            }
        }
        return applied
    }

    private static func uint(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> UInt32 {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr else { return 0 }
        return value
    }

    private static func string(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }

    private static func channels(_ id: AudioObjectID, scope: AudioObjectPropertyScope) -> Int {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamConfiguration, mScope: scope,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, raw) == noErr else { return 0 }
        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }
}
#endif
