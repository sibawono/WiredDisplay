import Foundation
import Network

/// One WiredDisplay receiver discovered over Bonjour (`_wireddisplay._tcp`).
public struct BonjourPeer: Sendable, Equatable, Hashable {
    public let id: String
    public let name: String
    public let fingerprintPrefix: String?
    public let endpoint: NWEndpoint

    public init(id: String, name: String, fingerprintPrefix: String?, endpoint: NWEndpoint) {
        self.id = id
        self.name = name
        self.fingerprintPrefix = fingerprintPrefix
        self.endpoint = endpoint
    }
}

/// Discovers WiredDisplay iPad receivers on the local network via Bonjour.
public final class BonjourBrowser: @unchecked Sendable {
    private let queue = DispatchQueue(label: "wireddisplay.bonjour.browser", qos: .userInitiated)
    private let lock = NSLock()
    private var browser: NWBrowser?
    private var currentPeers: [BonjourPeer] = []
    private let onChange: @Sendable ([BonjourPeer]) -> Void

    public init(onChange: @escaping @Sendable ([BonjourPeer]) -> Void = { _ in }) {
        self.onChange = onChange
    }

    public var peers: [BonjourPeer] { lock.withLock { currentPeers } }

    public func start() {
        let shouldStart = lock.withLock { browser == nil }
        guard shouldStart else { return }
        let params = NWParameters()
        params.preferNoProxies = true
        let descriptor = NWBrowser.Descriptor.bonjourWithTXTRecord(type: TransportConstants.wifiServiceType, domain: nil)
        let nwBrowser = NWBrowser(for: descriptor, using: params)
        nwBrowser.browseResultsChangedHandler = { [weak self] results, _ in
            guard let self else { return }
            var found: [BonjourPeer] = []
            for result in results {
                guard case .service(let name, _, _, _) = result.endpoint else { continue }
                var fpPrefix: String?
                if case .bonjour(let txt) = result.metadata {
                    fpPrefix = txt["id"]
                }
                let id = fpPrefix ?? name
                found.append(BonjourPeer(id: id, name: name, fingerprintPrefix: fpPrefix, endpoint: result.endpoint))
            }
            found.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            self.lock.withLock { self.currentPeers = found }
            self.onChange(found)
        }
        lock.withLock { browser = nwBrowser }
        nwBrowser.start(queue: queue)
    }

    public func stop() {
        let active = lock.withLock { () -> NWBrowser? in
            defer { browser = nil; currentPeers = [] }
            return browser
        }
        active?.cancel()
    }
}
