import Foundation

public enum WireError: Error, Equatable, Sendable {
    case truncated
    case trailingBytes(Int)
    case unknownTag(UInt8)
    case invalidValue(String)
}

/// Big-endian writer for session messages.
struct WireWriter {
    private(set) var bytes: [UInt8] = []

    mutating func u8(_ value: UInt8) { bytes.append(value) }
    mutating func u16(_ value: UInt16) { append(value) }
    mutating func u32(_ value: UInt32) { append(value) }
    mutating func u64(_ value: UInt64) { append(value) }
    mutating func f32(_ value: Float) { append(value.bitPattern) }
    mutating func raw(_ value: [UInt8]) { bytes.append(contentsOf: value) }

    /// UTF-8, length-prefixed (u16). Callers bound the length before writing.
    mutating func string(_ value: String) {
        let utf8 = Array(value.utf8)
        u16(UInt16(clamping: utf8.count))
        bytes.append(contentsOf: utf8.prefix(Int(UInt16.max)))
    }

    private mutating func append<T: FixedWidthInteger>(_ value: T) {
        withUnsafeBytes(of: value.bigEndian) { bytes.append(contentsOf: $0) }
    }
}

/// Bounds-checked big-endian reader. Every read throws instead of trapping, so
/// a hostile peer cannot crash the receiver with a short or malformed payload.
struct WireReader {
    private let bytes: [UInt8]
    private var offset = 0

    init(_ bytes: [UInt8]) { self.bytes = bytes }

    var remaining: Int { bytes.count - offset }

    mutating func u8() throws -> UInt8 { try read() }
    mutating func u16() throws -> UInt16 { try read() }
    mutating func u32() throws -> UInt32 { try read() }
    mutating func u64() throws -> UInt64 { try read() }
    mutating func f32() throws -> Float { Float(bitPattern: try read()) }

    mutating func raw(count: Int) throws -> [UInt8] {
        guard remaining >= count else { throw WireError.truncated }
        defer { offset += count }
        return Array(bytes[offset..<(offset + count)])
    }

    mutating func string(maxBytes: Int) throws -> String {
        let length = Int(try u16())
        guard length <= maxBytes else { throw WireError.invalidValue("string length \(length) > \(maxBytes)") }
        guard remaining >= length else { throw WireError.truncated }
        let slice = bytes[offset..<(offset + length)]
        offset += length
        guard let value = String(bytes: slice, encoding: .utf8) else { throw WireError.invalidValue("string not UTF-8") }
        return value
    }

    func requireEnd() throws {
        guard remaining == 0 else { throw WireError.trailingBytes(remaining) }
    }

    private mutating func read<T: FixedWidthInteger>() throws -> T {
        let size = MemoryLayout<T>.size
        guard remaining >= size else { throw WireError.truncated }
        var value: T = 0
        for index in offset..<(offset + size) { value = (value << 8) | T(bytes[index]) }
        offset += size
        return value
    }
}
