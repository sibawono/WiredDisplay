#if os(macOS)
import Darwin
import Foundation

/// An Android device reported by the local ADB server (`127.0.0.1:5037`).
public struct AdbDevice: Equatable, Hashable, Sendable {
    public let serial: String
    public let state: String
    public let model: String?
    public let isWiredOrLocal: Bool

    public init(serial: String, state: String, model: String? = nil, isWiredOrLocal: Bool = true) {
        self.serial = serial
        self.state = state
        self.model = model
        self.isWiredOrLocal = isWiredOrLocal
    }

    /// Prefixed controller serial so Android serials never collide with Apple UDIDs.
    public var fleetSerial: String { "\(AdbClient.serialPrefix)\(serial)" }

    public static func wiredOnly(_ devices: [AdbDevice]) -> [AdbDevice] {
        devices.filter { $0.state == "device" && $0.isWiredOrLocal }
    }
}

/// Pure-Swift client for the local ADB server (`127.0.0.1:5037`).
/// Opens a raw TCP tunnel to `tcp:<port>` on a USB-attached Android device and
/// hands the connected file descriptor directly to `FramedSocket`.
public enum AdbClient {
    public static let defaultHost = "127.0.0.1"
    public static let defaultPort: UInt16 = 5037
    public static let serialPrefix = "adb:"

    public enum ClientError: Error, Equatable, Sendable {
        case serverUnavailable
        case protocolError(String)
        case failed(String)
        case timedOut
    }

    public static func stripPrefix(_ fleetSerial: String) -> String? {
        guard fleetSerial.hasPrefix(serialPrefix) else { return nil }
        return String(fleetSerial.dropFirst(serialPrefix.count))
    }

    /// Encodes a command using ADB's 4-hex-digit length prefix.
    public static func encodeRequest(_ command: String) -> [UInt8] {
        let body = Array(command.utf8)
        let prefix = String(format: "%04x", body.count)
        return Array(prefix.utf8) + body
    }

