import Foundation

/// Logical streams multiplexed over one wired connection.
/// Raw values are wire values; unknown values are rejected by the parser.
public enum StreamType: UInt8, Sendable, CaseIterable {
    case control = 0
    case input = 1
    case video = 2
    case speaker = 3
    case microphone = 4
    case camera = 5

    /// Hard upper bound for a single payload on this stream. A peer announcing
    /// more is treated as malformed and the connection must be dropped.
    public var maxPayloadLength: UInt32 {
        switch self {
        case .control: return 64 * 1024
        case .input: return 4 * 1024
        case .video: return 8 * 1024 * 1024
        case .speaker, .microphone: return 64 * 1024
        case .camera: return 4 * 1024 * 1024
        }
    }
}

public struct FrameFlags: OptionSet, Sendable, Hashable {
    public let rawValue: UInt16
    public init(rawValue: UInt16) { self.rawValue = rawValue }

    /// Video: frame is independently decodable.
    public static let keyframe = FrameFlags(rawValue: 1 << 0)
    /// Payload is AES-GCM ciphertext followed by a 16-byte tag; the encoded
    /// header is the additional authenticated data (D-023, `SecureChannel`).
    /// Whether a frame MUST carry it is decided by the channel, not the parser.
    public static let authenticated = FrameFlags(rawValue: 1 << 1)

    static let known: FrameFlags = [.keyframe, .authenticated]
}

public enum FrameError: Error, Equatable, Sendable {
    case badMagic(UInt32)
    case unsupportedVersion(UInt8)
    case unknownStream(UInt8)
    case unknownFlags(UInt16)
    case payloadTooLarge(stream: StreamType, length: UInt32)
    case payloadLengthMismatch(header: UInt32, actual: Int)
    case truncatedHeader
    case bufferOverflow(limit: Int)
    case sequenceExhausted(stream: StreamType)
    case replayedOrReordered(stream: StreamType, got: UInt64, expectedAtLeast: UInt64)
    case parserPoisoned
}

/// Fixed 36-byte big-endian header.
///
///     off size field
///       0    4 magic            0x57445350 ("WDSP")
///       4    1 version          1
///       5    1 streamType
///       6    2 flags
///       8    8 sessionID        random per session, chosen during negotiation
///      16    8 sequence         per-stream, strictly increasing; gaps allowed
///      24    8 timestampNanos   sender monotonic clock
///      32    4 payloadLength    bounded per stream
public struct FrameHeader: Equatable, Sendable {
    public static let magic: UInt32 = 0x5744_5350
    public static let currentVersion: UInt8 = 1
    public static let encodedLength = 36

    public var stream: StreamType
    public var flags: FrameFlags
    public var sessionID: UInt64
    public var sequence: UInt64
    public var timestampNanos: UInt64
    public var payloadLength: UInt32

    public init(stream: StreamType, flags: FrameFlags = [], sessionID: UInt64, sequence: UInt64,
                timestampNanos: UInt64, payloadLength: UInt32) {
        self.stream = stream
        self.flags = flags
        self.sessionID = sessionID
        self.sequence = sequence
        self.timestampNanos = timestampNanos
        self.payloadLength = payloadLength
    }

    /// Validates the same invariants the decoder enforces, so we never emit a
    /// frame our own parser would reject.
    public func encoded() throws -> [UInt8] {
        try Self.validate(stream: stream, flags: flags, payloadLength: payloadLength)
        var out = [UInt8]()
        out.reserveCapacity(Self.encodedLength)
        out.appendBigEndian(Self.magic)
        out.append(Self.currentVersion)
        out.append(stream.rawValue)
        out.appendBigEndian(flags.rawValue)
        out.appendBigEndian(sessionID)
        out.appendBigEndian(sequence)
        out.appendBigEndian(timestampNanos)
        out.appendBigEndian(payloadLength)
        return out
    }

    /// Decodes exactly `encodedLength` bytes starting at `bytes.startIndex`.
    public static func decode<C: RandomAccessCollection>(_ bytes: C) throws -> FrameHeader
    where C.Element == UInt8 {
        guard bytes.count >= encodedLength else { throw FrameError.truncatedHeader }
        var reader = ByteReader(bytes)
        let magic: UInt32 = reader.read()
        guard magic == Self.magic else { throw FrameError.badMagic(magic) }
        let version: UInt8 = reader.read()
        guard version == currentVersion else { throw FrameError.unsupportedVersion(version) }
        let rawStream: UInt8 = reader.read()
        guard let stream = StreamType(rawValue: rawStream) else { throw FrameError.unknownStream(rawStream) }
        let flags = FrameFlags(rawValue: reader.read())
        let sessionID: UInt64 = reader.read()
        let sequence: UInt64 = reader.read()
        let timestamp: UInt64 = reader.read()
        let length: UInt32 = reader.read()
        try validate(stream: stream, flags: flags, payloadLength: length)
        return FrameHeader(stream: stream, flags: flags, sessionID: sessionID, sequence: sequence,
                           timestampNanos: timestamp, payloadLength: length)
    }

    private static func validate(stream: StreamType, flags: FrameFlags, payloadLength: UInt32) throws {
        guard flags.isSubset(of: FrameFlags.known) else { throw FrameError.unknownFlags(flags.rawValue) }
        guard !flags.contains(.keyframe) || stream == .video || stream == .camera else {
            throw FrameError.unknownFlags(flags.rawValue)
        }
        guard payloadLength <= stream.maxPayloadLength else {
            throw FrameError.payloadTooLarge(stream: stream, length: payloadLength)
        }
    }
}

extension Array where Element == UInt8 {
    mutating func appendBigEndian<T: FixedWidthInteger>(_ value: T) {
        Swift.withUnsafeBytes(of: value.bigEndian) { append(contentsOf: $0) }
    }
}

/// Bounds are established by the caller (count check) before any read.
struct ByteReader<C: RandomAccessCollection> where C.Element == UInt8 {
    private let bytes: C
    private var index: C.Index

    init(_ bytes: C) {
        self.bytes = bytes
        self.index = bytes.startIndex
    }

    mutating func read<T: FixedWidthInteger>() -> T {
        var value: T = 0
        for _ in 0..<MemoryLayout<T>.size {
            value = (value << 8) | T(truncatingIfNeeded: bytes[index])
            index = bytes.index(after: index)
        }
        return value
    }
}
