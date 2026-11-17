#if os(macOS)
import Foundation
import os
import XCTest
@testable import WDUsbmux

/// A local AF_UNIX server for exactly one client, driven by a handler closure.
/// The accept loop and all handler I/O poll with a short timeout and observe a
/// stop flag, and `deinit` waits for the thread before closing descriptors, so
/// a late thread can never accept on a recycled fd number (review finding 5).
final class UnixPeer: @unchecked Sendable {
    struct IO: Sendable {
        let fd: Int32
        let shouldStop: @Sendable () -> Bool

        /// Reads up to `max` bytes; nil on EOF, error or stop.
        func read(max: Int) -> [UInt8]? {
            var buffer = [UInt8](repeating: 0, count: max)
            while !shouldStop() {
                var p = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
                guard poll(&p, 1, 20) > 0 else { continue }
                let n = Darwin.read(fd, &buffer, max)
                if n > 0 { return Array(buffer.prefix(n)) }
                if n == 0 || (errno != EAGAIN && errno != EINTR) { return nil }
            }
            return nil
        }

        func readExactly(_ count: Int) -> [UInt8]? {
            var out = [UInt8]()
            while out.count < count {
                guard let chunk = read(max: count - out.count) else { return nil }
                out += chunk
            }
            return out
        }

        /// Writes everything unless the client stops reading and the test ends.
        @discardableResult
        func write(_ bytes: [UInt8]) -> Bool {
            var offset = 0
            while offset < bytes.count {
                if shouldStop() { return false }
                var p = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
                guard poll(&p, 1, 20) > 0 else { continue }
                let n = bytes.withUnsafeBytes { Darwin.write(fd, $0.baseAddress! + offset, bytes.count - offset) }
                if n > 0 { offset += n } else if errno != EAGAIN && errno != EINTR { return false }
            }
            return true
        }
    }

    let path: String
    private let listenFD: Int32
    private let stopped = OSAllocatedUnfairLock(initialState: false)
    private let finished = DispatchSemaphore(value: 0)

    init(handler: @escaping @Sendable (IO) -> Void) throws {
        let socketPath = NSTemporaryDirectory() + "wd-\(UInt32.random(in: 0...UInt32.max)).sock"
        path = socketPath
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw XCTSkip("socket() failed: \(errno)") }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(socketPath.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else {
            close(descriptor)
            throw XCTSkip("temp path too long")
        }
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard bound == 0, listen(descriptor, 1) == 0 else {
            close(descriptor)
            throw XCTSkip("cannot bind test socket: \(errno)")
        }
        listenFD = descriptor
        let stopped = self.stopped
        let finished = self.finished
        let shouldStop: @Sendable () -> Bool = { stopped.withLock { $0 } }
        Thread.detachNewThread {
            defer { finished.signal() }
            var client: Int32 = -1
            while client < 0, !shouldStop() {
                var p = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
                if poll(&p, 1, 20) > 0 { client = accept(descriptor, nil, nil) }
            }
            guard client >= 0 else { return }
            var on: Int32 = 1
            _ = setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
            _ = fcntl(client, F_SETFL, fcntl(client, F_GETFL) | O_NONBLOCK)
            handler(IO(fd: client, shouldStop: shouldStop))
            close(client)
        }
    }

    deinit {
        stopped.withLock { $0 = true }
        _ = finished.wait(timeout: .now() + 3)
        close(listenFD)
        unlink(path)
    }

    /// Echoes with backpressure, like the iPad probe: read a chunk, write it
    /// back completely, only then read again.
    static func echo(closeAfterBytes: Int? = nil) throws -> UnixPeer {
        try UnixPeer { io in
            var total = 0
            while let chunk = io.read(max: 4096) {
                guard io.write(chunk) else { return }
                total += chunk.count
                if let limit = closeAfterBytes, total >= limit { return }
            }
        }
    }

