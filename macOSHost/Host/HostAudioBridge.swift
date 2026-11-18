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
    private var speakerFifo: SpeakerFifo?

    func startSpeaker() throws {
        guard speakerProc == nil else { return }
        let device = try AudioDevices.find(.speakerTap)
        let frames = AudioDevices.setBufferFrameSize(device, frames: Self.ioBufferFrames)
        Log.info("audio: speaker capture from device \(device), IO buffer \(frames) frames, microphone TCC " +
                 "\(AVCaptureDevice.authorizationStatus(for: .audio).rawValue) (3 = authorized)")
        // The real-time IO thread only converts into a preallocated FIFO;
        // packets are built, encrypted and queued on a normal thread (audit
        // B-7: allocating, locking and encrypting on the IO thread risks
        // dropouts when the Mac is busy).
        let fifo = SpeakerFifo(channels: Int(SessionConstants.speakerChannels))
        var procID: AudioDeviceIOProcID?
        let status = AudioDeviceCreateIOProcIDWithBlock(&procID, device, nil, Self.makeSpeakerIOBlock(fifo: fifo))
        guard status == noErr, let procID else { throw AudioDevices.Error.coreAudio("create speaker IOProc", status) }
        fifo.startSender(send)
        let started = AudioDeviceStart(device, procID)
        guard started == noErr else {
            AudioDeviceDestroyIOProcID(device, procID)
            fifo.stopSender()
            throw AudioDevices.Error.coreAudio("start speaker IOProc", started)
        }
        speakerDevice = device
        speakerProc = procID
        speakerFifo = fifo
        Log.info("audio: speaker bridge started (iPad Speaker -> iPad, IOProc)")
        DispatchQueue.global().asyncAfter(deadline: .now() + 3) {
            Log.info("audio: speaker IO check after 3 s: \(fifo.ioCycles) IO cycles, \(fifo.overflows) overflows")
        }
    }

    func stopSpeaker() {
        guard let procID = speakerProc else { return }
        AudioDeviceStop(speakerDevice, procID)
        AudioDeviceDestroyIOProcID(speakerDevice, procID)
        speakerProc = nil
        speakerFifo?.stopSender()
        speakerFifo = nil
        Log.info("audio: speaker bridge stopped")
    }

    /// Converts each IO cycle's input (Float32, interleaved or not) into
    /// 16-bit stereo in the FIFO. No allocation, no blocking lock.
    private nonisolated static func makeSpeakerIOBlock(fifo: SpeakerFifo) -> AudioDeviceIOBlock {
        return { _, inputData, _, _, _ in
            let list = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inputData))
            guard let first = list.first, first.mData != nil else { return }
            fifo.write(list)
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
            // No array here: render callbacks must not allocate (audit C-5).
            let first = list.count > 0 ? list[0].mData?.assumingMemoryBound(to: Float.self) : nil
            let second = list.count > 1 ? list[1].mData?.assumingMemoryBound(to: Float.self) : nil
            buffer.pull(first, second, frames: Int(frameCount))
            return noErr
        }
    }
}

/// Single-producer (CoreAudio IO thread) / single-consumer (sender thread)
/// sample FIFO for the speaker bridge. The producer never allocates and only
/// try-locks: if the sender happens to hold the lock, that one IO cycle
/// (5 ms) is dropped and counted rather than blocking the IO thread.
final class SpeakerFifo: @unchecked Sendable {
    let channels: Int
    /// One second of audio: far more than the sender ever leaves behind.
    private let capacityFrames = 48_000
    private let storage: UnsafeMutablePointer<Int16>
    private var readFrame = 0, writeFrame = 0, count = 0
    /// Heap-allocated: an os_unfair_lock must not move (no `&property`).
    private let lock: UnsafeMutablePointer<os_unfair_lock> = {
        let pointer = UnsafeMutablePointer<os_unfair_lock>.allocate(capacity: 1)
        pointer.initialize(to: os_unfair_lock())
        return pointer
    }()
    private let wake = DispatchSemaphore(value: 0)
    private var running = false
    private var cycles = 0, dropped = 0

    init(channels: Int) {
        self.channels = channels
        storage = .allocate(capacity: capacityFrames * channels)
    }

    deinit {
        storage.deallocate()
        lock.deallocate()
    }

    var ioCycles: Int { os_unfair_lock_lock(lock); defer { os_unfair_lock_unlock(lock) }; return cycles }
    var overflows: Int { os_unfair_lock_lock(lock); defer { os_unfair_lock_unlock(lock) }; return dropped }

    /// IO thread.
    func write(_ list: UnsafeMutableAudioBufferListPointer) {
        guard os_unfair_lock_trylock(lock) else { return }
        cycles += 1
        let first = list[0]
        let interleaved = list.count == 1
        let sourceChannels = interleaved ? max(Int(first.mNumberChannels), 1) : 1
        let frames = Int(first.mDataByteSize) / (MemoryLayout<Float>.size * sourceChannels)
        if frames > capacityFrames - count {
            dropped += 1
        } else {
            for frame in 0..<frames {
                let base = writeFrame * channels
                for channel in 0..<channels {
                    let value: Float
                    if interleaved {
                        let floats = first.mData!.assumingMemoryBound(to: Float.self)
                        value = floats[frame * sourceChannels + min(channel, sourceChannels - 1)]
                    } else {
                        let buffer = list[min(channel, list.count - 1)]
                        value = buffer.mData.map { $0.assumingMemoryBound(to: Float.self)[frame] } ?? 0
                    }
                    storage[base + channel] = Int16((max(-1, min(1, value)) * 32767).rounded())
                }
                writeFrame = (writeFrame + 1) % capacityFrames
            }
            count += frames
        }
        os_unfair_lock_unlock(lock)
        if frames > 0 { wake.signal() }
    }

    /// Everything buffered so far, oldest first (sender thread).
    private func drain() -> [Int16] {
        os_unfair_lock_lock(lock)
        defer { os_unfair_lock_unlock(lock) }
        let frames = min(count, SessionConstants.maxAudioFramesPerPacket)
        guard frames > 0 else { return [] }
        var out = [Int16](repeating: 0, count: frames * channels)
        for index in 0..<frames {
            let source = ((readFrame + index) % capacityFrames) * channels
            for channel in 0..<channels { out[index * channels + channel] = storage[source + channel] }
        }
        readFrame = (readFrame + frames) % capacityFrames
        count -= frames
        return out
    }

    func startSender(_ send: @escaping @Sendable (AudioPacket) -> Void) {
        os_unfair_lock_lock(lock); running = true; os_unfair_lock_unlock(lock)
        let channels = UInt8(channels)
        let thread = Thread { [self] in
            while true {
                wake.wait()
                os_unfair_lock_lock(lock); let keepGoing = running; os_unfair_lock_unlock(lock)
                guard keepGoing else { return }
                while case let samples = drain(), !samples.isEmpty {
                    send(AudioPacket(channels: channels, samples: samples))
                }
            }
        }
        thread.qualityOfService = .userInteractive
        thread.name = "wireddisplay.speaker-sender"
        thread.start()
    }

    func stopSender() {
        os_unfair_lock_lock(lock); running = false; os_unfair_lock_unlock(lock)
        wake.signal()
    }
}
