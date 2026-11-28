import CryptoKit
import Foundation
import WDProtocol

/// Authenticated, encrypted channel for one connection (D-023, R-SEC-01).
///
/// Handshake (both sides at once, no round trip waits):
/// 1. Each side sends `authHello` in the clear: role, long-term Ed25519
///    identity key, fresh X25519 key.
/// 2. On the peer's `authHello`: X25519 shared secret -> HKDF-SHA256 (salt =
///    SHA-256 transcript of both hellos, host first) -> one AES-256 key per
///    direction. Everything sent from now on is encrypted.
/// 3. Each side sends `authProof`: an Ed25519 signature over the transcript and
///    its role. A valid proof means the peer holds the private key for the
///    identity it announced AND took part in this exact exchange (no relay).
/// 4. `verified(peer)`: the app decides whether it trusts that identity
///    (pinned key, first-use pairing or user confirmation). Until then, only
///    ping/pong/bye pass; the app keeps everything else gated on its own trust.
///
/// Frames: AES-GCM, nonce = stream type ‖ 0 0 0 ‖ sequence (unique per key,
/// since sequences strictly increase per stream and keys are per direction),
/// additional data = the encoded header (session ID, stream, sequence, flags,
/// timestamp, length). With `SequenceValidator`, replay and reordering fail.
///
/// Thread-safe: sending and receiving have separate locks, so sealing a large
/// video frame never waits for opening one (or the other way round). The
/// send key is the only state both sides touch, under `sendLock`.
public final class SecureChannel: @unchecked Sendable {
    public static let tagLength = 16

    public enum Error: Swift.Error, Equatable, Sendable {
        case expectedAuthHello
        case unexpectedAuthHello
        case incompatibleVersion(UInt16)
        case wrongRole
        case invalidKey
        case plaintextAfterHandshake
        case encryptedBeforeHandshake
        case decryptFailed
        case badProof
        case unexpectedProof
        case notVerified(StreamType)
        case notKeyed
        case payloadTooLarge
    }

    /// A peer whose proof verified. Trust is the app's decision.
    public struct Peer: Sendable, Equatable {
        public let identityKey: [UInt8]
        /// Short identifier for logs and UI: first 8 bytes of SHA-256(key), hex.
        public let fingerprint: String
        /// Six digits both sides derive from this connection's secret; shown
        /// on both screens during pairing ("123 456").
        public let pairingCode: String
    }

    public enum Incoming: Sendable {
        /// Consumed by the handshake; nothing to do.
        case none
        /// Keys are ready: send this control payload (our proof) now.
        case sendProof([UInt8])
        /// The peer proved its identity.
        case verified(Peer)
        /// A decrypted application frame.
        case message(Frame)
    }

    public let role: PeerRole
    private let identity: Curve25519.Signing.PrivateKey
    private let ephemeral: Curve25519.KeyAgreement.PrivateKey
    private let localHello: AuthHello
    private let lock = NSLock()      // receive side and handshake state
    private let sendLock = NSLock()  // sendKey, sentHello
    private var sendKey: SymmetricKey?
    private var receiveKey: SymmetricKey?
    private var transcript: Data?
    private var peerHello: AuthHello?
    private var pairingCode = ""
    private var verifiedPeer: Peer?
    private var sentHello = false

    public convenience init(role: PeerRole, identity: Curve25519.Signing.PrivateKey) {
        self.init(role: role, identity: identity, ephemeral: Curve25519.KeyAgreement.PrivateKey())
    }

    /// A fixed ephemeral key makes the handshake reproducible. Protocol test
    /// vectors only (`ProtocolVectorTests`); product code always uses a fresh key.
    init(role: PeerRole, identity: Curve25519.Signing.PrivateKey, ephemeral: Curve25519.KeyAgreement.PrivateKey) {
        self.role = role
        self.identity = identity
        self.ephemeral = ephemeral
        localHello = AuthHello(role: role, identityKey: Array(identity.publicKey.rawRepresentation),
                               ephemeralKey: Array(ephemeral.publicKey.rawRepresentation))
    }