    /// Scripted usbmuxd: reads one request packet and answers with `reply`.
    /// `captured` receives the decoded request. `tagOffset` corrupts the tag.
    static func fakeDaemon(reply: [String: Any]?, rawReply: [UInt8]? = nil, tagOffset: UInt32 = 0,
                           thenEcho: Bool = false,
                           captured: OSAllocatedUnfairLock<[String: String]>? = nil) throws -> UnixPeer {
        let replyData = try reply.map { try PropertyListSerialization.data(fromPropertyList: $0, format: .xml, options: 0) }
        return try UnixPeer { io in
            guard let headerBytes = io.readExactly(16), let header = try? UsbmuxCodec.decodeHeader(headerBytes),
                  let body = io.readExactly(header.bodyLength),
                  let request = try? UsbmuxCodec.decodeBody(body, header: header) else { return }
            let summary = Dictionary(uniqueKeysWithValues: request.map { ($0.key, "\($0.value)") })
            captured?.withLock { $0 = summary }
            if let rawReply {
                io.write(rawReply)
            } else if let replyData {
                var packet = [UInt8]()
                for word in [UInt32(16 + replyData.count), 1, 8, header.tag &+ tagOffset] {
                    withUnsafeBytes(of: word.littleEndian) { packet.append(contentsOf: $0) }
                }
                io.write(packet + Array(replyData))
            }
            if thenEcho {
                while let chunk = io.read(max: 4096) { guard io.write(chunk) else { return } }
            } else {
                // Keep the socket open until the client is done, so the client
                // observes its own decision rather than an EOF.
                while io.read(max: 64) != nil {}
            }
        }
    }
}

private let usbDevice = UsbmuxDevice(deviceID: 4, serialNumber: "AAAA", connectionType: .usb)

final class UsbmuxConnectionTests: XCTestCase {
    func testMissingSocketFailsCleanly() {
        XCTAssertThrowsError(try UsbmuxConnection(socketPath: "/nonexistent/wd-usbmuxd")) {
            guard case UsbmuxConnection.ClientError.socket = $0 else { return XCTFail("unexpected \($0)") }
        }
    }

    func testOverlongSocketPathIsRejected() {
        XCTAssertThrowsError(try UsbmuxConnection(socketPath: "/" + String(repeating: "x", count: 200))) {
            XCTAssertEqual($0 as? UsbmuxConnection.ClientError, .socket("path too long", errno: ENAMETOOLONG))
        }
    }

    func testNonPositiveTimeoutIsRejected() throws {
        let peer = try UnixPeer.echo()
        for bad in [0, -1, 3601] {
            XCTAssertThrowsError(try UsbmuxConnection(socketPath: peer.path, timeoutSeconds: bad)) {
                guard case UsbmuxConnection.ClientError.invalidArgument = $0 else { return XCTFail("unexpected \($0)") }
            }
        }
    }

    func testListDevicesAgainstFakeDaemon() throws {
        let peer = try UnixPeer.fakeDaemon(reply: ["DeviceList": [
            ["DeviceID": 4, "Properties": ["DeviceID": 4, "SerialNumber": "AAAA", "ConnectionType": "USB"]],
            ["DeviceID": 9, "Properties": ["DeviceID": 9, "SerialNumber": "BBBB", "ConnectionType": "Network"]],
        ]])
        let connection = try UsbmuxConnection(socketPath: peer.path, timeoutSeconds: 2)
        let devices = try connection.listDevices()
        XCTAssertEqual(devices.map(\.serialNumber), ["AAAA", "BBBB"])
        XCTAssertEqual(UsbmuxDevice.wiredOnly(devices).map(\.deviceID), [4])
    }

    func testListDevicesErrorResultIsReportedAsRefusal() throws {
        let peer = try UnixPeer.fakeDaemon(reply: ["MessageType": "Result", "Number": 1])
        let connection = try UsbmuxConnection(socketPath: peer.path, timeoutSeconds: 2)
        XCTAssertThrowsError(try connection.listDevices()) {
            XCTAssertEqual($0 as? UsbmuxConnection.ClientError, .refused(.badCommand))
        }
    }

