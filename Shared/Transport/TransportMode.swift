import Foundation
import WDProtocol
import WDSession

/// User-selectable connection policy for WiredDisplay.
public enum TransportMode: String, CaseIterable, Sendable {
    case usbOnly = "usb"
    case automatic = "auto"
    case wifiOnly = "wifi"

    public var title: String {
        switch self {
        case .usbOnly: return "USB-C Only"
        case .automatic: return "Automatic (USB-C + Wi-Fi)"
        case .wifiOnly: return "Wi-Fi Only"
        }
    }

    public var allowsUSB: Bool { self == .usbOnly || self == .automatic }
    public var allowsWiFi: Bool { self == .wifiOnly || self == .automatic }
}

/// The transport carrying an active session.
public enum ActiveTransportKind: String, Sendable, Equatable {
    case usb = "USB-C"
    case wifi = "Wi-Fi"
}

public enum TransportConstants {
    public static let wifiServiceType = "_wireddisplay._tcp"
    public static let defaultWiFiPort: UInt16 = 9101
    public static let wifiDialTimeout: TimeInterval = 5.0
}

/// Shared interface for framed, encrypted session transports (usbmuxd POSIX socket or Network.framework TCP).
public protocol FramedTransport: AnyObject, Sendable {
    var isClosed: Bool { get }
    var droppedVideoFrames: Int { get }
    var transportKind: ActiveTransportKind { get }

    func start()
    @discardableResult func send(_ stream: StreamType, payload: [UInt8]) -> Bool
    func sendVideo(_ payload: [UInt8], isKeyframe: Bool, timestampNanos: UInt64?) -> FramedSocket.VideoResult
    func close(_ reason: String)
}
