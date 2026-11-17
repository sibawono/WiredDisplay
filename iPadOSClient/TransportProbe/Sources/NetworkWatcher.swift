import Foundation
import Network
import os

/// What iPadOS itself reports about the iPad's network interfaces. Used in
/// E-05b to show, from the iPad's side, that no wireless path exists while
/// bytes still flow over the cable.
struct NetworkStatus: Sendable, Equatable {
    /// nil until the first update.
    var wifiUsable: Bool?
    /// Non-loopback interfaces iPadOS currently offers, e.g. "en0 (wifi)".
    var interfaces: [String] = []
}

final class NetworkWatcher: @unchecked Sendable {
    private let queue = DispatchQueue(label: "wireddisplay.transportprobe.network")
    private let wifiMonitor = NWPathMonitor(requiredInterfaceType: .wifi)
    private let anyMonitor = NWPathMonitor()
    private let status = OSAllocatedUnfairLock(initialState: NetworkStatus())
    private let events: EventLog

    init(events: EventLog) {
        self.events = events
        wifiMonitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            let usable = path.status == .satisfied
            let changed = self.status.withLock { current -> Bool in
                defer { current.wifiUsable = usable }
                return current.wifiUsable != usable
            }
            // A usable path, not radio power: Control Center "off" only disconnects.
            if changed { self.events.append("WIFI path \(usable ? "usable" : "NOT usable")") }
        }
        anyMonitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            // availableInterfaces can list the same interface once per address
            // family; keep the first occurrence of each.
            var seen = Set<String>()
            let names = path.availableInterfaces
                .filter { $0.type != .loopback }
                .map { "\($0.name) (\($0.type))" }
                .filter { seen.insert($0).inserted }
            let changed = self.status.withLock { current -> Bool in
                defer { current.interfaces = names }
                return current.interfaces != names
            }
            if changed {
                self.events.append("NET status=\(path.status) interfaces=[\(names.joined(separator: ", "))]")
            }
        }
        wifiMonitor.start(queue: queue)
        anyMonitor.start(queue: queue)
    }

    func snapshot() -> NetworkStatus { status.withLock { $0 } }
}
