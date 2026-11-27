#if os(macOS)
import CAoaUSB
import Foundation

/// USB-attached Android device discovered via IOKit for Android Open Accessory (AOA) plug-and-play.
public struct AoaDevice: Equatable, Hashable, Sendable {
    public let locationID: UInt32
    public let vendorID: UInt16
    public let productID: UInt16
    public let inAccessoryMode: Bool
    public let serial: String
    public let product: String?

    public var fleetSerial: String { "\(AoaClient.serialPrefix)\(serial)" }
}

/// Pure IOKit Android Open Accessory (AOA) transport requiring no USB Debugging on Android.
public enum AoaClient {
    public static let serialPrefix = "aoa:"

    public enum ClientError: Error, Equatable, Sendable {
        case switchFailed
        case openFailed
    }

    public static func stripPrefix(_ fleetSerial: String) -> String? {
        guard fleetSerial.hasPrefix(serialPrefix) else { return nil }
        return String(fleetSerial.dropFirst(serialPrefix.count))
    }

    public static func listDevices() -> [AoaDevice] {
        var raw = [wd_aoa_device_t](repeating: wd_aoa_device_t(), count: 16)
        let count = Int(wd_aoa_discover(&raw, Int32(raw.count)))
        guard count > 0 else { return [] }
        return raw.prefix(count).map { entry in
            let serial = withUnsafeBytes(of: entry.serial) {
                String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self)
            }
            let prod = withUnsafeBytes(of: entry.product) {
                String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self)
            }
            return AoaDevice(
                locationID: entry.location_id,
                vendorID: entry.vendor_id,
                productID: entry.product_id,
                inAccessoryMode: entry.in_accessory_mode,
                serial: serial,
                product: prod.isEmpty ? nil : prod
            )
        }
    }

    /// Switches a non-AOA Android device into accessory mode (control requests 51/52/53).
    public static func switchToAccessory(_ device: AoaDevice) throws {
        guard wd_aoa_switch_to_accessory(device.locationID) == 0 else {
            throw ClientError.switchFailed
        }
    }

    /// Opens a UNIX socketpair bridged to the device's AOA bulk IN/OUT endpoints.
    public static func openBridge(_ device: AoaDevice) throws -> Int32 {
        let fd = wd_aoa_open_bridge(device.locationID)
        guard fd >= 0 else { throw ClientError.openFailed }
        return fd
    }
}
#endif
