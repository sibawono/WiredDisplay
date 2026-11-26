import CryptoKit
import XCTest
import WDProtocol
@testable import WDSession

/// D-023: handshake, encryption, tamper and replay defence, trust storage.
final class SecureChannelTests: XCTestCase {
    /// One side of a connection: channel + framer + parser + validator, as
    /// FramedSocket and the iPad client use them.
    final class End {
        let channel: SecureChannel
        var framer: SessionFramer
        var parser = FrameParser()
        var validator: SequenceValidator?
        var verified: SecureChannel.Peer?
        var messages: [Frame] = []
        var outbox: [[UInt8]] = []

        init(_ role: PeerRole, identity: Curve25519.Signing.PrivateKey = .init(), session: UInt64) {
            channel = SecureChannel(role: role, identity: identity)
            framer = SessionFramer(sessionID: session, channel: channel, clock: { 42 })
        }

        func sendHello() throws { outbox.append(try framer.frame(.control, payload: channel.authHelloPayload)) }

        func send(_ stream: StreamType, _ payload: [UInt8], keyframe: Bool = false) throws {
            outbox.append(try framer.frame(stream, payload: payload, keyframe: keyframe))
        }

        /// Feeds wire bytes; proofs are queued in our outbox like the socket does.
        func receive(_ wire: [UInt8]) throws {
            try parser.append(wire)
            while let frame = try parser.next() {
                if validator == nil { validator = SequenceValidator(sessionID: frame.header.sessionID) }
                try validator?.accept(frame.header)
                switch try channel.receive(frame) {
                case .none: break
                case .sendProof(let proof): outbox.append(try framer.frame(.control, payload: proof))
                case .verified(let peer): verified = peer
                case .message(let opened): messages.append(opened)
                }
            }
        }

        func flush(to other: End) throws {
            let pending = outbox
            outbox = []
            for wire in pending { try other.receive(wire) }
        }
    }

    private func handshake() throws -> (End, End) {
        let host = End(.host, session: 1), client = End(.client, session: 2)
        try host.sendHello()
        try client.sendHello()
        try host.flush(to: client)   // host hello -> client keyed, client proof queued
        try client.flush(to: host)   // client hello + proof -> host keyed + verified, host proof queued
        try host.flush(to: client)   // host proof -> client verified
        return (host, client)
    }

    func testHandshakeVerifiesBothSidesWithMatchingCodes() throws {
        let (host, client) = try handshake()
        let hostSeesClient = try XCTUnwrap(host.verified)
        let clientSeesHost = try XCTUnwrap(client.verified)
        XCTAssertEqual(hostSeesClient.pairingCode, clientSeesHost.pairingCode)
        XCTAssertEqual(hostSeesClient.pairingCode.count, 7) // "123 456"
        XCTAssertEqual(hostSeesClient.identityKey, Array(client.channel.authHelloPayload[4..<36]))
        XCTAssertNotEqual(hostSeesClient.identityKey, clientSeesHost.identityKey)
    }

    func testFramesAreEncryptedAndDecryptBothWays() throws {
        let (host, client) = try handshake()
        let secret: [UInt8] = Array("the Mac's screen".utf8)
        try host.send(.video, secret, keyframe: true)
        let wire = try XCTUnwrap(host.outbox.first)
        XCTAssertNil(wire.firstRange(of: secret), "plaintext must not appear on the wire")
        try host.flush(to: client)
        XCTAssertEqual(client.messages.last?.payload, secret)
        XCTAssertEqual(client.messages.last?.header.flags, [.keyframe])

        try client.send(.input, SessionCodec.encode(.releaseAll))
        try client.flush(to: host)
        XCTAssertEqual(try SessionCodec.decodeInput(try XCTUnwrap(host.messages.last).payload), .releaseAll)
    }

    func testTamperedPayloadOrHeaderIsRejected() throws {
        for index in [10, 20, FrameHeader.encodedLength + 2] { // timestamp, sequence region, ciphertext
            let (host, client) = try handshake()
            try host.send(.video, [1, 2, 3, 4], keyframe: false)
            var wire = host.outbox.removeFirst()
            wire[index] ^= 0x01
            XCTAssertThrowsError(try client.receive(wire), "byte \(index)")
        }
    }

