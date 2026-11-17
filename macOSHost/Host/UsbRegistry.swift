import Foundation
import IOKit
import IOKit.usb

/// Read-only look at the IORegistry for Apple mobile devices on USB, to tell
/// apart "the iPad is not on the USB bus at all" from "it is on the bus but
/// usbmuxd does not list it" (BUG-037). No privileges, no side effects.
enum UsbRegistry {
    static let appleVendorID = 1452

    /// e.g. "iPad@00200000 config 5 speed 4" for every Apple iPad/iPhone on
    /// the bus; empty if none.
    static func appleMobileDevices() -> [String] {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOUSBHostDevice"), &iterator) == KERN_SUCCESS else {
            return ["IORegistry query failed"]
        }
        defer { IOObjectRelease(iterator) }
        var found: [String] = []
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            func property(_ key: String) -> Any? {
                IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
            }
            guard (property("idVendor") as? Int) == appleVendorID,
                  let name = property("USB Product Name") as? String,
                  name.hasPrefix("iPad") || name.hasPrefix("iPhone") else { continue }
            let location = (property("locationID") as? Int).map { String(format: "%08x", $0) } ?? "?"
            let configuration = (property("kUSBCurrentConfiguration") as? Int).map(String.init) ?? "none"
            let speed = (property("Device Speed") as? Int).map(String.init) ?? "?"
            let product = (property("idProduct") as? Int).map(String.init) ?? "?"
            found.append("\(name)@\(location) product \(product) config \(configuration) speed \(speed)")
        }
        return found
    }
}