    /// Our first frame's control payload (sent in the clear).
    public var authHelloPayload: [UInt8] { SessionCodec.encode(.authHello(localHello)) }

    public var peer: Peer? { lock.withLock { verifiedPeer } }

    // MARK: send

    /// Builds the wire bytes for one frame. Before the peer's hello arrives,
    /// only our own `authHello` may go out (in the clear); afterwards every
    /// frame is encrypted.
    public func wire(stream: StreamType, keyframe: Bool, sessionID: UInt64, sequence: UInt64,
                     timestampNanos: UInt64, payload: [UInt8]) throws -> [UInt8] {
        try sendLock.withLock {
            // Our authHello always goes in the clear, even if the peer's hello
            // already arrived (keys exist) before we sent ours.
            if !sentHello, stream == .control, payload == authHelloPayload {
                sentHello = true
                return try Frame(stream: stream, sessionID: sessionID, sequence: sequence,
                                 timestampNanos: timestampNanos, payload: payload).encoded()
            }
            guard let key = sendKey, sentHello else { throw Error.notKeyed }
            guard payload.count <= Int(stream.maxPayloadLength) - Self.tagLength else { throw Error.payloadTooLarge }
            var flags: FrameFlags = [.authenticated]
            if keyframe { flags.insert(.keyframe) }
            let header = FrameHeader(stream: stream, flags: flags, sessionID: sessionID, sequence: sequence,
                                     timestampNanos: timestampNanos,
                                     payloadLength: UInt32(payload.count + Self.tagLength))
            let headerBytes = try header.encoded()
            let box = try AES.GCM.seal(payload, using: key, nonce: Self.nonce(stream, sequence),
                                       authenticating: headerBytes)
            var out = [UInt8]()
            out.reserveCapacity(headerBytes.count + payload.count + Self.tagLength)
            out.append(contentsOf: headerBytes)
            out.append(contentsOf: box.ciphertext)
            out.append(contentsOf: box.tag)
            return out
        }
    }

    // MARK: receive

    /// Every frame from the peer goes through here, in order, after
    /// `SequenceValidator`. Throws on anything the protocol does not allow;
    /// the caller must then close the connection.
    public func receive(_ frame: Frame) throws -> Incoming {
        try lock.withLock {
            guard let key = receiveKey else {
                guard !frame.header.flags.contains(.authenticated) else { throw Error.encryptedBeforeHandshake }
                guard frame.header.stream == .control,
                      case .authHello(let hello) = try SessionCodec.decodeControl(frame.payload) else {
                    throw Error.expectedAuthHello
                }
                return .sendProof(try keyed(with: hello))
            }
            guard frame.header.flags.contains(.authenticated) else { throw Error.plaintextAfterHandshake }
            let length = frame.payload.count
            guard length >= Self.tagLength else { throw Error.decryptFailed }
            let plaintext: [UInt8]
            do {
                let box = try AES.GCM.SealedBox(nonce: Self.nonce(frame.header.stream, frame.header.sequence),
                                                ciphertext: frame.payload[0..<(length - Self.tagLength)],
                                                tag: frame.payload[(length - Self.tagLength)...])
                plaintext = Array(try AES.GCM.open(box, using: key, authenticating: try frame.header.encoded()))
            } catch {
                throw Error.decryptFailed
            }
            var header = frame.header
            header.flags.remove(.authenticated)
            header.payloadLength = UInt32(plaintext.count)
            let opened = Frame(header: header, payload: plaintext)

            if header.stream == .control {
                switch try SessionCodec.decodeControl(plaintext) {
                case .authHello:
                    throw Error.unexpectedAuthHello
                case .authProof(let signature):
                    return .verified(try verify(signature))
                case .ping, .pong, .bye:
                    return .message(opened)
                default:
                    break
                }
            }
            guard verifiedPeer != nil else { throw Error.notVerified(header.stream) }
            return .message(opened)
        }
    }

