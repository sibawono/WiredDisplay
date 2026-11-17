#if os(macOS)
import AVFoundation
import CoreAudio
import Foundation

/// The two loopback devices published by WiredDisplayAudio.driver (D-017).
public enum WiredAudioDevice: String, CaseIterable, Sendable {
    /// Apps play here; the host records its loopback input and sends it to the iPad.
    case speaker = "dev.wireddisplay.audio.speaker"
    /// The host plays iPad microphone audio here; apps record its loopback input.
    case microphone = "dev.wireddisplay.audio.microphone"
}

public struct AudioDeviceInfo: Sendable, Equatable {
    public var id: AudioDeviceID
    public var name: String
    public var uid: String
    public var inputChannels: Int
    public var outputChannels: Int
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
                            outputChannels: channels(id, scope: kAudioObjectPropertyScopeOutput))
        }
    }

    public static func find(_ device: WiredAudioDevice) throws -> AudioDeviceID {
        guard let info = all().first(where: { $0.uid == device.rawValue }) else {
            throw Error.notInstalled(device.rawValue)
        }
        return info.id
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