    func testReplayedFrameIsRejected() throws {
        let (host, client) = try handshake()
        try host.send(.video, [9, 9, 9])
        let wire = host.outbox[0]
        try host.flush(to: client)
        XCTAssertThrowsError(try client.receive(wire)) // same sequence again
    }

    func testPlaintextFrameAfterHandshakeIsRejected() throws {
        let (_, client) = try handshake()
        let plain = try Frame(stream: .input, sessionID: 1, sequence: 99, timestampNanos: 0,
                              payload: SessionCodec.encode(.releaseAll)).encoded()
        XCTAssertThrowsError(try client.receive(plain)) {
            XCTAssertEqual($0 as? SecureChannel.Error, .plaintextAfterHandshake)
        }
    }

    func testFirstFrameMustBeAuthHello() throws {
        let client = End(.client, session: 2)
        let hello = SessionCodec.encode(.hello(Hello(role: .host, deviceName: "Mac", pixelWidth: 1, pixelHeight: 1,
                                                     scale: 1, maxRefreshHz: 60, codecs: [.h264])))
        let wire = try Frame(stream: .control, sessionID: 1, sequence: 0, timestampNanos: 0, payload: hello).encoded()
        XCTAssertThrowsError(try client.receive(wire)) { XCTAssertEqual($0 as? SecureChannel.Error, .expectedAuthHello) }
    }

    func testNothingButPingPongByePassesBeforeProof() throws {
        let host = End(.host, session: 1), client = End(.client, session: 2)
        try host.sendHello()
        try client.sendHello()
        try host.flush(to: client)            // client keyed; its hello + proof queued
        XCTAssertThrowsError(try host.send(.video, [1])) // host not keyed yet: nothing can be sealed
        try client.flush(to: host)            // host keyed and verified
        host.outbox = []                      // the host's proof never reaches the client
        try host.send(.control, SessionCodec.encode(.ping(7)))
        try host.flush(to: client)
        XCTAssertEqual(client.messages.count, 1, "ping passes before verification")
        XCTAssertNil(client.verified)
        try host.send(.video, [1, 2, 3])
        XCTAssertThrowsError(try host.flush(to: client)) {
            XCTAssertEqual($0 as? SecureChannel.Error, .notVerified(.video))
        }
    }

    func testImpostorWithStolenPublicKeyIsRejected() throws {
        // The attacker announces the real iPad's public identity key but only
        // holds its own private key.
        let realIPad = Curve25519.Signing.PrivateKey()
        let attacker = End(.client, session: 2)
        let host = End(.host, session: 1)
        try attacker.sendHello()                     // control #0, replaced below
        let genuine = attacker.outbox.removeFirst()
        guard case .authHello(var hello) = try SessionCodec.decodeControl(Array(genuine[FrameHeader.encodedLength...])) else {
            return XCTFail("no hello")
        }
        hello.identityKey = Array(realIPad.publicKey.rawRepresentation)
        let forged = try Frame(stream: .control, sessionID: 2, sequence: 0, timestampNanos: 0,
                               payload: SessionCodec.encode(.authHello(hello))).encoded()
        try host.sendHello()
        try host.flush(to: attacker)                 // attacker keys up and queues its proof (#1)
        try host.receive(forged)                     // host keys up on the forged hello
        XCTAssertThrowsError(try attacker.flush(to: host)) // proof cannot be accepted
        XCTAssertNil(host.verified)
    }

    func testWrongRoleAndBadVersionAreRejected() throws {
        let a = End(.host, session: 1), b = End(.host, session: 2)
        try a.sendHello()
        XCTAssertThrowsError(try a.flush(to: b)) { XCTAssertEqual($0 as? SecureChannel.Error, .wrongRole) }

        let client = End(.client, session: 3)
        var hello = AuthHello(role: .host, identityKey: Array(Curve25519.Signing.PrivateKey().publicKey.rawRepresentation),
                              ephemeralKey: Array(Curve25519.KeyAgreement.PrivateKey().publicKey.rawRepresentation))
        hello.protocolVersion = 1
        let wire = try Frame(stream: .control, sessionID: 1, sequence: 0, timestampNanos: 0,
                             payload: SessionCodec.encode(.authHello(hello))).encoded()
        XCTAssertThrowsError(try client.receive(wire)) { XCTAssertEqual($0 as? SecureChannel.Error, .incompatibleVersion(1)) }
    }