    // MARK: handshake internals (lock held)

    private func keyed(with hello: AuthHello) throws -> [UInt8] {
        guard hello.protocolVersion == SessionConstants.protocolVersion else {
            throw Error.incompatibleVersion(hello.protocolVersion)
        }
        guard hello.role != role else { throw Error.wrongRole }
        guard hello.ephemeralKey != localHello.ephemeralKey,
              let peerEphemeral = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: hello.ephemeralKey),
              (try? Curve25519.Signing.PublicKey(rawRepresentation: hello.identityKey)) != nil,
              let shared = try? ephemeral.sharedSecretFromKeyAgreement(with: peerEphemeral) else {
            throw Error.invalidKey
        }
        // A low-order peer key yields an all-zero secret: refuse it.
        guard shared.withUnsafeBytes({ $0.contains { $0 != 0 } }) else { throw Error.invalidKey }

        let host = role == .host ? localHello : hello
        let client = role == .host ? hello : localHello
        var hasher = SHA256()
        hasher.update(data: Array("WiredDisplay auth v2".utf8))
        hasher.update(data: SessionCodec.encode(.authHello(host)))
        hasher.update(data: SessionCodec.encode(.authHello(client)))
        let digest = Data(hasher.finalize())

        func derive(_ label: String, bytes: Int = 32) -> SymmetricKey {
            shared.hkdfDerivedSymmetricKey(using: SHA256.self, salt: digest, sharedInfo: Data(label.utf8),
                                           outputByteCount: bytes)
        }
        let hostToClient = derive("host->client"), clientToHost = derive("client->host")
        sendLock.withLock { sendKey = role == .host ? hostToClient : clientToHost }
        receiveKey = role == .host ? clientToHost : hostToClient
        let code = derive("pairing code", bytes: 8).withUnsafeBytes { raw in
            raw.reduce(UInt64(0)) { $0 << 8 | UInt64($1) } % 1_000_000
        }
        let digits = String(format: "%06llu", code)
        pairingCode = "\(digits.prefix(3)) \(digits.suffix(3))"
        transcript = digest
        peerHello = hello

        let signature = try identity.signature(for: Self.proofMessage(role: role, transcript: digest))
        return SessionCodec.encode(.authProof(Array(signature)))
    }

    private func verify(_ signature: [UInt8]) throws -> Peer {
        guard verifiedPeer == nil, let transcript, let peerHello else { throw Error.unexpectedProof }
        guard let key = try? Curve25519.Signing.PublicKey(rawRepresentation: peerHello.identityKey),
              key.isValidSignature(signature, for: Self.proofMessage(role: peerHello.role, transcript: transcript)) else {
            throw Error.badProof
        }
        let peer = Peer(identityKey: peerHello.identityKey, fingerprint: Self.fingerprint(peerHello.identityKey),
                        pairingCode: pairingCode)
        verifiedPeer = peer
        return peer
    }

    private static func proofMessage(role: PeerRole, transcript: Data) -> Data {
        Data("WiredDisplay proof v2".utf8) + [role.rawValue] + transcript
    }

    public static func fingerprint(_ key: [UInt8]) -> String {
        SHA256.hash(data: key).prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    private static func nonce(_ stream: StreamType, _ sequence: UInt64) throws -> AES.GCM.Nonce {
        var raw: (UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8) = (
            stream.rawValue, 0, 0, 0,
            UInt8(truncatingIfNeeded: sequence >> 56),
            UInt8(truncatingIfNeeded: sequence >> 48),
            UInt8(truncatingIfNeeded: sequence >> 40),
            UInt8(truncatingIfNeeded: sequence >> 32),
            UInt8(truncatingIfNeeded: sequence >> 24),
            UInt8(truncatingIfNeeded: sequence >> 16),
            UInt8(truncatingIfNeeded: sequence >> 8),
            UInt8(truncatingIfNeeded: sequence)
        )
        return try withUnsafeBytes(of: &raw) { try AES.GCM.Nonce(data: $0) }
    }
}
