import AVFoundation
import Foundation
import os
import WDMacAudio
import WDSession

/// Bridges the WiredDisplayAudio loopback devices and the session (D-017):
/// - speaker: record "iPad Speaker Tap" (what Mac apps play into "iPad Speaker") via a CoreAudio IOProc
///   -> one PCM packet per ~5 ms IO cycle -> iPad
/// - microphone: iPad PCM packets -> jitter buffer -> play into "iPad Microphone Feed",
///   which apps record as "iPad Microphone" (D-032)
///
/// Each direction starts and stops alone.
/// Recording the loopback input needs the Microphone permission (TCC) for this
/// app. Methods are called from the session queue; render/tap callbacks run on
/// CoreAudio threads and only touch the jitter buffer and `send`.
final class HostAudioBridge: @unchecked Sendable {
    private var microphoneEngine: AVAudioEngine?
    // 30 ms target / 100 ms cap: the iPad now sends a packet every IO cycle.
    private let microphoneBuffer = AudioJitterBuffer(channels: Int(SessionConstants.microphoneChannels),
                                                     targetFrames: 1440, maxFrames: 4800)
    private let send: @Sendable (AudioPacket) -> Void
    /// Diagnostics: packets each way, logged periodically.
    private let counters = OSAllocatedUnfairLock(initialState: (sent: 0, received: 0, receivedFrames: 0))

    init(send: @escaping @Sendable (AudioPacket) -> Void) {
        let counters = counters
        self.send = { packet in
            send(packet)
            let sent = counters.withLock { $0.sent += 1; return $0.sent }
            if sent == 1 || sent % 5000 == 0 { Log.info("audio: speaker packets sent to iPad: \(sent)") }
        }
    }

    deinit { stopAll() }

    var isSpeakerRunning: Bool { speakerProc != nil }
    var isMicrophoneRunning: Bool { microphoneEngine != nil }

    // MARK: speaker (Mac -> iPad)

    /// IO buffer requested from CoreAudio for both bridges: 240 frames = 5 ms.
    /// Replaces AVAudioEngine taps, which delivered ~100 ms chunks (step 2).
    static let ioBufferFrames: UInt32 = 240

    private var speakerDevice: AudioDeviceID = 0
    private var speakerProc: AudioDeviceIOProcID?

    func startSpeaker() throws {
        guard speakerProc == nil else { return }
        let device = try AudioDevices.find(.speakerTap)
        let frames = AudioDevices.setBufferFrameSize(device, frames: Self.ioBufferFrames)
        let send = send
        let ioCalls = OSAllocatedUnfairLock(initialState: 0)
        Log.info("audio: speaker capture from device \(device), IO buffer \(frames) frames, microphone TCC " +
                 "\(AVCaptureDevice.authorizationStatus(for: .audio).rawValue) (3 = authorized)")
        var procID: AudioDeviceIOProcID?
        // Called on CoreAudio's real-time IO thread once per IO cycle with the
        // loopback input (what Mac apps play into "iPad Speaker").
        let status = AudioDeviceCreateIOProcIDWithBlock(&procID, device, nil, Self.makeSpeakerIOBlock(send: send, calls: ioCalls))
        guard status == noErr, let procID else { throw AudioDevices.Error.coreAudio("create speaker IOProc", status) }
        let started = AudioDeviceStart(device, procID)
        guard started == noErr else {
            AudioDeviceDestroyIOProcID(device, procID)
            throw AudioDevices.Error.coreAudio("start speaker IOProc", started)
        }
        speakerDevice = device
        speakerProc = procID
        Log.info("audio: speaker bridge started (iPad Speaker -> iPad, IOProc)")
        DispatchQueue.global().asyncAfter(deadline: .now() + 3) {
            Log.info("audio: speaker IO check after 3 s: \(ioCalls.withLock { $0 }) IO cycles")
        }
    }

    func stopSpeaker() {
        guard let procID = speakerProc else { return }
        AudioDeviceStop(speakerDevice, procID)
        AudioDeviceDestroyIOProcID(speakerDevice, procID)
        speakerProc = nil
        Log.info("audio: speaker bridge stopped")
    }

