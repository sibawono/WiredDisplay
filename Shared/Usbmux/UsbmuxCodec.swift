import Foundation

/// Pure encoder/decoder for the usbmuxd plist protocol (version 1, type 8).
/// Packet: 16-byte little-endian header {length, version, type, tag} + XML plist.
/// Everything read from the socket is treated as untrusted and bounded.
public enum UsbmuxCodec {
    public static let headerLength = 16
    public static let protocolVersion: UInt32 = 1
    public static let plistMessageType: UInt32 = 8
    /// usbmuxd replies are small; anything larger is malformed.
    public static let maxPacketLength: UInt32 = 1024 * 1024

    public enum CodecError: Error, Equatable, Sendable {
        case truncatedHeader
        case lengthOutOfBounds(UInt32)
        case unsupportedVersion(UInt32)
        case unsupportedType(UInt32)
        case bodyLengthMismatch(expected: Int, got: Int)
        case notADictionary
        case missingField(String)
        case plist(String)
    }

    public struct PacketHeader: Equatable, Sendable {
        public var length: UInt32
        public var version: UInt32
        public var type: UInt32
        public var tag: UInt32

        public var bodyLength: Int { Int(length) - UsbmuxCodec.headerLength }
    }

    public static func encodeRequest(_ fields: [String: Any], tag: UInt32,
                                     programName: String = "WiredDisplay") throws -> [UInt8] {
        var message = fields
        message["ClientVersionString"] = programName
        message["ProgName"] = programName
        message["kLibUSBMuxVersion"] = 3
        let body: Data
        do {
            body = try PropertyListSerialization.data(fromPropertyList: message, format: .xml, options: 0)
        } catch {
            throw CodecError.plist(String(describing: error))
        }
        let total = headerLength + body.count
        guard total <= Int(maxPacketLength) else { throw CodecError.lengthOutOfBounds(UInt32(clamping: total)) }
        var out = [UInt8]()
        out.reserveCapacity(total)
        for value in [UInt32(total), protocolVersion, plistMessageType, tag] {
            withUnsafeBytes(of: value.littleEndian) { out.append(contentsOf: $0) }
        }
        out.append(contentsOf: body)
        return out
    }

    public static func decodeHeader(_ bytes: [UInt8]) throws -> PacketHeader {
        guard bytes.count >= headerLength else { throw CodecError.truncatedHeader }
        func word(_ index: Int) -> UInt32 {
            let base = index * 4
            return UInt32(bytes[base]) | UInt32(bytes[base + 1]) << 8
                | UInt32(bytes[base + 2]) << 16 | UInt32(bytes[base + 3]) << 24
        }
        let header = PacketHeader(length: word(0), version: word(1), type: word(2), tag: word(3))
        guard header.length >= UInt32(headerLength), header.length <= maxPacketLength else {
            throw CodecError.lengthOutOfBounds(header.length)
        }
        guard header.version == protocolVersion else { throw CodecError.unsupportedVersion(header.version) }
        guard header.type == plistMessageType else { throw CodecError.unsupportedType(header.type) }
        return header
    }

    public static func decodeBody(_ body: [UInt8], header: PacketHeader) throws -> [String: Any] {
        guard body.count == header.bodyLength else {
            throw CodecError.bodyLengthMismatch(expected: header.bodyLength, got: body.count)
        }
        let object: Any
        do {
            object = try PropertyListSerialization.propertyList(from: Data(body), options: [], format: nil)
        } catch {
            throw CodecError.plist(String(describing: error))
        }
        guard let dictionary = object as? [String: Any] else { throw CodecError.notADictionary }
        return dictionary
    }

    /// usbmuxd expects the TCP port in network byte order inside a
    /// host-order integer field, i.e. byte-swapped on little-endian hosts.
    public static func wirePort(_ port: UInt16) -> Int { Int(port.byteSwapped) }
}

public enum UsbmuxResultCode: Equatable, Sendable {
    case ok
    case badCommand
    case badDevice
    case connectionRefused
    case badVersion
    case unknown(Int)

    public init(_ number: Int) {
        switch number {
        case 0: self = .ok
        case 1: self = .badCommand
        case 2: self = .badDevice
        case 3: self = .connectionRefused
        case 6: self = .badVersion
        default: self = .unknown(number)
        }
    }
}

public struct UsbmuxDevice: Equatable, Sendable {
    public enum ConnectionType: Equatable, Sendable {
        case usb
        case network
        case other(String)
    }

    public var deviceID: Int
    public var serialNumber: String
    public var connectionType: ConnectionType
    /// Negotiated USB link speed in bit/s, when usbmuxd reports it.
    public var connectionSpeed: Int?
    public var productID: Int?

    /// Parses a `ListDevices` reply. Entries that are malformed are skipped
    /// rather than trusted; a reply without a DeviceList is an error.
    public static func parseList(_ reply: [String: Any]) throws -> [UsbmuxDevice] {
        guard let list = reply["DeviceList"] as? [Any] else {
            throw UsbmuxCodec.CodecError.missingField("DeviceList")
        }
        return list.compactMap { entry in
            guard let dictionary = entry as? [String: Any],
                  let properties = dictionary["Properties"] as? [String: Any],
                  let deviceID = properties["DeviceID"] as? Int,
                  let serial = properties["SerialNumber"] as? String,
                  let rawType = properties["ConnectionType"] as? String else { return nil }
            let type: ConnectionType
            switch rawType {
            case "USB": type = .usb
            case "Network": type = .network
            default: type = .other(rawType)
            }
            return UsbmuxDevice(deviceID: deviceID, serialNumber: serial, connectionType: type,
                                connectionSpeed: properties["ConnectionSpeed"] as? Int,
                                productID: properties["ProductID"] as? Int)
        }
    }

    /// Wired Only policy: only devices usbmuxd itself reports as USB-attached.
    public static func wiredOnly(_ devices: [UsbmuxDevice]) -> [UsbmuxDevice] {
        devices.filter { $0.connectionType == .usb }
    }
}