    /// Parses the body returned by `host:devices-l`.
    public static func parseDeviceList(_ text: String) -> [AdbDevice] {
        var result: [AdbDevice] = []
        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }
            let parts = line.split(whereSeparator: \.isWhitespace).map(String.init)
            guard parts.count >= 2 else { continue }
            let serial = parts[0]
            let state = parts[1]
            var model: String?
            var hasUsbTag = false
            for token in parts.dropFirst(2) {
                if token.hasPrefix("model:") {
                    model = String(token.dropFirst("model:".count)).replacingOccurrences(of: "_", with: " ")
                } else if token.hasPrefix("usb:") {
                    hasUsbTag = true
                }
            }
            let isWireless = serial.contains(":") || serial.contains("._adb-tls-connect.")
            let isLocalEmulator = serial.hasPrefix("emulator-")
            let wiredOrLocal = (hasUsbTag || isLocalEmulator || !isWireless) && !isWireless
            result.append(AdbDevice(serial: serial, state: state, model: model, isWiredOrLocal: wiredOrLocal))
        }
        return result
    }

    public static func listDevices(port: UInt16 = defaultPort, timeoutMs: Int32 = 1500) throws -> [AdbDevice] {
        let fd = try openLoopbackSocket(port: port, timeoutMs: timeoutMs)
        defer { Darwin.close(fd) }
        try writeAll(fd: fd, bytes: encodeRequest("host:devices-l"), timeoutMs: timeoutMs)
        try readStatus(fd: fd, timeoutMs: timeoutMs)
        let lenBytes = try readExact(fd: fd, count: 4, timeoutMs: timeoutMs)
        guard let lenStr = String(bytes: lenBytes, encoding: .ascii),
              let length = Int(lenStr, radix: 16), length >= 0, length <= 256 * 1024 else {
            throw ClientError.protocolError("invalid device list length")
        }
        guard length > 0 else { return [] }
        let body = try readExact(fd: fd, count: length, timeoutMs: timeoutMs)
        guard let text = String(bytes: body, encoding: .utf8) else {
            throw ClientError.protocolError("device list not UTF-8")
        }
        return parseDeviceList(text)
    }

    /// Opens a raw stream tunnel to `tcp:<clientPort>` on the given Android device.
    /// Caller owns the returned non-blocking file descriptor (with SO_NOSIGPIPE and TCP_NODELAY).
    public static func connect(to serial: String, clientPort: UInt16, adbPort: UInt16 = defaultPort,
                               timeoutMs: Int32 = 3000) throws -> Int32 {
        let fd = try openLoopbackSocket(port: adbPort, timeoutMs: timeoutMs)
        do {
            try writeAll(fd: fd, bytes: encodeRequest("host:transport:\(serial)"), timeoutMs: timeoutMs)
            try readStatus(fd: fd, timeoutMs: timeoutMs)
            try writeAll(fd: fd, bytes: encodeRequest("tcp:\(clientPort)"), timeoutMs: timeoutMs)
            try readStatus(fd: fd, timeoutMs: timeoutMs)
            return fd
        } catch {
            Darwin.close(fd)
            throw error
        }
    }

    // MARK: socket helpers

    private static func openLoopbackSocket(port: UInt16, timeoutMs: Int32) throws -> Int32 {
        let fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw ClientError.serverUnavailable }
        var on: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        _ = setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &on, socklen_t(MemoryLayout<Int32>.size))
        let flags = fcntl(fd, F_GETFL)
        guard flags >= 0, fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0 else {
            Darwin.close(fd)
            throw ClientError.serverUnavailable
        }
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr = in_addr(s_addr: UInt32(INADDR_LOOPBACK).bigEndian)
        let rc = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        if rc != 0 {
            if errno != EINPROGRESS {
                Darwin.close(fd)
                throw ClientError.serverUnavailable
            }
            try waitReady(fd: fd, events: Int16(POLLOUT), timeoutMs: timeoutMs)
            var sockErr: Int32 = 0
            var errLen = socklen_t(MemoryLayout<Int32>.size)
            if getsockopt(fd, SOL_SOCKET, SO_ERROR, &sockErr, &errLen) != 0 || sockErr != 0 {
                Darwin.close(fd)
                throw ClientError.serverUnavailable
            }
        }
        return fd
    }

    private static func waitReady(fd: Int32, events: Int16, timeoutMs: Int32) throws {
        var pfd = pollfd(fd: fd, events: events, revents: 0)
        let rc = Darwin.poll(&pfd, 1, timeoutMs)
        if rc == 0 { throw ClientError.timedOut }
        if rc < 0 { throw ClientError.serverUnavailable }
    }

    private static func writeAll(fd: Int32, bytes: [UInt8], timeoutMs: Int32) throws {
        var offset = 0
        while offset < bytes.count {
            try waitReady(fd: fd, events: Int16(POLLOUT), timeoutMs: timeoutMs)
            let wrote = bytes.withUnsafeBytes { raw in
                Darwin.send(fd, raw.baseAddress!.advanced(by: offset), bytes.count - offset, 0)
            }
            if wrote < 0 {
                if errno == EAGAIN || errno == EINTR { continue }
                throw ClientError.serverUnavailable
            }
            if wrote == 0 { throw ClientError.serverUnavailable }
            offset += wrote
        }
    }

    private static func readExact(fd: Int32, count: Int, timeoutMs: Int32) throws -> [UInt8] {
        var out = [UInt8](repeating: 0, count: count)
        var offset = 0
        while offset < count {
            try waitReady(fd: fd, events: Int16(POLLIN), timeoutMs: timeoutMs)
            let got = out.withUnsafeMutableBytes { raw in
                Darwin.recv(fd, raw.baseAddress!.advanced(by: offset), count - offset, 0)
            }
            if got < 0 {
                if errno == EAGAIN || errno == EINTR { continue }
                throw ClientError.serverUnavailable
            }
            if got == 0 { throw ClientError.protocolError("EOF") }
            offset += got
        }
        return out
    }

    private static func readStatus(fd: Int32, timeoutMs: Int32) throws {
        let status = try readExact(fd: fd, count: 4, timeoutMs: timeoutMs)
        guard let text = String(bytes: status, encoding: .ascii) else {
            throw ClientError.protocolError("non-ASCII status")
        }
        if text == "OKAY" { return }
        if text == "FAIL" {
            let lenBytes = try readExact(fd: fd, count: 4, timeoutMs: timeoutMs)
            let len = String(bytes: lenBytes, encoding: .ascii).flatMap { Int($0, radix: 16) } ?? 0
            let msgBytes = len > 0 && len <= 4096 ? (try? readExact(fd: fd, count: len, timeoutMs: timeoutMs)) ?? [] : []
            let msg = String(bytes: msgBytes, encoding: .utf8) ?? "ADB failed"
            throw ClientError.failed(msg)
        }
        throw ClientError.protocolError("unexpected status \(text)")
    }
}
#endif
