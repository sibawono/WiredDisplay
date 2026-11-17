import Foundation

public struct Frame: Equatable, Sendable {
    public var header: FrameHeader
    public var payload: [UInt8]

    public init(header: FrameHeader, payload: [UInt8]) {
        self.header = header
        self.payload = payload
    }

    public init(stream: StreamType, flags: FrameFlags = [], sessionID: UInt64, sequence: UInt64,
                timestampNanos: UInt64, payload: [UInt8]) throws {
        guard payload.count <= Int(stream.maxPayloadLength) else {
            throw FrameError.payloadTooLarge(stream: stream, length: UInt32(clamping: payload.count))
        }
        self.header = FrameHeader(stream: stream, flags: flags, sessionID: sessionID, sequence: sequence,
                                  timestampNanos: timestampNanos, payloadLength: UInt32(payload.count))
        self.payload = payload
    }

    public func encoded() throws -> [UInt8] {
        guard payload.count == Int(header.payloadLength) else {
            throw FrameError.payloadLengthMismatch(header: header.payloadLength, actual: payload.count)
        }
        return try header.encoded() + payload
    }
}

/// Incremental parser for an untrusted byte stream.
///
/// - Memory is bounded: `append` refuses to retain more than
///   `maxBufferedBytes` (one maximum-size frame plus read-chunk slack), whether
///   or not the caller drains with `next()`. Announced payload lengths are
///   checked against the per-stream cap as soon as a header is parsed.
/// - Errors are terminal. A byte stream cannot be resynchronised safely after a
///   malformed header, so the owner must close the connection.
public struct FrameParser: Sendable {
    private var buffer: [UInt8] = []
    private var readOffset = 0
    private var pendingHeader: FrameHeader?
    private var poisoned = false

    /// One header + the largest payload any stream allows + 1 MiB of slack for
    /// the read chunk that straddles a frame boundary.
    public static let maxBufferedBytes: Int = {
        let largest = StreamType.allCases.map { Int($0.maxPayloadLength) }.max() ?? 0
        return FrameHeader.encodedLength + largest + 1024 * 1024
    }()

    public init() {}

    /// Bytes currently retained. Exposed for bound tests and diagnostics.
    public var bufferedByteCount: Int { buffer.count - readOffset }

    /// Buffers bytes read from the peer. Throws (and poisons the parser) if the
    /// caller has not drained with `next()` and the bound would be exceeded.
    public mutating func append<C: Collection>(_ bytes: C) throws where C.Element == UInt8 {
        guard !poisoned else { throw FrameError.parserPoisoned }
        guard bytes.count <= Self.maxBufferedBytes - bufferedByteCount else {
            poison()
            throw FrameError.bufferOverflow(limit: Self.maxBufferedBytes)
        }
        buffer.append(contentsOf: bytes)
    }

    private mutating func poison() {
        poisoned = true
        buffer.removeAll(keepingCapacity: false)
        readOffset = 0
        pendingHeader = nil
    }

    /// Storage actually retained, including consumed-but-not-yet-compacted
    /// bytes. For tests of the compaction path.
    var retainedStorageCount: Int { buffer.count }

    /// Returns the next complete frame, or nil if more bytes are needed.
    public mutating func next() throws -> Frame? {
        guard !poisoned else { throw FrameError.parserPoisoned }
        do {
            return try parseNext()
        } catch {
            poison()
            throw error
        }
    }

    private mutating func parseNext() throws -> Frame? {
        if pendingHeader == nil {
            guard bufferedByteCount >= FrameHeader.encodedLength else { return nil }
            let slice = buffer[readOffset..<(readOffset + FrameHeader.encodedLength)]
            pendingHeader = try FrameHeader.decode(slice)
            readOffset += FrameHeader.encodedLength
        }
        guard let header = pendingHeader else { return nil }
        let length = Int(header.payloadLength)
        guard bufferedByteCount >= length else { return nil }
        let payload = Array(buffer[readOffset..<(readOffset + length)])
        readOffset += length
        pendingHeader = nil
        compact()
        return Frame(header: header, payload: payload)
    }

    private mutating func compact() {
        if readOffset == buffer.count {
            buffer.removeAll(keepingCapacity: true)
            readOffset = 0
        } else if readOffset > 64 * 1024 {
            buffer.removeFirst(readOffset)
            readOffset = 0
        }
    }
}

/// Per-stream replay/reorder defence for a reliable, ordered transport:
/// sequence numbers must be strictly increasing and the session must match.
/// This is NOT cryptographic replay protection; that arrives with the
/// authenticated channel (see docs/DECISIONS.md D-006).
public struct SequenceValidator: Sendable {
    public enum Violation: Error, Equatable, Sendable {
        case wrongSession(expected: UInt64, got: UInt64)
    }

    public let sessionID: UInt64
    private var nextExpected: [StreamType: UInt64] = [:]

    public init(sessionID: UInt64) { self.sessionID = sessionID }

    public mutating func accept(_ header: FrameHeader) throws {
        guard header.sessionID == sessionID else {
            throw Violation.wrongSession(expected: sessionID, got: header.sessionID)
        }
        let expected = nextExpected[header.stream] ?? 0
        guard header.sequence >= expected else {
            throw FrameError.replayedOrReordered(stream: header.stream, got: header.sequence,
                                                 expectedAtLeast: expected)
        }
        // UInt64.max is never a valid "next" value; refuse rather than wrap.
        guard header.sequence < UInt64.max else { throw FrameError.sequenceExhausted(stream: header.stream) }
        nextExpected[header.stream] = header.sequence + 1
    }
}