    func testConnectSendsSwappedPortThenBecomesARawTunnel() throws {
        let captured = OSAllocatedUnfairLock(initialState: [String: String]())
        let peer = try UnixPeer.fakeDaemon(reply: ["MessageType": "Result", "Number": 0], thenEcho: true, captured: captured)
        let connection = try UsbmuxConnection(socketPath: peer.path, timeoutSeconds: 2)
        try connection.connect(to: usbDevice, port: 9000)
        let request = captured.withLock { $0 }
        XCTAssertEqual(request["MessageType"], "Connect")
        XCTAssertEqual(request["DeviceID"], "4")
        XCTAssertEqual(request["PortNumber"], "\(0x2823)", "9000 byte-swapped on the wire")

        XCTAssertEqual(try connection.exchange([1, 2, 3], expecting: 3), [1, 2, 3])
        // No usbmuxd request may be written into the tunnel.
        XCTAssertThrowsError(try connection.listDevices()) {
            guard case UsbmuxConnection.ClientError.invalidState = $0 else { return XCTFail("unexpected \($0)") }
        }
        // ...and the refused call must not have damaged the tunnel.
        XCTAssertEqual(try connection.exchange([4, 5], expecting: 2), [4, 5])
    }

    func testConnectRefusedKillsTheConnection() throws {
        let peer = try UnixPeer.fakeDaemon(reply: ["MessageType": "Result", "Number": 3])
        let connection = try UsbmuxConnection(socketPath: peer.path, timeoutSeconds: 2)
        XCTAssertThrowsError(try connection.connect(to: usbDevice, port: 9000)) {
            XCTAssertEqual($0 as? UsbmuxConnection.ClientError, .refused(.connectionRefused))
        }
        XCTAssertEqual(connection.state, .dead)
        XCTAssertThrowsError(try connection.exchange([1], expecting: 1))
    }

    func testRawIOBeforeConnectIsRejected() throws {
        let peer = try UnixPeer.echo()
        let connection = try UsbmuxConnection(socketPath: peer.path, timeoutSeconds: 2)
        XCTAssertThrowsError(try connection.writeAll([1])) {
            guard case UsbmuxConnection.ClientError.invalidState = $0 else { return XCTFail("unexpected \($0)") }
        }
        XCTAssertEqual(connection.state, .mux, "a rejected call must not change state")
    }

    func testTagMismatchIsRejectedAndConnectionDies() throws {
        let peer = try UnixPeer.fakeDaemon(reply: ["DeviceList": [Any]()], tagOffset: 7)
        let connection = try UsbmuxConnection(socketPath: peer.path, timeoutSeconds: 2)
        XCTAssertThrowsError(try connection.listDevices()) {
            XCTAssertEqual($0 as? UsbmuxConnection.ClientError, .unexpectedReply("tag 8 != 1"))
        }
        XCTAssertEqual(connection.state, .dead)
        XCTAssertThrowsError(try connection.listDevices()) {
            guard case UsbmuxConnection.ClientError.invalidState = $0 else { return XCTFail("unexpected \($0)") }
        }
    }

    func testHostileReplyLengthIsRejectedFromTheHeader() throws {
        var raw = [UInt8]()
        for word in [UInt32.max, 1, 8, 1] as [UInt32] { withUnsafeBytes(of: word.littleEndian) { raw.append(contentsOf: $0) } }
        let peer = try UnixPeer.fakeDaemon(reply: nil, rawReply: raw)
        let connection = try UsbmuxConnection(socketPath: peer.path, timeoutSeconds: 2)
        XCTAssertThrowsError(try connection.listDevices()) {
            XCTAssertEqual($0 as? UsbmuxCodec.CodecError, .lengthOutOfBounds(.max))
        }
        XCTAssertEqual(connection.state, .dead)
    }

    func testTruncatedReplyTimesOutWithinTheOperationDeadline() throws {
        // 8 of 16 header bytes, then silence.
        let peer = try UnixPeer.fakeDaemon(reply: nil, rawReply: [UInt8](repeating: 0, count: 8))
        let connection = try UsbmuxConnection(socketPath: peer.path, timeoutSeconds: 1)
        let started = Date()
        XCTAssertThrowsError(try connection.listDevices()) {
            XCTAssertEqual($0 as? UsbmuxConnection.ClientError, .timedOut)
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 2.5)
    }

