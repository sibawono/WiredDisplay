import CryptoKit
import Foundation
import XCTest
import WDProtocol
@testable import WDSession

/// The real Swift code against golden vectors (`Tests/Vectors/protocol-v6.json`),
/// which `scripts/gen-protocol-vectors.py` computes independently from the
/// protocol description. Any other client (Android) must match the same file.
/// A change to the wire format fails here until the vectors are regenerated
/// on purpose, together with a protocol version bump.
final class ProtocolVectorTests: XCTestCase {
    // MARK: vectors

    private struct Vectors {
        let root: [String: Any]

        static func load() throws -> Vectors {
            let url = URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent() // WDSessionTests
                .deletingLastPathComponent() // Unit
                .deletingLastPathComponent() // Tests
                .appendingPathComponent("Vectors/protocol-v6.json")
            let object = try JSONSerialization.jsonObject(with: Data(contentsOf: url))
            return Vectors(root: try XCTUnwrap(object as? [String: Any], "vectors are not a JSON object"))
        }

        func section(_ name: String) throws -> [String: Any] {
            try XCTUnwrap(root[name] as? [String: Any], "missing section \(name)")
        }

        func string(_ section: String, _ key: String) throws -> String {
            try XCTUnwrap(try self.section(section)[key] as? String, "missing \(section).\(key)")
        }

        func bytes(_ section: String, _ key: String) throws -> [UInt8] {
            try ProtocolVectorTests.hex(try string(section, key))
        }

        func u64(_ section: String, _ key: String) throws -> UInt64 {
            try XCTUnwrap(UInt64(try string(section, key), radix: 16), "\(section).\(key) is not hex")
        }
    }

    private static func hex(_ text: String) throws -> [UInt8] {
        let digits = Array(text.utf8)
        guard digits.count % 2 == 0 else { throw WireError.invalidValue("odd hex length") }
        return try stride(from: 0, to: digits.count, by: 2).map { index in
            guard let byte = UInt8(String(decoding: digits[index...index + 1], as: UTF8.self), radix: 16) else {
                throw WireError.invalidValue("bad hex")
            }
            return byte
        }
    }

    /// Exactly one frame, parsed by the real parser (header decoding included).
    private func frame(_ wire: [UInt8]) throws -> Frame {
        var parser = FrameParser()
        try parser.append(wire)
        let frame = try XCTUnwrap(try parser.next(), "incomplete frame")
        XCTAssertNil(try parser.next())
        return frame
    }

    private func bytes(_ key: SymmetricKey) -> [UInt8] { key.withUnsafeBytes { Array($0) } }

    // MARK: messages

    private static let controlMessages: [String: ControlMessage] = [
        "hello": .hello(Hello(protocolVersion: 6, role: .client, deviceName: "Tab \u{DC}n\u{EF} 11", pixelWidth: 2560,
                              pixelHeight: 1600, scale: 2, maxRefreshHz: 120, codecs: [.h264, .hevc], pixelsPerInch: 274)),
        "streamConfig": .streamConfig(StreamConfig(pixelWidth: 2560, pixelHeight: 1600, pointWidth: 1440, pointHeight: 900,
                                                   refreshHz: 60, codec: .hevc)),
        "requestKeyframe": .requestKeyframe,
        "ping": .ping(0xFEDC_BA98_7654_3210),
        "pong": .pong(0x0123_4567_89AB_CDEF),
        "bye": .bye("selesai"),
        "audioRoute_speaker": .audioRoute(speaker: true, microphone: false),
        "audioRoute_both": .audioRoute(speaker: true, microphone: true),
        "videoActive_false": .videoActive(false),
        "decodeFailed": .decodeFailed,
        "brightness": .brightness(0.75),
        "cursor": .cursor(x: 0.25, y: 0.5, visible: true),
        "cursorImage": .cursorImage(CursorImage(png: [0x89, 0x50, 0x4E, 0x47], width: 0.015625, height: 0.03125,
                                                hotX: 0.125, hotY: 0)),
        "panelSize": .panelSize(width: 1600, height: 2560),
    ]

