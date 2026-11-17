import AVFoundation
import Foundation
import WDMacAudio

// Verifies WiredDisplayAudio.driver on the Mac alone (no iPad):
//
//   wd-audio-probe list
//       Lists audio devices; the two WiredDisplay devices must appear.
//   wd-audio-probe loopback speaker|microphone
//       Plays a 1 kHz tone into the device's OUTPUT for 2 s while recording
//       its INPUT, and checks the tone comes back (level + frequency).
//       Recording needs the Microphone permission for the calling app.

/// Outside top-level code so the render block is not main-actor isolated
/// (it runs on CoreAudio's real-time thread).
nonisolated func makeTone(format: AVAudioFormat, frequency: Double) -> AVAudioSourceNode {
    final class Phase: @unchecked Sendable { var value = 0.0 }
    let phase = Phase()
    return AVAudioSourceNode(format: format) { _, _, frameCount, bufferList in
        let buffers = UnsafeMutableAudioBufferListPointer(bufferList)
        for frame in 0..<Int(frameCount) {
            let value = Float(sin(phase.value) * 0.25)
            phase.value += 2 * .pi * frequency / format.sampleRate
            for buffer in buffers { buffer.mData?.assumingMemoryBound(to: Float.self)[frame] = value }
        }
        return noErr
    }
}

func fail(_ message: String, code: Int32 = 1) -> Never {
    FileHandle.standardError.write(Data(("error: " + message + "\n").utf8))
    exit(code)
}

let arguments = Array(CommandLine.arguments.dropFirst())
switch arguments.first {
case "list":
    for device in AudioDevices.all() {
        let mark = WiredAudioDevice(rawValue: device.uid) != nil ? "  <-- WiredDisplay" : ""
        print("id=\(device.id) in=\(device.inputChannels) out=\(device.outputChannels) \(device.name) [\(device.uid)]\(mark)")
    }
case "loopback":
    guard arguments.count == 2, let which = WiredAudioDevice.allCases.first(where: { "\($0)" == arguments[1] }) else {
        fail("usage: wd-audio-probe loopback speaker|microphone", code: 64)
    }
    let deviceID: AudioDeviceID
    do { deviceID = try AudioDevices.find(which) } catch { fail("\(error)", code: 2) }

    let player = AVAudioEngine()
    let recorder = AVAudioEngine()
    do {
        try AudioDevices.bind(player.outputNode, to: deviceID)
        try AudioDevices.bind(recorder.inputNode, to: deviceID)
    } catch { fail("\(error)", code: 3) }

    let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
    let frequency = 1000.0
    let tone = makeTone(format: format, frequency: frequency)
    player.attach(tone)
    player.connect(tone, to: player.mainMixerNode, format: format)

    final class Capture: @unchecked Sendable {
        let lock = NSLock()
        var samples: [Float] = []
    }
    let capture = Capture()
    let inputFormat = recorder.inputNode.inputFormat(forBus: 0)
    print("device \(deviceID) input format: \(inputFormat)")
    recorder.inputNode.installTap(onBus: 0, bufferSize: 4800, format: inputFormat) { buffer, _ in
        guard let channel = buffer.floatChannelData?[0] else { return }
        let chunk = Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
        capture.lock.withLock { capture.samples += chunk }
    }
    do {
        try recorder.start()
        try player.start()
    } catch { fail("engine start: \(error)", code: 4) }
    Thread.sleep(forTimeInterval: 2.0)
    player.stop()
    recorder.stop()

    let samples = capture.lock.withLock { capture.samples }
    // Skip the first 0.3 s (start-up), analyse the rest.
    let body = Array(samples.dropFirst(Int(inputFormat.sampleRate * 0.3)))
    guard !body.isEmpty else { fail("recorded nothing (Microphone permission missing?)", code: 5) }
    let rms = sqrt(body.reduce(0) { $0 + $1 * $1 } / Float(body.count))
    var crossings = 0
    for index in 1..<body.count where (body[index - 1] < 0) != (body[index] < 0) { crossings += 1 }
    let measured = Double(crossings) / 2 / (Double(body.count) / inputFormat.sampleRate)
    print(String(format: "recorded %d frames, RMS %.3f (tone 0.177 expected), frequency %.0f Hz (1000 expected)",
                 samples.count, rms, measured))
    let pass = rms > 0.1 && abs(measured - frequency) < 50
    print(pass ? "RESULT: PASS — \(which) loopback carries audio" : "RESULT: FAIL")
    exit(pass ? 0 : 6)
case "level":
    // Records the device INPUT for 5 s and prints the level every 0.5 s, e.g.
    // to see the iPad microphone arriving in "iPad Microphone".
    guard arguments.count == 2, let which = WiredAudioDevice.allCases.first(where: { "\($0)" == arguments[1] }) else {
        fail("usage: wd-audio-probe level speaker|microphone", code: 64)
    }
    let deviceID: AudioDeviceID
    do { deviceID = try AudioDevices.find(which) } catch { fail("\(error)", code: 2) }
    let recorder = AVAudioEngine()
    do { try AudioDevices.bind(recorder.inputNode, to: deviceID) } catch { fail("\(error)", code: 3) }
    final class Meter: @unchecked Sendable { let lock = NSLock(); var sum: Float = 0; var count = 0; var peak: Float = 0 }
    let meter = Meter()
    let format = recorder.inputNode.inputFormat(forBus: 0)
    recorder.inputNode.installTap(onBus: 0, bufferSize: 4800, format: format) { buffer, _ in
        guard let channel = buffer.floatChannelData?[0] else { return }
        meter.lock.withLock {
            for index in 0..<Int(buffer.frameLength) {
                meter.sum += channel[index] * channel[index]
                meter.peak = max(meter.peak, abs(channel[index]))
            }
            meter.count += Int(buffer.frameLength)
        }
    }
    do { try recorder.start() } catch { fail("engine start: \(error)", code: 4) }
    var loudest: Float = 0
    for step in 1...10 {
        Thread.sleep(forTimeInterval: 0.5)
        let (rms, peak) = meter.lock.withLock { () -> (Float, Float) in
            defer { meter.sum = 0; meter.count = 0; meter.peak = 0 }
            return (meter.count > 0 ? sqrt(meter.sum / Float(meter.count)) : 0, meter.peak)
        }
        loudest = max(loudest, rms)
        let bar = String(repeating: "#", count: min(40, Int(rms * 400)))
        print(String(format: "%4.1fs  RMS %.4f  peak %.3f  %@", Double(step) * 0.5, rms, peak, bar))
    }
    recorder.stop()
    print(loudest > 0.002 ? "RESULT: signal present on \(which)" : "RESULT: silence on \(which)")
default:
    fail("usage: wd-audio-probe list | loopback speaker|microphone | level speaker|microphone", code: 64)
}