    func testPeerClosingMidReplyIsReported() throws {
        let peer = try UnixPeer { io in
            _ = io.read(max: 4096)
            io.write([UInt8](repeating: 0, count: 5))
        }
        let connection = try UsbmuxConnection(socketPath: peer.path, timeoutSeconds: 2)
        XCTAssertThrowsError(try connection.listDevices()) {
            XCTAssertEqual($0 as? UsbmuxConnection.ClientError, .closedByPeer)
        }
    }

    /// The negative-control entry point really does bypass the policy (so the
    /// E-05b control measures the network path), and only that entry point does.
    func testNegativeControlBypassesPolicyButConnectStillRefuses() throws {
        let captured = OSAllocatedUnfairLock(initialState: [String: String]())
        let peer = try UnixPeer.fakeDaemon(reply: ["MessageType": "Result", "Number": 0], thenEcho: true, captured: captured)
        let wifi = UsbmuxDevice(deviceID: 47, serialNumber: "00000000-x", connectionType: .network)

        // UnixPeer serves exactly one client, so the guarded call gets its own.
        let silentCapture = OSAllocatedUnfairLock(initialState: [String: String]())
        let guardedPeer = try UnixPeer.fakeDaemon(reply: ["MessageType": "Result", "Number": 0], captured: silentCapture)
        let guarded = try UsbmuxConnection(socketPath: guardedPeer.path, timeoutSeconds: 2)
        XCTAssertThrowsError(try guarded.connect(to: wifi, port: 9000)) {
            XCTAssertEqual($0 as? UsbmuxConnection.ClientError, .notWired)
        }
        XCTAssertTrue(silentCapture.withLock { $0.isEmpty }, "Wired Only refusal must send nothing")
        guarded.close()

        let control = try UsbmuxConnection(socketPath: peer.path, timeoutSeconds: 2)
        try control.connectIgnoringWiredOnlyPolicyForNegativeControl(to: wifi, port: 9000)
        XCTAssertEqual(captured.withLock { $0["DeviceID"] }, "47")
        XCTAssertEqual(try control.exchange([7], expecting: 1), [7])
    }

    func testConnectRefusesNonUSBDeviceWithoutAnyIO() throws {
        let captured = OSAllocatedUnfairLock(initialState: [String: String]())
        let peer = try UnixPeer.fakeDaemon(reply: ["MessageType": "Result", "Number": 0], captured: captured)
        let connection = try UsbmuxConnection(socketPath: peer.path, timeoutSeconds: 2)
        for type in [UsbmuxDevice.ConnectionType.network, .other("Thread")] {
            let device = UsbmuxDevice(deviceID: 1, serialNumber: "x", connectionType: type)
            XCTAssertThrowsError(try connection.connect(to: device, port: 9000)) {
                XCTAssertEqual($0 as? UsbmuxConnection.ClientError, .notWired)
            }
        }
        XCTAssertEqual(connection.state, .mux)
        XCTAssertTrue(captured.withLock { $0.isEmpty }, "policy check must precede any request")
    }
}

final class UsbmuxExchangeTests: XCTestCase {
    private func tunnel(to peer: UnixPeer, timeoutSeconds: Int = 2) throws -> UsbmuxConnection {
        let connection = try UsbmuxConnection(socketPath: peer.path, timeoutSeconds: timeoutSeconds)
        connection.enterTunnelStateForTesting()
        return connection
    }

    /// Regression for BUG-001: 4 MiB is far beyond AF_UNIX socket buffering, so
    /// write-everything-then-read against this peer cannot complete.
    func testExchangeLargerThanSocketBuffersDoesNotDeadlock() throws {
        let peer = try UnixPeer.echo()
        let connection = try tunnel(to: peer)
        var generator = SystemRandomNumberGenerator()
        let payload = (0..<(4 * 1024 * 1024)).map { _ in UInt8.random(in: 0...255, using: &generator) }
        XCTAssertEqual(try connection.exchange(payload, expecting: payload.count, timeoutMilliseconds: 5000), payload)
        XCTAssertEqual(try connection.exchange([1, 2, 3], expecting: 3), [1, 2, 3])
    }

