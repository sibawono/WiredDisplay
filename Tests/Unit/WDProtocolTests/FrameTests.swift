import XCTest
@testable import WDProtocol

/// Deterministic generator so fuzz failures are reproducible from the seed.
struct SplitMix64: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

final class FrameHeaderTests: XCTestCase {
    private func sample(stream: StreamType = .video, length: UInt32 = 5) -> FrameHeader {
        FrameHeader(stream: stream, flags: stream == .video ? [.keyframe] : [], sessionID: 0x0102_0304_0506_0708,
                    sequence: 42, timestampNanos: 0xFFFF_FFFF_FFFF_FFFE, payloadLength: length)
    }

    func testRoundTripAndExactLayout() throws {
        let bytes = try sample().encoded()
        XCTAssertEqual(bytes.count, FrameHeader.encodedLength)
        XCTAssertEqual(Array(bytes[0..<4]), [0x57, 0x44, 0x53, 0x50])
        XCTAssertEqual(bytes[4], 1)
        XCTAssertEqual(bytes[5], StreamType.video.rawValue)
        XCTAssertEqual(Array(bytes[6..<8]), [0x00, 0x01])
        XCTAssertEqual(Array(bytes[8..<16]), [1, 2, 3, 4, 5, 6, 7, 8])
        XCTAssertEqual(Array(bytes[32..<36]), [0, 0, 0, 5])
        XCTAssertEqual(try FrameHeader.decode(bytes), sample())
    }

    func testDecodeFromSliceWithNonZeroStartIndex() throws {
        let bytes = [0xAA, 0xBB, 0xCC] + (try sample().encoded())
        XCTAssertEqual(try FrameHeader.decode(bytes[3...]), sample())
    }

    func testRejectsTruncatedHeader() throws {
        let bytes = try sample().encoded()
        for length in 0..<FrameHeader.encodedLength {
            XCTAssertThrowsError(try FrameHeader.decode(bytes.prefix(length))) {
                XCTAssertEqual($0 as? FrameError, .truncatedHeader)
            }
        }
    }

    func testRejectsBadMagicVersionStreamFlags() throws {
        var bytes = try sample().encoded()
        bytes[0] = 0x00
        XCTAssertThrowsError(try FrameHeader.decode(bytes)) { XCTAssertEqual($0 as? FrameError, .badMagic(0x0044_5350)) }

        bytes = try sample().encoded(); bytes[4] = 2
        XCTAssertThrowsError(try FrameHeader.decode(bytes)) { XCTAssertEqual($0 as? FrameError, .unsupportedVersion(2)) }

        bytes = try sample().encoded(); bytes[5] = 200
        XCTAssertThrowsError(try FrameHeader.decode(bytes)) { XCTAssertEqual($0 as? FrameError, .unknownStream(200)) }

        bytes = try sample().encoded(); bytes[6] = 0x80
        XCTAssertThrowsError(try FrameHeader.decode(bytes)) { XCTAssertEqual($0 as? FrameError, .unknownFlags(0x8001)) }
    }

    func testAuthenticatedFlagRoundTrips() throws {
        var header = sample()
        header.flags = [.authenticated]
        XCTAssertEqual(try FrameHeader.decode(try header.encoded()).flags, [.authenticated])
    }

    func testPayloadLengthBoundaryPerStream() throws {
        for stream in StreamType.allCases {
            let limit = stream.maxPayloadLength
            XCTAssertNoThrow(try FrameHeader.decode(try sample(stream: stream, length: limit).encoded()))
            XCTAssertThrowsError(try sample(stream: stream, length: limit + 1).encoded()) {
                XCTAssertEqual($0 as? FrameError, .payloadTooLarge(stream: stream, length: limit + 1))
            }
        }
        // A hostile peer announcing 4 GiB must be rejected from the header alone.
        var bytes = try sample().encoded()
        bytes.replaceSubrange(32..<36, with: [0xFF, 0xFF, 0xFF, 0xFF])
        XCTAssertThrowsError(try FrameHeader.decode(bytes)) {
            XCTAssertEqual($0 as? FrameError, .payloadTooLarge(stream: .video, length: .max))
        }
    }
}