    func testAllZeroEphemeralKeyIsRejected() throws {
        let client = End(.client, session: 3)
        let hello = AuthHello(role: .host, identityKey: Array(Curve25519.Signing.PrivateKey().publicKey.rawRepresentation),
                              ephemeralKey: [UInt8](repeating: 0, count: 32))
        let wire = try Frame(stream: .control, sessionID: 1, sequence: 0, timestampNanos: 0,
                             payload: SessionCodec.encode(.authHello(hello))).encoded()
        XCTAssertThrowsError(try client.receive(wire)) { XCTAssertEqual($0 as? SecureChannel.Error, .invalidKey) }
    }

    func testOversizedPayloadIsRefusedBeforeSealing() throws {
        let (host, _) = try handshake()
        let tooBig = [UInt8](repeating: 0, count: Int(StreamType.input.maxPayloadLength) - SecureChannel.tagLength + 1)
        XCTAssertThrowsError(try host.send(.input, tooBig))
    }

    func testTrustStorePersistsIdentityAndPeers() throws {
        let storage = MemoryStorage()
        let store = TrustStore(storage: storage)
        let identity = try store.identity()
        XCTAssertEqual(try TrustStore(storage: storage).identity().rawRepresentation, identity.rawRepresentation)
        let key = Array(Curve25519.Signing.PrivateKey().publicKey.rawRepresentation)
        XCTAssertFalse(store.isTrusted(key))
        try store.trust(key, name: "iPad")
        store.rename(key, to: "Test iPad")
        let reopened = TrustStore(storage: storage)
        XCTAssertTrue(reopened.isTrusted(key))
        XCTAssertEqual(reopened.peers.map(\.name), ["Test iPad"])
        reopened.forgetAllPeers()
        XCTAssertFalse(store.isTrusted(key))
        XCTAssertEqual(try store.identity().rawRepresentation, identity.rawRepresentation, "forget keeps our identity")
    }
}

/// R-INP-02: keyboard and trackpad-scroll events.
final class KeyboardAndScrollCodecTests: XCTestCase {
    func testKeyAndGestureScrollRoundTrip() throws {
        let events: [InputEvent] = [
            .key(usage: 0x04, down: true), .key(usage: 0xE7, down: false),
            .gestureScroll(dx: 0, dy: 0, phase: .began, momentum: .none),
            .gestureScroll(dx: -12.5, dy: 300, phase: .changed, momentum: .none),
            .gestureScroll(dx: 1, dy: 2, phase: .none, momentum: .continue),
        ]
        for event in events { XCTAssertEqual(try SessionCodec.decodeInput(SessionCodec.encode(event)), event) }
    }

    func testOutOfRangeKeyAndPhaseMixAreRejected() {
        for usage: UInt16 in [0, 3, 0xE8, 0xFFFF] {
            XCTAssertThrowsError(try SessionCodec.decodeInput(SessionCodec.encode(.key(usage: usage, down: true))))
        }
        XCTAssertThrowsError(try SessionCodec.decodeInput(
            SessionCodec.encode(.gestureScroll(dx: 0, dy: 0, phase: .changed, momentum: .begin))))
        var bytes = SessionCodec.encode(.key(usage: 4, down: true))
        bytes[3] = 2
        XCTAssertThrowsError(try SessionCodec.decodeInput(bytes))
    }

    func testKeyMapCoversLettersDigitsModifiersAndArrows() {
        XCTAssertEqual(KeyMap.virtualKey(forUsage: 0x04), 0x00) // A
        XCTAssertEqual(KeyMap.virtualKey(forUsage: 0x1D), 0x06) // Z
        XCTAssertEqual(KeyMap.virtualKey(forUsage: 0x27), 0x1D) // 0
        XCTAssertEqual(KeyMap.virtualKey(forUsage: 0x28), 0x24) // Return
        XCTAssertEqual(KeyMap.virtualKey(forUsage: 0x52), 0x7E) // Up
        XCTAssertEqual(KeyMap.virtualKey(forUsage: 0xE3), 0x37) // left Command
        XCTAssertEqual(KeyMap.modifier(forUsage: 0xE6), .option)
        XCTAssertNil(KeyMap.modifier(forUsage: 0x04))
        // Every letter and digit maps, to distinct keys.
        let codes = (0x04...0x27).compactMap { KeyMap.virtualKey(forUsage: UInt16($0)) }
        XCTAssertEqual(codes.count, 36)
        XCTAssertEqual(Set(codes).count, 36)
    }
}

