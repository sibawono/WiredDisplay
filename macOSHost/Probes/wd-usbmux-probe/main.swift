import Foundation
import WDProtocol
import WDUsbmux

// Phase 0 experiment E-04/E-05: prove Mac <-> iPad app bytes over the USB cable.
//
//   wd-usbmux-probe list
//       Lists devices known to usbmuxd with their connection type.
//   wd-usbmux-probe echo [--port 9000] [--megabytes 64] [--chunk-kb 256]
//       Connects through usbmuxd to a loopback TCP listener in the iPad app
//       (iPadOSClient/TransportProbe), sends framed random payloads, verifies
//       the echoed bytes, and reports round-trip latency and throughput.
//       Only USB-attached devices are eligible; Wi-Fi-synced ones are refused.
//   wd-usbmux-probe echo --negative-control-network <serial prefix> [...]
//       E-05b negative control ONLY: deliberately uses the Network-type entry
//       of that device, bypassing Wired Only, to show what the filter blocks.

func fail(_ message: String, code: Int32 = 1) -> Never {
    FileHandle.standardError.write(Data(("error: " + message + "\n").utf8))
    exit(code)
}

func nowNanos() -> UInt64 { clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW) }

let commandLine = Array(CommandLine.arguments.dropFirst())
guard let command = commandLine.first else { fail("usage: wd-usbmux-probe list | echo [--port N] [--megabytes N] [--chunk-kb N]", code: 64) }
let arguments = Array(commandLine.dropFirst())

@MainActor
func intValue(_ flag: String, default fallback: Int, range: ClosedRange<Int>) -> Int {
    guard let index = arguments.firstIndex(of: flag) else { return fallback }
    guard index + 1 < arguments.count, let parsed = Int(arguments[index + 1]), range.contains(parsed) else {
        fail("\(flag) expects an integer in \(range)", code: 64)
    }
    return parsed
}

func redacted(_ serial: String) -> String { String(serial.prefix(8)) + "…" }

/// `--negative-control-network <serial prefix>`: E-05b only. Requires an
/// explicit prefix of at least 8 characters so it can never pick an arbitrary
/// device. Unknown flags are rejected so a typo cannot silently drop it.
let knownFlags: Set<String> = ["--port", "--megabytes", "--chunk-kb", "--negative-control-network"]
for (index, argument) in arguments.enumerated() where argument.hasPrefix("--") {
    guard knownFlags.contains(argument) else { fail("unknown flag \(argument)", code: 64) }
    guard index + 1 < arguments.count else { fail("\(argument) needs a value", code: 64) }
}
let negativeControlSerialPrefix: String? = {
    guard let index = arguments.firstIndex(of: "--negative-control-network") else { return nil }
    let prefix = arguments[index + 1]
    guard prefix.count >= 8, !prefix.hasPrefix("--") else {
        fail("--negative-control-network needs a serial prefix of at least 8 characters", code: 64)
    }
    return prefix
}()