final class FrameParserTests: XCTestCase {
    private func frame(_ sequence: UInt64, stream: StreamType = .input, size: Int = 16) throws -> Frame {
        try Frame(stream: stream, sessionID: 7, sequence: sequence, timestampNanos: sequence * 10,
                  payload: (0..<size).map { UInt8(truncatingIfNeeded: $0 &+ Int(sequence)) })
    }

    func testParsesFramesDeliveredOneByteAtATime() throws {
        let frames = try (0..<5).map { try frame(UInt64($0), size: $0 * 3) }
        let wire = try frames.flatMap { try $0.encoded() }
        var parser = FrameParser()
        var parsed: [Frame] = []
        for byte in wire {
            try parser.append([byte])
            while let next = try parser.next() { parsed.append(next) }
        }
        XCTAssertEqual(parsed, frames)
        XCTAssertEqual(parser.bufferedByteCount, 0)
    }

    func testParsesManyFramesInOneChunkIncludingEmptyPayload() throws {
        let frames = try [frame(0, size: 0), frame(1, size: 1), frame(2, size: 4096)]
        var parser = FrameParser()
        try parser.append(try frames.flatMap { try $0.encoded() })
        XCTAssertEqual(try parser.next(), frames[0])
        XCTAssertEqual(try parser.next(), frames[1])
        XCTAssertEqual(try parser.next(), frames[2])
        XCTAssertNil(try parser.next())
    }

    func testIncompleteFrameReturnsNilWithoutConsuming() throws {
        let wire = try frame(0, size: 100).encoded()
        var parser = FrameParser()
        try parser.append(wire.dropLast())
        XCTAssertNil(try parser.next())
        XCTAssertNil(try parser.next())
        try parser.append(wire.suffix(1))
        XCTAssertEqual(try parser.next(), try frame(0, size: 100))
    }

    func testMalformedHeaderPoisonsParserAndDropsBuffer() throws {
        var parser = FrameParser()
        try parser.append([UInt8](repeating: 0xEE, count: 100))
        XCTAssertThrowsError(try parser.next()) { XCTAssertEqual($0 as? FrameError, .badMagic(0xEEEE_EEEE)) }
        XCTAssertEqual(parser.bufferedByteCount, 0)
        // Valid data afterwards must not resurrect the stream.
        XCTAssertThrowsError(try parser.append(try frame(0).encoded())) {
            XCTAssertEqual($0 as? FrameError, .parserPoisoned)
        }
        XCTAssertEqual(parser.bufferedByteCount, 0)
        XCTAssertThrowsError(try parser.next()) { XCTAssertEqual($0 as? FrameError, .parserPoisoned) }
    }

    func testOversizedLengthIsRejectedBeforePayloadArrives() throws {
        var header = try frame(0, stream: .input, size: 0).header.encoded()
        header.replaceSubrange(32..<36, with: [0x00, 0x00, 0x10, 0x01]) // 4097 > input cap 4096
        var parser = FrameParser()
        try parser.append(header)
        XCTAssertThrowsError(try parser.next()) {
            XCTAssertEqual($0 as? FrameError, .payloadTooLarge(stream: .input, length: 4097))
        }
    }

    func testFrameInitRejectsOversizedPayload() {
        XCTAssertThrowsError(try Frame(stream: .input, sessionID: 1, sequence: 0, timestampNanos: 0,
                                       payload: [UInt8](repeating: 0, count: 4097))) {
            XCTAssertEqual($0 as? FrameError, .payloadTooLarge(stream: .input, length: 4097))
        }
    }

    func testEncodeRejectsHeaderPayloadLengthMismatch() throws {
        var bad = try frame(0, size: 8)
        bad.payload.removeLast()
        XCTAssertThrowsError(try bad.encoded()) {
            XCTAssertEqual($0 as? FrameError, .payloadLengthMismatch(header: 8, actual: 7))
        }
    }