final class TransformGestureTests: XCTestCase {
    func testMagnifyAndRotateRoundTripAndBounds() throws {
        let events: [InputEvent] = [
            .magnify(delta: 0, phase: .began), .magnify(delta: -0.125, phase: .changed),
            .magnify(delta: 0, phase: .ended), .rotate(degrees: 12.5, phase: .changed),
            .rotate(degrees: 0, phase: .cancelled),
        ]
        for event in events { XCTAssertEqual(try SessionCodec.decodeInput(SessionCodec.encode(event)), event) }
        for bad: InputEvent in [.magnify(delta: 5, phase: .changed), .magnify(delta: .nan, phase: .changed),
                                .rotate(degrees: 181, phase: .changed), .magnify(delta: 0.1, phase: .none)] {
            XCTAssertThrowsError(try SessionCodec.decodeInput(SessionCodec.encode(bad)))
        }
    }

    func testTrackerTurnsCumulativeValuesIntoDeltas() throws {
        var tracker = TransformTracker()
        XCTAssertEqual(tracker.beganPinch(), .magnify(delta: 0, phase: .began))
        XCTAssertEqual(tracker.pinch(scale: 1.25), .magnify(delta: 0.25, phase: .changed))
        XCTAssertEqual(tracker.pinch(scale: 1.0), .magnify(delta: -0.25, phase: .changed))
        XCTAssertNil(tracker.pinch(scale: 1.0))
        XCTAssertNil(tracker.pinch(scale: 0))
        _ = tracker.beganRotation()
        // UIKit clockwise positive -> macOS counterclockwise positive.
        guard case .rotate(let degrees, .changed)? = tracker.rotation(radians: .pi / 2) else { return XCTFail() }
        XCTAssertEqual(degrees, -90, accuracy: 0.001)
        guard case .rotate(let back, .changed)? = tracker.rotation(radians: 0) else { return XCTFail() }
        XCTAssertEqual(back, 90, accuracy: 0.001)
    }
}

final class ShortcutRemapperTests: XCTestCase {
    private let control: UInt16 = 0xE0, shift: UInt16 = 0xE1, command: UInt16 = 0xE3, tab: UInt16 = 0x2B

    func testControlTabBecomesCommandTabUntilControlIsReleased() {
        var remapper = ShortcutRemapper()
        XCTAssertEqual(remapper.key(usage: control, down: true), [.key(usage: control, down: true)])
        XCTAssertEqual(remapper.key(usage: tab, down: true),
                       [.key(usage: control, down: false), .key(usage: command, down: true), .key(usage: tab, down: true)])
        XCTAssertEqual(remapper.key(usage: tab, down: false), [.key(usage: tab, down: false)])
        // Second Tab while Control is still held: just Tab (Command is still down on the Mac).
        XCTAssertEqual(remapper.key(usage: tab, down: true), [.key(usage: tab, down: true)])
        XCTAssertEqual(remapper.key(usage: tab, down: false), [.key(usage: tab, down: false)])
        XCTAssertEqual(remapper.key(usage: control, down: false), [.key(usage: command, down: false)])
        XCTAssertFalse(remapper.isRemapping)
    }

    func testScreenshotNeedsShiftAndOtherControlShortcutsPassThrough() {
        var remapper = ShortcutRemapper()
        _ = remapper.key(usage: control, down: true)
        // Control-3 without Shift stays Control-3 (Mission Control / Spaces shortcuts).
        XCTAssertEqual(remapper.key(usage: 0x20, down: true), [.key(usage: 0x20, down: true)])
        _ = remapper.key(usage: 0x20, down: false)
        // Control-C stays Control-C (terminal interrupt).
        XCTAssertEqual(remapper.key(usage: 0x06, down: true), [.key(usage: 0x06, down: true)])
        _ = remapper.key(usage: 0x06, down: false)
        _ = remapper.key(usage: shift, down: true)
        XCTAssertEqual(remapper.key(usage: 0x21, down: true),
                       [.key(usage: control, down: false), .key(usage: command, down: true), .key(usage: 0x21, down: true)])
    }

    func testRealCommandIsLeftAlone() {
        var remapper = ShortcutRemapper()
        _ = remapper.key(usage: control, down: true)
        _ = remapper.key(usage: command, down: true)
        XCTAssertEqual(remapper.key(usage: 0x2C, down: true), [.key(usage: 0x2C, down: true)])
        XCTAssertFalse(remapper.isRemapping)
    }