do {
    let connection = try UsbmuxConnection()
    let devices = try connection.listDevices()

    switch command {
    case "list":
        print("usbmuxd reports \(devices.count) device(s)")
        for device in devices {
            print("  id=\(device.deviceID) serial=\(redacted(device.serialNumber)) type=\(device.connectionType) "
                + "speed=\(device.connectionSpeed.map { "\($0 / 1_000_000) Mbit/s" } ?? "n/a")")
        }
    case "echo":
        let port = UInt16(intValue("--port", default: 9000, range: 1024...65535))
        let megabytes = intValue("--megabytes", default: 64, range: 1...4096)
        let chunk = intValue("--chunk-kb", default: 256, range: 1...4096) * 1024
        let device: UsbmuxDevice
        if let prefix = negativeControlSerialPrefix {
            // Negative control: deliberately use the Network-type (Wi-Fi) entry of
            // one specific device, to show the Wired Only filter is what keeps the
            // normal path on the cable. Never the default.
            guard let network = devices.first(where: {
                $0.connectionType == .network && $0.serialNumber.hasPrefix(prefix)
            }) else { fail("negative control: no Network-type device with serial prefix \(prefix)", code: 2) }
            device = network
            print("NEGATIVE CONTROL: using Network-type device, Wired Only policy bypassed for this run")
        } else {
            let wired = UsbmuxDevice.wiredOnly(devices)
            guard let usb = wired.first else { fail("no USB-attached device (Wired Only); plug in the iPad and trust this Mac", code: 2) }
            if wired.count > 1 { print("note: \(wired.count) USB devices; using id=\(usb.deviceID)") }
            device = usb
        }
        print("device id=\(device.deviceID) serial=\(redacted(device.serialNumber)) type=\(device.connectionType) "
            + "linkSpeed=\(device.connectionSpeed.map { "\($0 / 1_000_000) Mbit/s" } ?? "n/a")")

        do {
            if negativeControlSerialPrefix != nil {
                try connection.connectIgnoringWiredOnlyPolicyForNegativeControl(to: device, port: port)
            } else {
                try connection.connect(to: device, port: port)
            }
        } catch UsbmuxConnection.ClientError.refused(.connectionRefused) {
            fail("iPad refused port \(port): the cable path works, but the TransportProbe app is not listening (launch it and keep it in the foreground)", code: 3)
        }
        print("connected through usbmuxd to device loopback port \(port)")

        var generator = SystemRandomNumberGenerator()
        let sessionID = generator.next()
        var parser = FrameParser()
        var validator = SequenceValidator(sessionID: sessionID)
        var roundTrips: [Double] = []
        let total = megabytes * 1024 * 1024
        var sent = 0
        var sequence: UInt64 = 0
        var pool: [UInt8] = []
        let started = nowNanos()

        while sent < total {
            let size = min(chunk, total - sent)
            // Random data generated ONCE and rotated per frame: generating it
            // byte by byte per frame made the probe CPU-bound and reported a
            // throughput far below the link's (BUG-032).
            if pool.count < chunk {
                pool = [UInt8](repeating: 0, count: chunk + 8)
                pool.withUnsafeMutableBytes { raw in
                    for index in stride(from: 0, to: raw.count - 7, by: 8) {
                        raw.storeBytes(of: generator.next() as UInt64, toByteOffset: index, as: UInt64.self)
                    }
                }
            }
            let rotate = Int(sequence % 8)
            var payload = Array(pool[rotate..<(rotate + size)])
            payload[0] = UInt8(truncatingIfNeeded: sequence) // frames differ, so a stale echo cannot pass
            // Video stream type: the only one whose cap admits MiB-sized chunks.
            let frame = try Frame(stream: .video, sessionID: sessionID, sequence: sequence,
                                  timestampNanos: nowNanos(), payload: payload)
            let wire = try frame.encoded()
            let t0 = nowNanos()
            try parser.append(try connection.exchange(wire, expecting: wire.count))
            guard let echoed = try parser.next() else { fail("echo did not contain a complete frame", code: 4) }
            roundTrips.append(Double(nowNanos() - t0) / 1_000_000)
            try validator.accept(echoed.header)
            guard echoed == frame else { fail("echo mismatch at sequence \(sequence): data corrupted in transit", code: 4) }
            sent += size
            sequence += 1
        }

        let seconds = Double(nowNanos() - started) / 1_000_000_000
        let sorted = roundTrips.sorted()
        func percentile(_ p: Double) -> Double { sorted[min(sorted.count - 1, Int(Double(sorted.count) * p))] }
        // On-the-wire time only (excludes building and verifying frames).
        // During each exchange the frame travels out and back concurrently, so
        // this is the rate sustained in EACH direction at the same time.
        let wireSeconds = roundTrips.reduce(0, +) / 1000
        let perDirection = Double(sent) * 8 / 1_000_000 / wireSeconds
        print(String(format: "RESULT: %d MiB echoed and verified in %.2fs (%.2fs on the wire), %d frames of %d KiB",
                     megabytes, seconds, wireSeconds, sorted.count, chunk / 1024))
        print(String(format: "  throughput: %.0f Mbit/s in each direction simultaneously (%.0f Mbit/s total)",
                     perDirection, perDirection * 2))
        print(String(format: "  frame round trip ms: min %.2f  p50 %.2f  p95 %.2f  max %.2f", sorted.first ?? 0, percentile(0.5), percentile(0.95), sorted.last ?? 0))
    default:
        fail("unknown command \(command)", code: 64)
    }
} catch {
    fail("\(error)")
}
