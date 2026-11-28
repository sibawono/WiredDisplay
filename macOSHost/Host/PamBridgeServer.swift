import Darwin
import Foundation
import os
import WDSession

/// Local Unix domain socket relay between `pam_wireddisplay.so` (running as root in `sudo`
/// or `screensaver`) and `HostFleet` (which forwards challenges to the connected iPad's
/// Secure Enclave over `SecureChannel`).
///
/// Security: this bridge is an UNTRUSTED transport relay. `pam_wireddisplay.so` generates
/// the random nonce itself and verifies the iPad Secure Enclave ECDSA P-256 signature against
/// a root-owned public key file. Even if this process were compromised, it cannot forge a
/// valid signature without live Touch ID / Face ID verification on the enrolled iPad.
final class PamBridgeServer: @unchecked Sendable {
    struct Request: Sendable {
        let service: String
        let username: String
        let reason: String
        let nonce: [UInt8]
        let timeoutSeconds: TimeInterval
    }

    struct Response: Sendable {
        /// 0 = ok, 1 = cancelled, 2 = unavailable, 3 = notEnrolled
        let status: UInt8
        let signature: [UInt8]
    }

    static var cacheDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Caches/dev.wireddisplay.host", isDirectory: true)
    }

    static var socketPath: String {
        cacheDirectory.appendingPathComponent("pam.sock").path
    }

    static var lastPublicKeyFile: URL {
        cacheDirectory.appendingPathComponent("last_biometric_key.b64")
    }

    /// Saves the connected iPad's latest Secure Enclave public key (base64 X9.63) to user cache
    /// as a convenience input for `sudo scripts/install-pam.sh`.
    static func recordBiometricPublicKey(_ key: [UInt8]) {
        guard key.count == BiometricAuthMessage.p256PublicKeyLength else { return }
        do {
            try FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
            let b64 = Data(key).base64EncodedString() + "\n"
            try b64.write(to: lastPublicKeyFile, atomically: true, encoding: .utf8)
            chmod(lastPublicKeyFile.path, 0o600)
        } catch {
            Log.warn("pam: could not save last biometric public key: \(error)")
        }
    }

    /// Represents a long-lived Lock Screen authentication session from `WiredDisplayAuth.bundle`.
    /// Stays alive while the Mac is locked until either the user approves Touch ID / Face ID
    /// on the iPad (`resolve(_:)`) or unlocks the Mac another way (`WiredDisplayAuth` closes the socket).
    final class LockscreenSession: @unchecked Sendable {
        let requestID: UInt32
        let service: String
        let username: String
        let reason: String
        let nonce: [UInt8]

        private let state: OSAllocatedUnfairLock<(response: Response?, wakeWriteFD: Int32)>

        init(requestID: UInt32, service: String, username: String, reason: String, nonce: [UInt8], wakeWriteFD: Int32) {
            self.requestID = requestID
            self.service = service
            self.username = username
            self.reason = reason
            self.nonce = nonce
            self.state = OSAllocatedUnfairLock(initialState: (nil, wakeWriteFD))
        }

        func resolve(_ response: Response) {
            let fdToWake: Int32 = state.withLock { st in
                guard st.response == nil else { return -1 }
                st.response = response
                return st.wakeWriteFD
            }
            if fdToWake >= 0 {
                var byte: UInt8 = 1
                _ = Darwin.write(fdToWake, &byte, 1)
            }
        }

        func currentResponse() -> Response? {
            state.withLock { $0.response }
        }

        func closeWakeWriteFD() {
            let fd: Int32 = state.withLock { st in
                defer { st.wakeWriteFD = -1 }
                return st.wakeWriteFD
            }
            if fd >= 0 { Darwin.close(fd) }
        }
    }

    private let handler: @Sendable (Request) -> Response
    private let onLockscreenStart: (@Sendable (LockscreenSession) -> Void)?
    private let onLockscreenEnd: (@Sendable (UInt32) -> Void)?
    private let nextLockscreenID = OSAllocatedUnfairLock<UInt32>(initialState: 0x8000_0001)
    private let listenFD = OSAllocatedUnfairLock<Int32>(initialState: -1)
    private let stopping = OSAllocatedUnfairLock(initialState: false)

    init(
        handler: @escaping @Sendable (Request) -> Response,
        onLockscreenStart: (@Sendable (LockscreenSession) -> Void)? = nil,
        onLockscreenEnd: (@Sendable (UInt32) -> Void)? = nil
    ) {
        self.handler = handler
        self.onLockscreenStart = onLockscreenStart
        self.onLockscreenEnd = onLockscreenEnd
    }

    deinit { stop() }

    func start() {
        do {
            try FileManager.default.createDirectory(at: Self.cacheDirectory, withIntermediateDirectories: true)
            chmod(Self.cacheDirectory.path, 0o700)
        } catch {
            Log.warn("pam: could not create cache dir: \(error)")
            return
        }
        let path = Self.socketPath
        unlink(path)

        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            Log.warn("pam: socket() failed: errno \(errno)")
            return
        }
        var on: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(path.utf8)
        guard pathBytes.count < MemoryLayout.size(ofValue: addr.sun_path) else {
            Darwin.close(fd)
            Log.warn("pam: socket path too long")
            return
        }
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            raw.copyBytes(from: pathBytes)
            raw[pathBytes.count] = 0
        }
        let bound = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0 else {
            Log.warn("pam: bind(\(path)) failed: errno \(errno)")
            Darwin.close(fd)
            return
        }
        chmod(path, 0o600)
        guard Darwin.listen(fd, 8) == 0 else {
            Log.warn("pam: listen() failed: errno \(errno)")
            Darwin.close(fd)
            return
        }
        listenFD.withLock { $0 = fd }
        Log.info("pam: bridge listening at \(path)")
        Thread.detachNewThread { [weak self] in self?.acceptLoop(fd: fd) }
    }

    func stop() {
        stopping.withLock { $0 = true }
        let fd = listenFD.withLock { current -> Int32 in
            defer { current = -1 }
            return current
        }
        if fd >= 0 {
            shutdown(fd, SHUT_RDWR)
            Darwin.close(fd)
            unlink(Self.socketPath)
        }
    }

    private func acceptLoop(fd: Int32) {
        while !stopping.withLock({ $0 }) {
            var clientAddr = sockaddr_un()
            var addrLen = socklen_t(MemoryLayout<sockaddr_un>.size)
            let clientFD = withUnsafeMutablePointer(to: &clientAddr) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.accept(fd, $0, &addrLen)
                }
            }
            if clientFD < 0 {
                if errno == EINTR { continue }
                if stopping.withLock({ $0 }) { break }
                Thread.sleep(forTimeInterval: 0.1)
                continue
            }
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                self?.handleClient(clientFD)
            }
        }
    }

    private func handleClient(_ fd: Int32) {
        defer { Darwin.close(fd) }
        var on: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        var tv = timeval(tv_sec: 2, tv_usec: 0)
        _ = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        _ = setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        // Only accept root (PAM in sudo/screensaver) or our own user UID.
        var euid: uid_t = 0
        var egid: gid_t = 0
        guard getpeereid(fd, &euid, &egid) == 0, euid == 0 || euid == getuid() else {
            Log.warn("pam: rejected unauthorized peer uid=\(euid)")
            return
        }

        // Binary request wire format:
        // u8 version(1) | u16 serviceLen | service | u16 userLen | user | u16 reasonLen | reason | u8 nonceLen(32) | nonce
        guard let version = readExact(fd, count: 1)?.first, version == 1,
              let service = readString(fd, maxLen: 64),
              let username = readString(fd, maxLen: 64),
              let reason = readString(fd, maxLen: 128),
              let nonceLen = readExact(fd, count: 1)?.first,
              Int(nonceLen) == BiometricAuthMessage.nonceLength,
              let nonce = readExact(fd, count: Int(nonceLen)) else {
            writeResponse(fd, Response(status: 2, signature: []))
            return
        }

        if service == "lockscreen" || service == "admin" {
            handleLockscreenClient(fd, service: service, username: username, reason: reason, nonce: nonce)
            return
        }

        let timeout: TimeInterval = service == "screensaver" ? 10 : 15
        let response = handler(Request(service: service, username: username, reason: reason,
                                       nonce: nonce, timeoutSeconds: timeout))
        writeResponse(fd, response)
    }

    private func handleLockscreenClient(_ fd: Int32, service: String, username: String, reason: String, nonce: [UInt8]) {
        var pipeFDs: [Int32] = [-1, -1]
        guard pipe(&pipeFDs) == 0 else {
            writeResponse(fd, Response(status: 2, signature: []))
            return
        }
        let wakeReadFD = pipeFDs[0]
        let wakeWriteFD = pipeFDs[1]
        let reqID: UInt32 = nextLockscreenID.withLock { id in
            let current = id
            id &+= 1
            if id < 0x8000_0001 { id = 0x8000_0001 }
            return current
        }
        let session = LockscreenSession(requestID: reqID, service: service, username: username, reason: reason,
                                        nonce: nonce, wakeWriteFD: wakeWriteFD)
        Log.info("pam: \(service) session #\(reqID) started for \(username)")
        onLockscreenStart?(session)
        defer {
            session.closeWakeWriteFD()
            Darwin.close(wakeReadFD)
            onLockscreenEnd?(reqID)
            Log.info("pam: \(service) session #\(reqID) ended")
        }

        while !stopping.withLock({ $0 }) {
            if let response = session.currentResponse() {
                writeResponse(fd, response)
                return
            }
            var pfds = [
                pollfd(fd: fd, events: Int16(POLLIN), revents: 0),
                pollfd(fd: wakeReadFD, events: Int16(POLLIN), revents: 0)
            ]
            let r = poll(&pfds, 2, 1000)
            if r < 0 {
                if errno == EINTR { continue }
                return
            }
            if let response = session.currentResponse() {
                writeResponse(fd, response)
                return
            }
            if r > 0 && (pfds[0].revents & Int16(POLLIN | POLLHUP | POLLERR)) != 0 {
                var peek: UInt8 = 0
                let n = recv(fd, &peek, 1, MSG_PEEK | MSG_DONTWAIT)
                if n <= 0 || (pfds[0].revents & Int16(POLLHUP | POLLERR)) != 0 {
                    // Peer (WiredDisplayAuth) deactivated/closed because Mac unlocked another way.
                    return
                }
            }
        }
    }

    private func readExact(_ fd: Int32, count: Int) -> [UInt8]? {
        guard count >= 0 else { return nil }
        if count == 0 { return [] }
        var buf = [UInt8](repeating: 0, count: count)
        var offset = 0
        while offset < count {
            let n = buf.withUnsafeMutableBytes { raw in
                Darwin.read(fd, raw.baseAddress! + offset, count - offset)
            }
            if n < 0 && errno == EINTR { continue }
            guard n > 0 else { return nil }
            offset += n
        }
        return buf
    }

    private func readString(_ fd: Int32, maxLen: Int) -> String? {
        guard let lenBytes = readExact(fd, count: 2) else { return nil }
        let len = (Int(lenBytes[0]) << 8) | Int(lenBytes[1])
        guard len <= maxLen, let data = readExact(fd, count: len) else { return nil }
        return String(bytes: data, encoding: .utf8)
    }

    private func writeResponse(_ fd: Int32, _ response: Response) {
        let sigLen = min(response.signature.count, BiometricAuthMessage.maxSignatureLength)
        var out = [UInt8]()
        out.reserveCapacity(3 + sigLen)
        out.append(response.status)
        out.append(UInt8((sigLen >> 8) & 0xFF))
        out.append(UInt8(sigLen & 0xFF))
        out.append(contentsOf: response.signature.prefix(sigLen))
        var sent = 0
        while sent < out.count {
            let n = out.withUnsafeBytes { raw in
                Darwin.write(fd, raw.baseAddress! + sent, out.count - sent)
            }
            if n < 0 && errno == EINTR { continue }
            guard n > 0 else { return }
            sent += n
        }
    }
}