    private static let inputEvents: [String: InputEvent] = [
        "pointer_move": .pointer(phase: .move, button: .none, x: 0.5, y: 0.25),
        "pointer_down_left": .pointer(phase: .down, button: .left, x: 1, y: 0),
        "pointer_up_right": .pointer(phase: .up, button: .right, x: 0.125, y: 0.875),
        "scroll": .scroll(dx: -12.5, dy: 40),
        "releaseAll": .releaseAll,
        "key_a_down": .key(usage: 0x04, down: true),
        "key_rightCommand_up": .key(usage: 0xE7, down: false),
        "gestureScroll_changed": .gestureScroll(dx: 1.5, dy: -3, phase: .changed, momentum: .none),
        "gestureScroll_momentum": .gestureScroll(dx: 0, dy: 6.25, phase: .none, momentum: .continue),
        "magnify_began": .magnify(delta: 0.0625, phase: .began),
        "rotate_ended": .rotate(degrees: -15, phase: .ended),
    ]

    func testControlMessagesMatchVectors() throws {
        let vectors = try Vectors.load()
        let names = Set(try vectors.section("control").keys)
        XCTAssertEqual(names, Set(Self.controlMessages.keys).union(["hello_name_truncated"]), "every vector is checked")
        for (name, message) in Self.controlMessages {
            let expected = try vectors.bytes("control", name)
            XCTAssertEqual(SessionCodec.encode(message), expected, "encode \(name)")
            XCTAssertEqual(try SessionCodec.decodeControl(expected), message, "decode \(name)")
        }
        // A 40-character, 80-byte name is cut to whole characters within 64 bytes.
        let long = Hello(protocolVersion: 6, role: .client, deviceName: String(repeating: "\u{E9}", count: 40),
                         pixelWidth: 2400, pixelHeight: 1080, scale: 3, maxRefreshHz: 90, codecs: [.h264])
        let expected = try vectors.bytes("control", "hello_name_truncated")
        XCTAssertEqual(SessionCodec.encode(.hello(long)), expected)
        var cut = long
        cut.deviceName = String(repeating: "\u{E9}", count: 32)
        XCTAssertEqual(try SessionCodec.decodeControl(expected), .hello(cut))
    }

    func testInputEventsMatchVectors() throws {
        let vectors = try Vectors.load()
        XCTAssertEqual(Set(try vectors.section("input").keys), Set(Self.inputEvents.keys), "every vector is checked")
        for (name, event) in Self.inputEvents {
            let expected = try vectors.bytes("input", name)
            XCTAssertEqual(SessionCodec.encode(event), expected, "encode \(name)")
            XCTAssertEqual(try SessionCodec.decodeInput(expected), event, "decode \(name)")
        }
    }

    func testAudioPacketsAreLittleEndian() throws {
        let audio = try Vectors.load().section("audio")
        XCTAssertEqual(audio.count, 2)
        for (name, value) in audio {
            let entry = try XCTUnwrap(value as? [String: Any])
            let channels = UInt8(try XCTUnwrap(entry["channels"] as? Int))
            let samples = try XCTUnwrap(entry["samples"] as? [Int]).map { Int16($0) }
            let expected = try Self.hex(try XCTUnwrap(entry["hex"] as? String))
            let packet = AudioPacket(channels: channels, samples: samples)
            XCTAssertEqual(packet.encoded(), expected, "encode \(name)")
            XCTAssertEqual(try AudioPacket.decode(expected, expectedChannels: channels), packet, "decode \(name)")
        }
    }

    // MARK: handshake