    func testOptionShortcutsAndHideAppRemap() {
        let option: UInt16 = 0xE2, keyD: UInt16 = 0x07, keyH: UInt16 = 0x0B, esc: UInt16 = 0x29, space: UInt16 = 0x2C
        // Ctrl+D without Option stays Ctrl+D (EOF in terminal).
        var r1 = ShortcutRemapper()
        _ = r1.key(usage: control, down: true)
        XCTAssertEqual(r1.key(usage: keyD, down: true), [.key(usage: keyD, down: true)])
        XCTAssertFalse(r1.isRemapping)
        _ = r1.key(usage: keyD, down: false)
        // Ctrl+Opt+D -> Cmd+Opt+D (Show/Hide Dock).
        _ = r1.key(usage: option, down: true)
        XCTAssertEqual(r1.key(usage: keyD, down: true),
                       [.key(usage: control, down: false), .key(usage: command, down: true), .key(usage: keyD, down: true)])
        XCTAssertTrue(r1.isRemapping)

        // Ctrl+Opt+Esc -> Cmd+Opt+Esc (Force Quit).
        var r2 = ShortcutRemapper()
        _ = r2.key(usage: control, down: true)
        _ = r2.key(usage: option, down: true)
        XCTAssertEqual(r2.key(usage: esc, down: true),
                       [.key(usage: control, down: false), .key(usage: command, down: true), .key(usage: esc, down: true)])

        // Ctrl+H -> Cmd+H (Hide app) and Ctrl+Opt+Space -> Cmd+Opt+Space (Finder Search).
        var r3 = ShortcutRemapper()
        _ = r3.key(usage: control, down: true)
        XCTAssertEqual(r3.key(usage: keyH, down: true),
                       [.key(usage: control, down: false), .key(usage: command, down: true), .key(usage: keyH, down: true)])

        var r4 = ShortcutRemapper()
        _ = r4.key(usage: control, down: true)
        _ = r4.key(usage: option, down: true)
        XCTAssertEqual(r4.key(usage: space, down: true),
                       [.key(usage: control, down: false), .key(usage: command, down: true), .key(usage: space, down: true)])
    }

    func testDisplaySpaceQualityAndStylusMessagesRoundTrip() throws {
        XCTAssertEqual(try SessionCodec.decodeControl(SessionCodec.encode(.displaySpace(2))), .displaySpace(2))
        XCTAssertEqual(try SessionCodec.decodeControl(SessionCodec.encode(.qualityPreset(1))), .qualityPreset(1))
        XCTAssertThrowsError(try SessionCodec.decodeControl(SessionCodec.encode(.displaySpace(5))))
        XCTAssertThrowsError(try SessionCodec.decodeControl(SessionCodec.encode(.qualityPreset(9))))

        let stylus = InputEvent.stylus(phase: .move, x: 0.25, y: 0.75, pressure: 0.6)
        XCTAssertEqual(try SessionCodec.decodeInput(SessionCodec.encode(stylus)), stylus)
        XCTAssertThrowsError(try SessionCodec.decodeInput(SessionCodec.encode(.stylus(phase: .down, x: 0.5, y: 0.5, pressure: 1.5))))
    }
}

final class DecodeLimitTests: XCTestCase {
    func testStepDownDrops444FirstThenTenBit() {
        XCTAssertEqual(DecodeLimits.next(after: [], uses444: true, tenBit: true), .no444)
        XCTAssertEqual(DecodeLimits.next(after: .no444, uses444: false, tenBit: true), [.no444, .no10Bit])
        XCTAssertEqual(DecodeLimits.next(after: [], uses444: false, tenBit: true), .no10Bit)
        XCTAssertNil(DecodeLimits.next(after: [.no444, .no10Bit], uses444: false, tenBit: false))
        XCTAssertNil(DecodeLimits.next(after: [], uses444: false, tenBit: false))
    }

