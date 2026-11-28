#if os(macOS)
import Foundation

/// Client for the local usbmuxd daemon. Each instance owns exactly one socket
/// and is used from one thread; it is deliberately not Sendable. The session
/// layer (Phase 1) wraps it in an actor.
///
/// Lifecycle: `.mux` (plist requests allowed) -> `.tunnel` after a successful
/// `connect` (raw bytes only) -> `.dead` after any I/O or protocol error. A
/// dead connection is closed and every further call throws `.invalidState`:
/// after a failed or partial exchange the byte stream cannot be trusted.
public final class UsbmuxConnection {
    public enum ClientError: Error, Equatable {
        case socket(String, errno: Int32)
        case closedByPeer
        case timedOut
        case unexpectedReply(String)
        case refused(UsbmuxResultCode)
        case notWired
        case invalidState(String)
        case invalidArgument(String)
    }

    enum State: Equatable { case mux, tunnel, dead }

    public static let defaultSocketPath = "/var/run/usbmuxd"

    private var fd: Int32 = -1
    private var nextTag: UInt32 = 1
    private(set) var state: State = .mux
    private let operationTimeoutMilliseconds: Int

    /// `timeoutSeconds` bounds every whole operation (a request, a read, a
    /// write, an exchange), not each individual syscall.
    public init(socketPath: String = UsbmuxConnection.defaultSocketPath, timeoutSeconds: Int = 5) throws {
        guard (1...3600).contains(timeoutSeconds) else {
            throw ClientError.invalidArgument("timeoutSeconds must be in 1...3600")
        }
        operationTimeoutMilliseconds = timeoutSeconds * 1000

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(socketPath.utf8)
        guard pathBytes.count < MemoryLayout.size(ofValue: address.sun_path) else {
            throw ClientError.socket("path too long", errno: ENAMETOOLONG)
        }
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            raw.copyBytes(from: pathBytes)
            raw[pathBytes.count] = 0
        }

        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw ClientError.socket("socket", errno: errno) }
        func failing(_ operation: String, _ code: Int32) -> ClientError {
            Darwin.close(descriptor)
            return ClientError.socket(operation, errno: code)
        }

        // Without SO_NOSIGPIPE a write to a vanished peer would kill the process.
        var on: Int32 = 1
        guard setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size)) == 0 else {
            throw failing("setsockopt(SO_NOSIGPIPE)", errno)
        }
        // macOS defaults AF_UNIX stream buffers to 8 KiB, forcing 20-250+ write() syscalls per video frame.
        var bufSize: Int32 = 512 * 1024
        _ = setsockopt(descriptor, SOL_SOCKET, SO_SNDBUF, &bufSize, socklen_t(MemoryLayout<Int32>.size))
        _ = setsockopt(descriptor, SOL_SOCKET, SO_RCVBUF, &bufSize, socklen_t(MemoryLayout<Int32>.size))
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else { throw failing("connect \(socketPath)", errno) }
        // All I/O goes through one poll loop with a deadline.
        let flags = fcntl(descriptor, F_GETFL)
        guard flags >= 0, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0 else {
            throw failing("fcntl(O_NONBLOCK)", errno)
        }
        fd = descriptor
    }

    deinit { close() }

    public func close() {
        if fd >= 0 { Darwin.close(fd); fd = -1 }
        state = .dead
    }

    // MARK: usbmuxd requests (state .mux)

    public func listDevices() throws -> [UsbmuxDevice] {
        let reply = try request(["MessageType": "ListDevices"])
        if (reply["MessageType"] as? String) == "Result", let number = reply["Number"] as? Int {
            close()
            throw ClientError.refused(UsbmuxResultCode(number))
        }
        do {
            return try UsbmuxDevice.parseList(reply)
        } catch {
            close()
            throw error
        }
    }

    /// Asks usbmuxd to splice this socket to `port` on the device's loopback.
    /// On success the socket becomes a raw byte pipe to the iPad app and no
    /// further usbmuxd requests are accepted on it.
    ///
    /// Refuses devices that are not USB-attached: usbmuxd also lists
    /// Wi-Fi-synced devices, and Wired Only must never ride on those.
    public func connect(to device: UsbmuxDevice, port: UInt16) throws {
        guard device.connectionType == .usb else { throw ClientError.notWired }
        try splice(to: device, port: port)
    }

    /// TEST INSTRUMENT ONLY — never call from product code.
    ///
    /// Same as `connect` but deliberately ignores the Wired Only policy, so an
    /// experiment can show that usbmuxd *would* reach the iPad over Wi-Fi when
    /// it is listed as a Network-type device, i.e. that the policy check in
    /// `connect` is what makes the product wired-only (E-05b negative control,
    /// review finding 9).
    public func connectIgnoringWiredOnlyPolicyForNegativeControl(to device: UsbmuxDevice, port: UInt16) throws {
        try splice(to: device, port: port)
    }

    private func splice(to device: UsbmuxDevice, port: UInt16) throws {
        let reply = try request([
            "MessageType": "Connect",
            "DeviceID": device.deviceID,
            "PortNumber": UsbmuxCodec.wirePort(port),
        ])
        guard (reply["MessageType"] as? String) == "Result", let number = reply["Number"] as? Int else {
            close()
            throw ClientError.unexpectedReply("Connect: \(reply.keys.sorted())")
        }
        let code = UsbmuxResultCode(number)
        guard code == .ok else {
            close()
            throw ClientError.refused(code)
        }
        state = .tunnel
    }

    private func request(_ fields: [String: Any]) throws -> [String: Any] {
        guard state == .mux else { throw ClientError.invalidState("usbmuxd request in state \(state)") }
        let tag = nextTag
        nextTag &+= 1
        do {
            let deadline = Self.deadline(afterMilliseconds: operationTimeoutMilliseconds)
            _ = try duplex(try UsbmuxCodec.encodeRequest(fields, tag: tag), expecting: 0, deadline: deadline)
            let header = try UsbmuxCodec.decodeHeader(
                try duplex([], expecting: UsbmuxCodec.headerLength, deadline: deadline))
            guard header.tag == tag else { throw ClientError.unexpectedReply("tag \(header.tag) != \(tag)") }
            return try UsbmuxCodec.decodeBody(try duplex([], expecting: header.bodyLength, deadline: deadline),
                                              header: header)
        } catch {
            close()
            throw error
        }
    }

    // MARK: raw I/O (state .tunnel)

    public func writeAll(_ bytes: [UInt8]) throws {
        _ = try exchange(bytes, expecting: 0)
    }

    public func readExactly(_ count: Int) throws -> [UInt8] {
        try exchange([], expecting: count)
    }

    /// Writes `bytes` while simultaneously reading exactly `count` bytes, all
    /// within one deadline.
    ///
    /// A peer that echoes with backpressure stops reading when its own writes
    /// stall. Writing a whole frame and only then reading (BUG-001) deadlocks
    /// as soon as the frame exceeds the buffering in the path, so both
    /// directions are serviced from one poll loop.
    public func exchange(_ bytes: [UInt8], expecting count: Int, timeoutMilliseconds: Int? = nil) throws -> [UInt8] {
        guard state == .tunnel else { throw ClientError.invalidState("raw I/O in state \(state)") }
        guard count >= 0 else { throw ClientError.invalidArgument("negative read length") }
        let budget = timeoutMilliseconds ?? operationTimeoutMilliseconds
        guard budget > 0 else { throw ClientError.invalidArgument("timeout must be positive") }
        do {
            return try duplex(bytes, expecting: count, deadline: Self.deadline(afterMilliseconds: budget))
        } catch {
            close()
            throw error
        }
    }

    /// Hands the tunnel's socket to a streaming transport and gives up
    /// ownership: this object will no longer read, write or close it. The
    /// descriptor stays non-blocking with SO_NOSIGPIPE set.
    public func detachTunnel() throws -> Int32 {
        guard state == .tunnel, fd >= 0 else { throw ClientError.invalidState("detach in state \(state)") }
        let descriptor = fd
        fd = -1
        state = .dead
        return descriptor
    }

    /// Test seam: lets unit tests drive raw I/O against a local socket without
    /// a usbmuxd handshake. Not public.
    func enterTunnelStateForTesting() { if state == .mux { state = .tunnel } }

    // MARK: poll loop

    private static func deadline(afterMilliseconds milliseconds: Int) -> UInt64 {
        clock_gettime_nsec_np(CLOCK_MONOTONIC) + UInt64(milliseconds) * 1_000_000
    }

    private static func ioError(_ operation: String, _ code: Int32) -> ClientError {
        switch code {
        case EPIPE, ECONNRESET, ENOTCONN: return .closedByPeer
        default: return .socket(operation, errno: code)
        }
    }

    private static func isTransient(_ code: Int32) -> Bool {
        code == EAGAIN || code == EWOULDBLOCK || code == EINTR
    }

    private func duplex(_ bytes: [UInt8], expecting count: Int, deadline: UInt64) throws -> [UInt8] {
        var received = [UInt8](repeating: 0, count: count)
        var sent = 0
        var got = 0
        while sent < bytes.count || got < count {
            let now = clock_gettime_nsec_np(CLOCK_MONOTONIC)
            guard now < deadline else { throw ClientError.timedOut }
            // Round up so a sub-millisecond remainder cannot spin.
            let remaining = Int32(clamping: (deadline - now + 999_999) / 1_000_000)

            var events: Int32 = 0
            if sent < bytes.count { events |= POLLOUT }
            if got < count { events |= POLLIN }
            var descriptor = pollfd(fd: fd, events: Int16(events), revents: 0)
            let ready = poll(&descriptor, 1, remaining)
            let pollErrno = errno
            if ready == 0 { throw ClientError.timedOut }
            if ready < 0 {
                if pollErrno == EINTR { continue }
                throw ClientError.socket("poll", errno: pollErrno)
            }
            let revents = Int32(descriptor.revents)
            if revents & POLLNVAL != 0 { throw ClientError.socket("poll", errno: EBADF) }

            if got < count, revents & (POLLIN | POLLHUP | POLLERR) != 0 {
                let (result, code): (Int, Int32) = received.withUnsafeMutableBytes { raw in
                    guard let base = raw.baseAddress else { return (0, EINVAL) }
                    let n = Darwin.read(fd, base + got, count - got)
                    return (n, errno)
                }
                if result > 0 {
                    got += result
                } else if result == 0 {
                    throw ClientError.closedByPeer
                } else if !Self.isTransient(code) {
                    throw Self.ioError("read", code)
                }
            } else if revents & (POLLHUP | POLLERR) != 0 {
                // Peer went away while we still had bytes to send.
                throw ClientError.closedByPeer
            }

            if sent < bytes.count, revents & POLLOUT != 0 {
                let (result, code): (Int, Int32) = bytes.withUnsafeBytes { raw in
                    guard let base = raw.baseAddress else { return (0, EINVAL) }
                    let n = Darwin.write(fd, base + sent, bytes.count - sent)
                    return (n, errno)
                }
                if result > 0 {
                    sent += result
                } else if result < 0, !Self.isTransient(code) {
                    throw Self.ioError("write", code)
                }
            }
        }
        return received
    }
}
#endif
