/// Reads the chroma format and bit depth from an HEVC sequence parameter set
/// (ITU-T H.265 7.3.2.2), so the iPad's Metal renderer can ask the decoder
/// for 4:4:4 output when the stream is 4:4:4 instead of always 4:2:0 (D-042).
public struct HEVCSPSInfo: Equatable, Sendable {
    /// 1 = 4:2:0, 2 = 4:2:2, 3 = 4:4:4.
    public var chromaFormat: Int
    public var bitDepthLuma: Int
    public var width: Int
    public var height: Int

    public init(chromaFormat: Int, bitDepthLuma: Int, width: Int, height: Int) {
        self.chromaFormat = chromaFormat
        self.bitDepthLuma = bitDepthLuma
        self.width = width
        self.height = height
    }

    /// `nal`: the SPS NAL unit including its 2-byte header, without a start code.
    public init?(sps nal: [UInt8]) {
        guard nal.count > 3, (nal[0] >> 1) & 0x3F == 33 else { return nil } // nal_unit_type 33 = SPS
        var bits = BitReader(Self.removeEmulationPrevention(Array(nal.dropFirst(2))))
        guard bits.skip(4) else { return nil } // sps_video_parameter_set_id
        guard let maxSubLayersMinus1 = bits.read(3), bits.skip(1) else { return nil } // + temporal_id_nesting
        // profile_tier_level(1, maxSubLayersMinus1)
        guard bits.skip(88 + 8) else { return nil } // general profile (88 bits) + general_level_idc
        var subProfile = [Bool](), subLevel = [Bool]()
        for _ in 0..<maxSubLayersMinus1 {
            guard let p = bits.read(1), let l = bits.read(1) else { return nil }
            subProfile.append(p == 1)
            subLevel.append(l == 1)
        }
        if maxSubLayersMinus1 > 0 { guard bits.skip(2 * (8 - maxSubLayersMinus1)) else { return nil } }
        for i in 0..<maxSubLayersMinus1 {
            if subProfile[i] { guard bits.skip(88) else { return nil } }
            if subLevel[i] { guard bits.skip(8) else { return nil } }
        }
        guard bits.readUE() != nil, let chroma = bits.readUE() else { return nil } // sps_seq_parameter_set_id
        if chroma == 3 { guard bits.skip(1) else { return nil } } // separate_colour_plane_flag
        guard let width = bits.readUE(), let height = bits.readUE(), let window = bits.read(1) else { return nil }
        if window == 1 { for _ in 0..<4 { guard bits.readUE() != nil else { return nil } } }
        guard let depthMinus8 = bits.readUE() else { return nil }
        self.init(chromaFormat: chroma, bitDepthLuma: depthMinus8 + 8, width: width, height: height)
    }

    static func removeEmulationPrevention(_ bytes: [UInt8]) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(bytes.count)
        var zeros = 0
        for byte in bytes {
            if zeros >= 2 && byte == 0x03 { zeros = 0; continue }
            out.append(byte)
            zeros = byte == 0 ? zeros + 1 : 0
        }
        return out
    }
}

struct BitReader {
    private let bytes: [UInt8]
    private var position = 0
    init(_ bytes: [UInt8]) { self.bytes = bytes }

    mutating func read(_ count: Int) -> Int? {
        guard count >= 0, position + count <= bytes.count * 8 else { return nil }
        var value = 0
        for _ in 0..<count {
            let bit = (bytes[position >> 3] >> (7 - UInt8(position & 7))) & 1
            value = (value << 1) | Int(bit)
            position += 1
        }
        return value
    }

    mutating func skip(_ count: Int) -> Bool {
        guard count >= 0, position + count <= bytes.count * 8 else { return false }
        position += count
        return true
    }

    /// Exp-Golomb unsigned.
    mutating func readUE() -> Int? {
        var zeros = 0
        while true {
            guard let bit = read(1) else { return nil }
            if bit == 1 { break }
            zeros += 1
            if zeros > 31 { return nil }
        }
        guard let rest = read(zeros) else { return nil }
        return (1 << zeros) - 1 + rest
    }
}
