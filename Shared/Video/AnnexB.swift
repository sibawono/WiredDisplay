import Foundation

/// Elementary-stream helpers shared by host (encoder output, AVCC/HVCC
/// length-prefixed) and client (sample buffers). Everything that parses
/// untrusted bytes throws instead of trapping.
public enum AnnexB {
    public enum Error: Swift.Error, Equatable, Sendable {
        case invalidLengthPrefix(offset: Int)
        case unsupportedLengthSize(Int)
        case emptyNAL
        case missingParameterSets
    }

    static let startCode: [UInt8] = [0, 0, 0, 1]

    /// Converts length-prefixed NAL units (as produced by VideoToolbox) into an
    /// Annex-B byte stream with 4-byte start codes.
    public static func fromLengthPrefixed(_ data: [UInt8], lengthSize: Int = 4) throws -> [UInt8] {
        try splitLengthPrefixed(data, lengthSize: lengthSize).reduce(into: [UInt8]()) { out, nal in
            out += startCode
            out += nal
        }
    }

    public static func splitLengthPrefixed(_ data: [UInt8], lengthSize: Int = 4) throws -> [[UInt8]] {
        guard [1, 2, 4].contains(lengthSize) else { throw Error.unsupportedLengthSize(lengthSize) }
        var nals: [[UInt8]] = []
        var offset = 0
        while offset < data.count {
            guard data.count - offset >= lengthSize else { throw Error.invalidLengthPrefix(offset: offset) }
            var length = 0
            for index in offset..<(offset + lengthSize) { length = (length << 8) | Int(data[index]) }
            offset += lengthSize
            guard length > 0 else { throw Error.emptyNAL }
            guard length <= data.count - offset else { throw Error.invalidLengthPrefix(offset: offset - lengthSize) }
            nals.append(Array(data[offset..<(offset + length)]))
            offset += length
        }
        return nals
    }

    /// Splits an Annex-B stream at 3- or 4-byte start codes. Leading bytes
    /// before the first start code are ignored; empty NAL units are dropped.
    public static func split(_ stream: [UInt8]) -> [[UInt8]] {
        var nals: [[UInt8]] = []
        var start: Int?
        var index = 0
        while index + 2 < stream.count {
            if stream[index] == 0, stream[index + 1] == 0, stream[index + 2] == 1 {
                if let start {
                    var end = index
                    // A 4-byte start code's leading zero belongs to it, not the NAL.
                    if end > start, stream[end - 1] == 0 { end -= 1 }
                    if end > start { nals.append(Array(stream[start..<end])) }
                }
                index += 3
                start = index
            } else {
                index += 1
            }
        }
        if let start, start < stream.count { nals.append(Array(stream[start...])) }
        return nals
    }

    /// Joins NAL units into 4-byte length-prefixed form for a CMSampleBuffer.
    public static func lengthPrefixed(_ nals: [[UInt8]]) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(nals.reduce(0) { $0 + $1.count + 4 })
        for nal in nals {
            let length = UInt32(nal.count).bigEndian
            withUnsafeBytes(of: length) { out.append(contentsOf: $0) }
            out += nal
        }
        return out
    }
}

/// NAL unit classification per codec.
public enum NALKind: Equatable, Sendable {
    case parameterSet
    case keyframeSlice
    case slice
    case other
}

public extension VideoCodecKind {
    func kind(of nal: [UInt8]) -> NALKind {
        guard let first = nal.first else { return .other }
        switch self {
        case .h264:
            switch first & 0x1F {
            case 7, 8: return .parameterSet           // SPS, PPS
            case 5: return .keyframeSlice             // IDR
            case 1: return .slice
            default: return .other
            }
        case .hevc:
            switch (first >> 1) & 0x3F {
            case 32, 33, 34: return .parameterSet     // VPS, SPS, PPS
            case 16...21: return .keyframeSlice       // BLA, IDR, CRA (IRAP)
            case 0...9: return .slice
            default: return .other
            }
        }
    }
}

/// Codec identity without depending on the session module.
public enum VideoCodecKind: Sendable, Equatable {
    case h264
    case hevc
}

/// One encoded picture as it travels on the wire: an Annex-B access unit.
/// Keyframes carry their parameter sets in-band, so a receiver can start (or
/// restart after loss) at any keyframe.
public struct AccessUnit: Sendable, Equatable {
    public var codec: VideoCodecKind
    public var nals: [[UInt8]]

    public init(codec: VideoCodecKind, nals: [[UInt8]]) {
        self.codec = codec
        self.nals = nals
    }

    public init(codec: VideoCodecKind, annexB: [UInt8]) {
        self.init(codec: codec, nals: AnnexB.split(annexB))
    }

    public var annexB: [UInt8] {
        nals.reduce(into: [UInt8]()) { $0 += AnnexB.startCode + $1 }
    }

    public var parameterSets: [[UInt8]] { nals.filter { codec.kind(of: $0) == .parameterSet } }
    public var pictureNALs: [[UInt8]] { nals.filter { codec.kind(of: $0) != .parameterSet } }
    public var isKeyframe: Bool { nals.contains { codec.kind(of: $0) == .keyframeSlice } }
}