    /// Converts each IO cycle's input (Float32, interleaved or not) into one
    /// 16-bit stereo packet. Built outside any actor (real-time thread).
    private nonisolated static func makeSpeakerIOBlock(send: @escaping @Sendable (AudioPacket) -> Void,
                                                       calls: OSAllocatedUnfairLock<Int>) -> AudioDeviceIOBlock {
        let channels = Int(SessionConstants.speakerChannels)
        return { _, inputData, _, _, _ in
            calls.withLock { $0 += 1 }
            let list = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inputData))
            guard let first = list.first, let base = first.mData else { return }
            var samples: [Int16]
            if list.count == 1 {
                // Interleaved: one buffer carrying all channels.
                let sourceChannels = max(Int(first.mNumberChannels), 1)
                let frames = Int(first.mDataByteSize) / (MemoryLayout<Float>.size * sourceChannels)
                let floats = base.assumingMemoryBound(to: Float.self)
                samples = [Int16](repeating: 0, count: frames * channels)
                for frame in 0..<frames {
                    for channel in 0..<channels {
                        let value = floats[frame * sourceChannels + min(channel, sourceChannels - 1)]
                        samples[frame * channels + channel] = Int16((max(-1, min(1, value)) * 32767).rounded())
                    }
                }
            } else {
                // Deinterleaved: one buffer per channel.
                let frames = Int(first.mDataByteSize) / MemoryLayout<Float>.size
                let sources = (0..<channels).compactMap { index -> UnsafePointer<Float>? in
                    list[min(index, list.count - 1)].mData.map { UnsafePointer($0.assumingMemoryBound(to: Float.self)) }
                }
                guard sources.count == channels else { return }
                samples = PCM.interleave(sources, frames: frames)
            }
            guard !samples.isEmpty else { return }
            send(AudioPacket(channels: UInt8(channels), samples: samples))
        }
    }

    // MARK: microphone (iPad -> Mac)

    func startMicrophone() throws {
        guard microphoneEngine == nil else { return }
        let device = try AudioDevices.find(.microphoneFeed)
        let engine = AVAudioEngine()
        try AudioDevices.bind(engine.outputNode, to: device)
        AudioDevices.setBufferFrameSize(device, frames: Self.ioBufferFrames)
        microphoneBuffer.reset()
        let source = Self.makeSource(buffer: microphoneBuffer)
        engine.attach(source)
        engine.connect(source, to: engine.mainMixerNode,
                       format: AVAudioFormat(standardFormatWithSampleRate: SessionConstants.audioSampleRate, channels: 2))
        try engine.start()
        microphoneEngine = engine
        Log.info("audio: microphone bridge started (iPad -> iPad Microphone)")
    }

    func stopMicrophone() {
        guard let engine = microphoneEngine else { return }
        engine.stop()
        microphoneEngine = nil
        microphoneBuffer.reset()
        Log.info("audio: microphone bridge stopped; jitter stats \(microphoneBuffer.stats)")
    }

    /// From the network; cheap and thread-safe.
    func pushMicrophone(_ packet: AudioPacket) {
        microphoneBuffer.push(packet)
        let (count, frames) = counters.withLock { c -> (Int, Int) in
            c.received += 1
            c.receivedFrames += packet.frameCount
            return (c.received, c.receivedFrames)
        }
        if count == 1 || count % 2000 == 0 {
            let peak = packet.samples.map { abs(Int($0)) }.max() ?? 0
            Log.info("audio: microphone packets from iPad: \(count) (\(frames) frames, last peak \(peak)/32767, " +
                     "engine \(microphoneEngine != nil ? "running" : "NOT running"), jitter \(microphoneBuffer.stats))")
        }
    }

    func stopAll() {
        stopSpeaker()
        stopMicrophone()
    }

    /// Built outside any actor so the render block is not main-actor isolated.
    private nonisolated static func makeSource(buffer: AudioJitterBuffer) -> AVAudioSourceNode {
        let format = AVAudioFormat(standardFormatWithSampleRate: SessionConstants.audioSampleRate, channels: 2)!
        return AVAudioSourceNode(format: format) { _, _, frameCount, bufferList -> OSStatus in
            let list = UnsafeMutableAudioBufferListPointer(bufferList)
            let outputs = list.compactMap { $0.mData?.assumingMemoryBound(to: Float.self) }
            buffer.pull(into: outputs, frames: Int(frameCount))
            return noErr
        }
    }
}