    /// Exercises the removeFirst compaction branch: several large frames plus a
    /// partial one in a single append, so a residue survives past the 64 KiB
    /// consumed threshold.
    func testCompactionWithResidueKeepsOffsetsCorrect() throws {
        let frames = try (0..<4).map { try frame(UInt64($0), stream: .video, size: 50_000) }
        let tail = try frame(4, stream: .video, size: 50_000)
        let tailWire = try tail.encoded()
        var parser = FrameParser()
        try parser.append(try frames.flatMap { try $0.encoded() } + tailWire.prefix(20_000))
        for expected in frames { XCTAssertEqual(try parser.next(), expected) }
        XCTAssertNil(try parser.next())
        XCTAssertEqual(parser.bufferedByteCount, 20_000 - FrameHeader.encodedLength, "header consumed, partial payload kept")
        XCTAssertLessThan(parser.retainedStorageCount, 60_000, "consumed frames must have been compacted away")
        try parser.append(tailWire.dropFirst(20_000))
        XCTAssertEqual(try parser.next(), tail)
        XCTAssertEqual(parser.retainedStorageCount, 0)
    }

    func testKeyframeFlagIsRejectedOnNonVideoStreams() throws {
        XCTAssertThrowsError(try Frame(stream: .input, flags: [.keyframe], sessionID: 1, sequence: 0,
                                       timestampNanos: 0, payload: []).encoded()) {
            XCTAssertEqual($0 as? FrameError, .unknownFlags(FrameFlags.keyframe.rawValue))
        }
        var bytes = try frame(0, stream: .input, size: 0).encoded()
        bytes[7] = 0x01
        XCTAssertThrowsError(try FrameHeader.decode(bytes)) {
            XCTAssertEqual($0 as? FrameError, .unknownFlags(1))
        }
        // Camera stream carries H.264/HEVC frames and allows the keyframe flag.
        let camFrame = try Frame(stream: .camera, flags: [.keyframe], sessionID: 1, sequence: 0,
                                 timestampNanos: 123, payload: [0, 0, 0, 1, 0x65])
        let decoded = try FrameHeader.decode(try camFrame.encoded())
        XCTAssertEqual(decoded.stream, .camera)
        XCTAssertTrue(decoded.flags.contains(.keyframe))
    }

    /// A caller that never drains must hit the bound instead of growing forever.
    func testAppendWithoutDrainingIsBoundedAndPoisons() throws {
        var parser = FrameParser()
        let chunk = [UInt8](repeating: 0xEE, count: 1024 * 1024)
        var appended = 0
        var overflowed = false
        for _ in 0..<64 {
            do {
                try parser.append(chunk)
                appended += chunk.count
                XCTAssertLessThanOrEqual(parser.bufferedByteCount, FrameParser.maxBufferedBytes)
            } catch {
                XCTAssertEqual(error as? FrameError, .bufferOverflow(limit: FrameParser.maxBufferedBytes))
                overflowed = true
                break
            }
        }
        XCTAssertTrue(overflowed, "64 MiB of undrained input must overflow the bound")
        XCTAssertLessThanOrEqual(appended, FrameParser.maxBufferedBytes)
        XCTAssertEqual(parser.retainedStorageCount, 0, "poisoning releases the buffer")
        XCTAssertThrowsError(try parser.next()) { XCTAssertEqual($0 as? FrameError, .parserPoisoned) }
    }

    func testAppendExactlyAtBoundIsAccepted() throws {
        var parser = FrameParser()
        try parser.append([UInt8](repeating: 0, count: FrameParser.maxBufferedBytes))
        XCTAssertThrowsError(try parser.append([0])) {
            XCTAssertEqual($0 as? FrameError, .bufferOverflow(limit: FrameParser.maxBufferedBytes))
        }
    }

    /// Fuzz: random valid frames, randomly chunked, must round-trip exactly.
    func testFuzzRandomChunkingRoundTrips() throws {
        for seed in UInt64(1)...40 {
            var rng = SplitMix64(state: seed)
            var frames: [Frame] = []
            for sequence in 0..<UInt64(Int.random(in: 1...30, using: &rng)) {
                let stream = StreamType.allCases.randomElement(using: &rng) ?? .control
                let size = Int.random(in: 0...min(3000, Int(stream.maxPayloadLength)), using: &rng)
                frames.append(try Frame(stream: stream, flags: stream == .video && Bool.random(using: &rng) ? [.keyframe] : [],
                                        sessionID: rng.next(), sequence: sequence, timestampNanos: rng.next(),
                                        payload: (0..<size).map { _ in UInt8.random(in: 0...255, using: &rng) }))
            }
            let wire = try frames.flatMap { try $0.encoded() }
            var parser = FrameParser()
            var parsed: [Frame] = []
            var offset = 0
            while offset < wire.count {
                let step = min(Int.random(in: 1...700, using: &rng), wire.count - offset)
                try parser.append(wire[offset..<(offset + step)])
                offset += step
                while let next = try parser.next() { parsed.append(next) }
            }
            XCTAssertEqual(parsed, frames, "seed \(seed)")
        }
    }