    func testWriteOnlyAgainstBackpressurePeerTimesOutAndKillsConnection() throws {
        // Documents why exchange() exists: writing without draining stalls.
        let peer = try UnixPeer.echo()
        let connection = try tunnel(to: peer, timeoutSeconds: 1)
        XCTAssertThrowsError(try connection.writeAll([UInt8](repeating: 7, count: 4 * 1024 * 1024))) {
            XCTAssertEqual($0 as? UsbmuxConnection.ClientError, .timedOut)
        }
        // A partially written stream is desynchronised: it must not be reusable.
        XCTAssertEqual(connection.state, .dead)
    }

    func testExchangeReportsPeerCloseInsteadOfHanging() throws {
        let peer = try UnixPeer.echo(closeAfterBytes: 4096)
        let connection = try tunnel(to: peer)
        let payload = [UInt8](repeating: 9, count: 2 * 1024 * 1024)
        XCTAssertThrowsError(try connection.exchange(payload, expecting: payload.count, timeoutMilliseconds: 3000)) {
            XCTAssertEqual($0 as? UsbmuxConnection.ClientError, .closedByPeer)
        }
    }

    func testExchangeTimesOutWhenPeerNeverAnswers() throws {
        let peer = try UnixPeer.echo()
        let connection = try tunnel(to: peer)
        XCTAssertThrowsError(try connection.exchange([1], expecting: 2, timeoutMilliseconds: 300)) {
            XCTAssertEqual($0 as? UsbmuxConnection.ClientError, .timedOut)
        }
    }

    /// The deadline covers the whole operation: a peer that trickles one byte
    /// well inside any per-syscall timeout must still be cut off.
    func testTricklingPeerCannotExtendTheDeadline() throws {
        let peer = try UnixPeer { io in
            _ = io.read(max: 16)
            for _ in 0..<200 {
                guard io.write([0x55]) else { return }
                Thread.sleep(forTimeInterval: 0.05)
            }
        }
        let connection = try tunnel(to: peer)
        let started = Date()
        XCTAssertThrowsError(try connection.exchange([1], expecting: 10_000, timeoutMilliseconds: 400)) {
            XCTAssertEqual($0 as? UsbmuxConnection.ClientError, .timedOut)
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 1.5)
    }

    func testExchangeWithNothingToDoReturnsImmediately() throws {
        let peer = try UnixPeer.echo()
        let connection = try tunnel(to: peer)
        XCTAssertEqual(try connection.exchange([], expecting: 0), [])
    }

    func testInvalidArgumentsAreRejectedWithoutKillingTheConnection() throws {
        let peer = try UnixPeer.echo()
        let connection = try tunnel(to: peer)
        XCTAssertThrowsError(try connection.exchange([], expecting: -1))
        XCTAssertThrowsError(try connection.exchange([1], expecting: 1, timeoutMilliseconds: 0))
        XCTAssertEqual(try connection.exchange([8], expecting: 1), [8])
    }
}
#endif

final class DevicePreferenceTests: XCTestCase {
    private func device(_ id: Int, _ serial: String) -> UsbmuxDevice {
        UsbmuxDevice(deviceID: id, serialNumber: serial, connectionType: .usb)
    }

    func testLastGoodDeviceIsTriedFirstAndOthersKeepTheirOrder() {
        let sidecarIPad = device(1, "A"), iPhone = device(2, "B"), ours = device(3, "C")
        let all = [sidecarIPad, iPhone, ours]
        XCTAssertEqual(UsbmuxDevice.preferring(serial: "C", in: all).map(\.serialNumber), ["C", "A", "B"])
        XCTAssertEqual(UsbmuxDevice.preferring(serial: nil, in: all).map(\.serialNumber), ["A", "B", "C"])
        XCTAssertEqual(UsbmuxDevice.preferring(serial: "gone", in: all).map(\.serialNumber), ["A", "B", "C"])
    }
}