    func testKeyDerivationMatchesVectors() throws {
        let vectors = try Vectors.load()
        let host = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: try vectors.bytes("keys", "hostEphemeralPrivate"))
        let client = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: try vectors.bytes("keys", "clientEphemeralPublic"))
        XCTAssertEqual(Array(host.publicKey.rawRepresentation), try vectors.bytes("keys", "hostEphemeralPublic"))
        let shared = try host.sharedSecretFromKeyAgreement(with: client)
        XCTAssertEqual(shared.withUnsafeBytes { Array($0) }, try vectors.bytes("handshake", "sharedSecret"))

        let transcript = try vectors.bytes("handshake", "transcript")
        var hasher = SHA256()
        hasher.update(data: Array("WiredDisplay auth v2".utf8))
        hasher.update(data: try vectors.bytes("handshake", "hostAuthHelloPayload"))
        hasher.update(data: try vectors.bytes("handshake", "clientAuthHelloPayload"))
        XCTAssertEqual(Array(hasher.finalize()), transcript)

        func derive(_ label: String, _ count: Int) -> [UInt8] {
            bytes(shared.hkdfDerivedSymmetricKey(using: SHA256.self, salt: transcript, sharedInfo: Data(label.utf8),
                                                 outputByteCount: count))
        }
        XCTAssertEqual(derive("host->client", 32), try vectors.bytes("handshake", "hostToClientKey"))
        XCTAssertEqual(derive("client->host", 32), try vectors.bytes("handshake", "clientToHostKey"))
        XCTAssertEqual(derive("pairing code", 8), try vectors.bytes("handshake", "pairingCodeBytes"))
        // The vector was chosen so a signed 64-bit modulo would be wrong.
        let value = derive("pairing code", 8).reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
        XCTAssertGreaterThanOrEqual(value, UInt64(1) << 63)
        XCTAssertEqual(String(value), try vectors.string("handshake", "pairingCodeUnsigned"))
    }

    func testHostSideOfTheHandshakeMatchesVectors() throws {
        let vectors = try Vectors.load()
        let identity = try Curve25519.Signing.PrivateKey(rawRepresentation: try vectors.bytes("keys", "hostIdentitySeed"))
        let ephemeral = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: try vectors.bytes("keys", "hostEphemeralPrivate"))
        let host = SecureChannel(role: .host, identity: identity, ephemeral: ephemeral)
        let session = try vectors.u64("session", "hostSessionID"), ts = try vectors.u64("session", "baseTimestamp")

        XCTAssertEqual(host.authHelloPayload, try vectors.bytes("handshake", "hostAuthHelloPayload"))
        XCTAssertEqual(try host.wire(stream: .control, keyframe: false, sessionID: session, sequence: 0, timestampNanos: ts,
                                     payload: host.authHelloPayload),
                       try vectors.bytes("frames", "host_auth_hello"))

        guard case .sendProof(let proof) = try host.receive(try frame(try vectors.bytes("frames", "client_auth_hello"))) else {
            return XCTFail("the client's hello did not key the channel")
        }
        guard case .authProof(let signature) = try SessionCodec.decodeControl(proof) else { return XCTFail("not a proof") }
        XCTAssertTrue(identity.publicKey.isValidSignature(signature, for: try vectors.bytes("handshake", "hostProofMessage")))

        guard case .verified(let peer) = try host.receive(try frame(try vectors.bytes("frames", "client_proof"))) else {
            return XCTFail("the client's proof was not accepted")
        }
        XCTAssertEqual(peer.identityKey, try vectors.bytes("keys", "clientIdentityPublic"))
        XCTAssertEqual(peer.fingerprint, try vectors.string("handshake", "clientFingerprint"))
        XCTAssertEqual(peer.pairingCode, try vectors.string("handshake", "pairingCode"))

        XCTAssertEqual(try host.wire(stream: .control, keyframe: false, sessionID: session, sequence: 2, timestampNanos: ts + 2,
                                     payload: try vectors.bytes("framePlaintexts", "host_ping")),
                       try vectors.bytes("frames", "host_ping"))
        XCTAssertEqual(try host.wire(stream: .video, keyframe: true, sessionID: session,
                                     sequence: try vectors.u64("session", "videoSequence"), timestampNanos: ts + 3,
                                     payload: try vectors.bytes("framePlaintexts", "host_video_keyframe")),
                       try vectors.bytes("frames", "host_video_keyframe"))

        for (name, stream) in [("client_input", StreamType.input), ("client_microphone", StreamType.microphone)] {
            guard case .message(let opened) = try host.receive(try frame(try vectors.bytes("frames", name))) else {
                return XCTFail("\(name) did not open")
            }
            XCTAssertEqual(opened.header.stream, stream)
            XCTAssertEqual(opened.header.flags, [])
            XCTAssertEqual(opened.payload, try vectors.bytes("framePlaintexts", name))
        }
    }

    func testClientSideOfTheHandshakeMatchesVectors() throws {
        let vectors = try Vectors.load()
        let identity = try Curve25519.Signing.PrivateKey(rawRepresentation: try vectors.bytes("keys", "clientIdentitySeed"))
        let ephemeral = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: try vectors.bytes("keys", "clientEphemeralPrivate"))
        let client = SecureChannel(role: .client, identity: identity, ephemeral: ephemeral)
        let session = try vectors.u64("session", "clientSessionID"), ts = try vectors.u64("session", "baseTimestamp")

        XCTAssertEqual(client.authHelloPayload, try vectors.bytes("handshake", "clientAuthHelloPayload"))
        XCTAssertEqual(try client.wire(stream: .control, keyframe: false, sessionID: session, sequence: 0,
                                       timestampNanos: ts + 10, payload: client.authHelloPayload),
                       try vectors.bytes("frames", "client_auth_hello"))

        guard case .sendProof(let proof) = try client.receive(try frame(try vectors.bytes("frames", "host_auth_hello"))) else {
            return XCTFail("the host's hello did not key the channel")
        }
        guard case .authProof(let signature) = try SessionCodec.decodeControl(proof) else { return XCTFail("not a proof") }
        XCTAssertTrue(identity.publicKey.isValidSignature(signature, for: try vectors.bytes("handshake", "clientProofMessage")))

        guard case .verified(let peer) = try client.receive(try frame(try vectors.bytes("frames", "host_proof"))) else {
            return XCTFail("the host's proof was not accepted")
        }
        XCTAssertEqual(peer.identityKey, try vectors.bytes("keys", "hostIdentityPublic"))
        XCTAssertEqual(peer.fingerprint, try vectors.string("handshake", "hostFingerprint"))
        XCTAssertEqual(peer.pairingCode, try vectors.string("handshake", "pairingCode"))

        XCTAssertEqual(try client.wire(stream: .input, keyframe: false, sessionID: session, sequence: 0, timestampNanos: ts + 12,
                                       payload: try vectors.bytes("framePlaintexts", "client_input")),
                       try vectors.bytes("frames", "client_input"))
        XCTAssertEqual(try client.wire(stream: .microphone, keyframe: false, sessionID: session, sequence: 0,
                                       timestampNanos: ts + 13, payload: try vectors.bytes("framePlaintexts", "client_microphone")),
                       try vectors.bytes("frames", "client_microphone"))

        guard case .message(let ping) = try client.receive(try frame(try vectors.bytes("frames", "host_ping"))) else {
            return XCTFail("host_ping did not open")
        }
        XCTAssertEqual(ping.payload, try vectors.bytes("framePlaintexts", "host_ping"))
        guard case .message(let video) = try client.receive(try frame(try vectors.bytes("frames", "host_video_keyframe"))) else {
            return XCTFail("host_video_keyframe did not open")
        }
        XCTAssertEqual(video.header.flags, [.keyframe])
        XCTAssertEqual(video.header.sequence, try vectors.u64("session", "videoSequence"))
        XCTAssertEqual(video.payload, try vectors.bytes("framePlaintexts", "host_video_keyframe"))
    }

    /// One flipped bit in the ciphertext must close the connection (decrypt fails).
    func testTamperedVectorFrameIsRejected() throws {
        let vectors = try Vectors.load()
        let identity = try Curve25519.Signing.PrivateKey(rawRepresentation: try vectors.bytes("keys", "hostIdentitySeed"))
        let ephemeral = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: try vectors.bytes("keys", "hostEphemeralPrivate"))
        let host = SecureChannel(role: .host, identity: identity, ephemeral: ephemeral)
        _ = try host.wire(stream: .control, keyframe: false, sessionID: 1, sequence: 0, timestampNanos: 0,
                          payload: host.authHelloPayload)
        _ = try host.receive(try frame(try vectors.bytes("frames", "client_auth_hello")))
        _ = try host.receive(try frame(try vectors.bytes("frames", "client_proof")))
        var wire = try vectors.bytes("frames", "client_input")
        wire[FrameHeader.encodedLength] ^= 0x01
        XCTAssertThrowsError(try host.receive(try frame(wire))) { error in
            XCTAssertEqual(error as? SecureChannel.Error, .decryptFailed)
        }
    }
}