    /// Fuzz: arbitrary garbage and bit-flipped/truncated valid streams must
    /// either parse or throw a FrameError; never crash, and a failure must
    /// release the buffer. (The memory bound itself is tested separately.)
    func testFuzzGarbageAndMutationsNeverCrashAndStayBounded() throws {
        for seed in UInt64(1)...300 {
            var rng = SplitMix64(state: seed &* 7919)
            var wire: [UInt8]
            if seed % 3 == 0 {
                wire = (0..<Int.random(in: 0...2000, using: &rng)).map { _ in UInt8.random(in: 0...255, using: &rng) }
            } else {
                wire = try (0..<4).flatMap { try frame(UInt64($0), size: Int.random(in: 0...200, using: &rng)).encoded() }
                for _ in 0..<Int.random(in: 1...6, using: &rng) where !wire.isEmpty {
                    wire[Int.random(in: 0..<wire.count, using: &rng)] ^= UInt8(1 << Int.random(in: 0...7, using: &rng))
                }
                wire.removeLast(Int.random(in: 0...min(40, wire.count), using: &rng))
            }
            var parser = FrameParser()
            var offset = 0
            do {
                while offset < wire.count {
                    let step = min(Int.random(in: 1...300, using: &rng), wire.count - offset)
                    try parser.append(wire[offset..<(offset + step)])
                    offset += step
                    while let next = try parser.next() {
                        XCTAssertLessThanOrEqual(next.payload.count, Int(next.header.stream.maxPayloadLength))
                    }
                    // Everything parseable was drained: at most one partial frame of this
                    // small test wire may remain.
                    XCTAssertLessThanOrEqual(parser.bufferedByteCount, wire.count)
                }
            } catch {
                XCTAssertTrue(error is FrameError, "seed \(seed): unexpected error type \(error)")
                XCTAssertEqual(parser.bufferedByteCount, 0)
            }
        }
    }
}

final class SequenceValidatorTests: XCTestCase {
    private func header(_ stream: StreamType, _ sequence: UInt64, session: UInt64 = 9) -> FrameHeader {
        FrameHeader(stream: stream, sessionID: session, sequence: sequence, timestampNanos: 0, payloadLength: 0)
    }

    func testAcceptsIncreasingAndGapsPerStreamIndependently() throws {
        var validator = SequenceValidator(sessionID: 9)
        try validator.accept(header(.video, 0))
        try validator.accept(header(.video, 1))
        try validator.accept(header(.video, 10)) // sender dropped stale frames
        try validator.accept(header(.input, 0))  // other stream has its own counter
    }

    func testRejectsDuplicateAndReordered() throws {
        var validator = SequenceValidator(sessionID: 9)
        try validator.accept(header(.input, 5))
        XCTAssertThrowsError(try validator.accept(header(.input, 5))) {
            XCTAssertEqual($0 as? FrameError, .replayedOrReordered(stream: .input, got: 5, expectedAtLeast: 6))
        }
        XCTAssertThrowsError(try validator.accept(header(.input, 4)))
        try validator.accept(header(.input, 6))
    }

    func testRejectsWrongSession() {
        var validator = SequenceValidator(sessionID: 9)
        XCTAssertThrowsError(try validator.accept(header(.control, 0, session: 10))) {
            XCTAssertEqual($0 as? SequenceValidator.Violation, .wrongSession(expected: 9, got: 10))
        }
    }

    func testMaxSequenceIsRefusedInsteadOfWrapping() throws {
        var validator = SequenceValidator(sessionID: 9)
        try validator.accept(header(.control, UInt64.max - 1))
        XCTAssertThrowsError(try validator.accept(header(.control, UInt64.max))) {
            XCTAssertEqual($0 as? FrameError, .sequenceExhausted(stream: .control))
        }
        // State is unchanged by the refusal: max-1 is now a replay.
        XCTAssertThrowsError(try validator.accept(header(.control, UInt64.max - 1)))
    }
}
