import Foundation

/// The device's name and model, read from lockdownd over the same USB mux.
///
/// The iPad app cannot supply them: since iPadOS 16 `UIDevice.current.name`
/// returns the generic "iPad" unless Apple grants an entitlement, so every
/// paired iPad showed as "iPad". lockdownd answers `GetValue` for these keys
/// without a pairing session (measured: DeviceName, ProductType, DeviceClass,
/// ProductVersion all returned on iPadOS 27.3).
public struct DeviceIdentity: Sendable, Equatable {
    /// The name the owner gave the device ("Alex's iPad").
    public var name: String?
    /// Hardware identifier, e.g. "iPad14,10".
    public var productType: String?
    /// "iPad", "iPhone", …
    public var deviceClass: String?

    public init(name: String? = nil, productType: String? = nil, deviceClass: String? = nil) {
        self.name = name
        self.productType = productType
        self.deviceClass = deviceClass
    }

    /// Marketing model name, or the identifier when the model is unknown.
    public var modelName: String? {
        guard let productType else { return deviceClass }
        return Lockdown.marketingName(productType: productType) ?? productType
    }
}

public enum Lockdown {
    /// lockdownd's port on the device loopback.
    public static let port: UInt16 = 62078

    /// One request: a 4-byte big-endian length, then an XML property list.
    public static func encode(_ request: [String: Any]) throws -> [UInt8] {
        let body = try PropertyListSerialization.data(fromPropertyList: request, format: .xml, options: 0)
        let length = UInt32(body.count).bigEndian
        return withUnsafeBytes(of: length) { Array($0) } + Array(body)
    }

    public static func bodyLength(_ header: [UInt8]) -> Int? {
        guard header.count == 4 else { return nil }
        let length = header.reduce(0) { $0 << 8 | Int($1) }
        return (1...1_048_576).contains(length) ? length : nil
    }

    /// The `Value` of a GetValue reply, or nil (error reply, wrong type).
    public static func stringValue(_ body: [UInt8]) -> String? {
        guard let reply = try? PropertyListSerialization.propertyList(from: Data(body), options: [], format: nil)
            as? [String: Any], reply["Error"] == nil else { return nil }
        return reply["Value"] as? String
    }

    /// Reads name, model and class from a USB-attached device. Each step is
    /// bounded by `timeoutSeconds`; a failure returns what was read so far.
    public static func readIdentity(of device: UsbmuxDevice, timeoutSeconds: Int = 2) -> DeviceIdentity {
        var identity = DeviceIdentity()
        guard let connection = try? UsbmuxConnection(timeoutSeconds: timeoutSeconds) else { return identity }
        defer { connection.close() }
        guard (try? connection.connect(to: device, port: port)) != nil else { return identity }
        for key in ["DeviceName", "ProductType", "DeviceClass"] {
            guard let request = try? encode(["Request": "GetValue", "Key": key, "Label": "WiredDisplay"]),
                  (try? connection.writeAll(request)) != nil,
                  let header = try? connection.readExactly(4), let length = bodyLength(header),
                  let body = try? connection.readExactly(length) else { break }
            let value = stringValue(body)?.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let value, !value.isEmpty else { continue }
            switch key {
            case "DeviceName": identity.name = value
            case "ProductType": identity.productType = value
            default: identity.deviceClass = value
            }
        }
        return identity
    }

    /// iPads that run the WiredDisplay client (iPadOS 18 or later). Unknown
    /// identifiers (newer models) show as the identifier itself.
    public static func marketingName(productType: String) -> String? {
        let names: [String: String] = [
            // iPad
            "iPad12,1": "iPad (9th generation)", "iPad12,2": "iPad (9th generation)",
            "iPad13,18": "iPad (10th generation)", "iPad13,19": "iPad (10th generation)",
            "iPad15,7": "iPad (A16)", "iPad15,8": "iPad (A16)",
            // iPad mini
            "iPad14,1": "iPad mini (6th generation)", "iPad14,2": "iPad mini (6th generation)",
            "iPad16,1": "iPad mini (A17 Pro)", "iPad16,2": "iPad mini (A17 Pro)",
            // iPad Air
            "iPad13,1": "iPad Air (4th generation)", "iPad13,2": "iPad Air (4th generation)",
            "iPad13,16": "iPad Air (5th generation)", "iPad13,17": "iPad Air (5th generation)",
            "iPad14,8": "iPad Air 11-inch (M2)", "iPad14,9": "iPad Air 11-inch (M2)",
            "iPad14,10": "iPad Air 13-inch (M2)", "iPad14,11": "iPad Air 13-inch (M2)",
            "iPad15,3": "iPad Air 11-inch (M3)", "iPad15,4": "iPad Air 11-inch (M3)",
            "iPad15,5": "iPad Air 13-inch (M3)", "iPad15,6": "iPad Air 13-inch (M3)",
            // iPad Pro
            "iPad8,1": "iPad Pro 11-inch (1st generation)", "iPad8,2": "iPad Pro 11-inch (1st generation)",
            "iPad8,3": "iPad Pro 11-inch (1st generation)", "iPad8,4": "iPad Pro 11-inch (1st generation)",
            "iPad8,5": "iPad Pro 12.9-inch (3rd generation)", "iPad8,6": "iPad Pro 12.9-inch (3rd generation)",
            "iPad8,7": "iPad Pro 12.9-inch (3rd generation)", "iPad8,8": "iPad Pro 12.9-inch (3rd generation)",
            "iPad8,9": "iPad Pro 11-inch (2nd generation)", "iPad8,10": "iPad Pro 11-inch (2nd generation)",
            "iPad8,11": "iPad Pro 12.9-inch (4th generation)", "iPad8,12": "iPad Pro 12.9-inch (4th generation)",
            "iPad13,4": "iPad Pro 11-inch (3rd generation)", "iPad13,5": "iPad Pro 11-inch (3rd generation)",
            "iPad13,6": "iPad Pro 11-inch (3rd generation)", "iPad13,7": "iPad Pro 11-inch (3rd generation)",
            "iPad13,8": "iPad Pro 12.9-inch (5th generation)", "iPad13,9": "iPad Pro 12.9-inch (5th generation)",
            "iPad13,10": "iPad Pro 12.9-inch (5th generation)", "iPad13,11": "iPad Pro 12.9-inch (5th generation)",
            "iPad14,3": "iPad Pro 11-inch (4th generation)", "iPad14,4": "iPad Pro 11-inch (4th generation)",
            "iPad14,5": "iPad Pro 12.9-inch (6th generation)", "iPad14,6": "iPad Pro 12.9-inch (6th generation)",
            "iPad16,3": "iPad Pro 11-inch (M4)", "iPad16,4": "iPad Pro 11-inch (M4)",
            "iPad16,5": "iPad Pro 13-inch (M4)", "iPad16,6": "iPad Pro 13-inch (M4)",
        ]
        return names[productType]
    }
}