    func testDetectorNeedsRepeatedFailuresAndCoolsDown() {
        var detector = DecodeFailureDetector()
        XCTAssertFalse(detector.failed(at: 0))
        XCTAssertFalse(detector.failed(at: 20)) // the first one fell out of the window
        XCTAssertFalse(detector.failed(at: 21))
        XCTAssertTrue(detector.failed(at: 22))
        // Cooling down while the Mac switches format.
        for t in [23.0, 24, 25, 26] { XCTAssertFalse(detector.failed(at: t)) }
        XCTAssertFalse(detector.failed(at: 31))
        XCTAssertFalse(detector.failed(at: 31.5))
        XCTAssertTrue(detector.failed(at: 32))
    }

    func testHelloCarriesPixelDensityAndDecodeFailedRoundTrips() throws {
        let hello = Hello(role: .client, deviceName: "Test iPad", pixelWidth: 2266, pixelHeight: 1488, scale: 2,
                          maxRefreshHz: 60, codecs: [.h264], pixelsPerInch: 326)
        XCTAssertEqual(try SessionCodec.decodeControl(SessionCodec.encode(.hello(hello))), .hello(hello))
        XCTAssertEqual(try SessionCodec.decodeControl(SessionCodec.encode(.decodeFailed)), .decodeFailed)
        var bad = hello
        bad.pixelsPerInch = 5000
        XCTAssertThrowsError(try SessionCodec.decodeControl(SessionCodec.encode(.hello(bad))))
    }
}

final class BrightnessTests: XCTestCase {
    func testStepsSnapToGridAndClamp() {
        XCTAssertEqual(BrightnessStep.next(from: 0.5, up: true, fine: false), 0.5625)
        XCTAssertEqual(BrightnessStep.next(from: 0.5, up: false, fine: false), 0.4375)
        XCTAssertEqual(BrightnessStep.next(from: 0.53, up: true, fine: false), 0.5625)
        XCTAssertEqual(BrightnessStep.next(from: 0.53, up: false, fine: false), 0.5)
        XCTAssertEqual(BrightnessStep.next(from: 1, up: true, fine: false), 1)
        XCTAssertEqual(BrightnessStep.next(from: 0.02, up: false, fine: false), 0)
        XCTAssertEqual(BrightnessStep.next(from: 0.5, up: true, fine: true), 0.515625)
    }

    func testBrightnessMessageRoundTripsAndIsBounded() throws {
        XCTAssertEqual(try SessionCodec.decodeControl(SessionCodec.encode(.brightness(0.75))), .brightness(0.75))
        XCTAssertThrowsError(try SessionCodec.decodeControl(SessionCodec.encode(.brightness(1.5))))
        XCTAssertThrowsError(try SessionCodec.decodeControl(SessionCodec.encode(.brightness(.nan))))
    }
}

final class CursorMessageTests: XCTestCase {
    func testCursorMessagesRoundTripAndAreBounded() throws {
        XCTAssertEqual(try SessionCodec.decodeControl(SessionCodec.encode(.cursor(x: 0.25, y: 1, visible: true))),
                       .cursor(x: 0.25, y: 1, visible: true))
        let image = CursorImage(png: [0x89, 0x50, 0x4E, 0x47], width: 0.012, height: 0.02, hotX: 0.1, hotY: 0.05)
        XCTAssertEqual(try SessionCodec.decodeControl(SessionCodec.encode(.cursorImage(image))), .cursorImage(image))
        XCTAssertThrowsError(try SessionCodec.decodeControl(SessionCodec.encode(.cursor(x: 1.5, y: 0, visible: true))))
        var huge = image
        huge.png = [UInt8](repeating: 0, count: CursorImage.maxPNGBytes + 1)
        XCTAssertThrowsError(try SessionCodec.decodeControl(SessionCodec.encode(.cursorImage(huge))))
    }

    func testVolumeAndSleepMacMessagesRoundTrip() throws {
        XCTAssertEqual(try SessionCodec.decodeControl(SessionCodec.encode(.volume(level: 0.6, muted: false))),
                       .volume(level: 0.6, muted: false))
        XCTAssertEqual(try SessionCodec.decodeControl(SessionCodec.encode(.volume(level: 0, muted: true))),
                       .volume(level: 0, muted: true))
        XCTAssertEqual(try SessionCodec.decodeControl(SessionCodec.encode(.sleepMac)), .sleepMac)
        XCTAssertThrowsError(try SessionCodec.decodeControl(SessionCodec.encode(.volume(level: 1.5, muted: false))))
        XCTAssertThrowsError(try SessionCodec.decodeControl(SessionCodec.encode(.volume(level: .nan, muted: false))))
    }
}
