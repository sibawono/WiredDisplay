import CryptoKit
import Foundation
import Security

/// Long-term identity and the list of trusted peers (D-023).
///
/// Production storage is the Keychain (generic password items, this device
/// only); tests use `MemoryStorage`. Peer public keys are not secret, but they
/// sit in the Keychain too so another app cannot quietly add a peer.
public final class TrustStore: @unchecked Sendable {
    public struct TrustedPeer: Codable, Sendable, Equatable {
        public var identityKey: [UInt8]
        public var name: String
        public var added: Date
        /// Model name ("iPad Air 13-inch (M2)"); nil for peers saved before it
        /// was recorded, or when the model could not be read.
        public var model: String? = nil
        public var fingerprint: String { SecureChannel.fingerprint(identityKey) }
    }

    public protocol Storage: Sendable {
        func read(_ account: String) -> Data?
        func write(_ account: String, _ data: Data) throws
        func delete(_ account: String)
    }

    private let storage: Storage
    private let lock = NSLock()
    private static let identityAccount = "identity.ed25519"
    private static let peersAccount = "trusted-peers"

    public init(storage: Storage) { self.storage = storage }

    /// Keychain storage under `service` (e.g. "dev.wireddisplay.host").
    public convenience init(keychainService service: String) {
        self.init(storage: KeychainStorage(service: service))
    }

    /// Loads the identity, creating and saving one on first use.
    public func identity() throws -> Curve25519.Signing.PrivateKey {
        try lock.withLock {
            if let data = storage.read(Self.identityAccount),
               let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: data) {
                return key
            }
            let key = Curve25519.Signing.PrivateKey()
            try storage.write(Self.identityAccount, key.rawRepresentation)
            return key
        }
    }

    public var peers: [TrustedPeer] {
        lock.withLock { loadPeers() }
    }

    public func isTrusted(_ identityKey: [UInt8]) -> Bool {
        lock.withLock { loadPeers().contains { $0.identityKey == identityKey } }
    }

    public func trust(_ identityKey: [UInt8], name: String) throws {
        try lock.withLock {
            var peers = loadPeers().filter { $0.identityKey != identityKey }
            peers.append(TrustedPeer(identityKey: identityKey, name: name, added: Date()))
            try storage.write(Self.peersAccount, try JSONEncoder().encode(peers))
        }
    }

    /// Updates the display name of a trusted peer (names arrive after trust).
    public func rename(_ identityKey: [UInt8], to name: String) {
        lock.withLock {
            var peers = loadPeers()
            guard let index = peers.firstIndex(where: { $0.identityKey == identityKey }), peers[index].name != name else { return }
            peers[index].name = name
            try? storage.write(Self.peersAccount, (try? JSONEncoder().encode(peers)) ?? Data())
        }
    }

    /// Updates name and model together (the host reads both from the device).
    /// A nil `model` keeps the stored one.
    public func update(_ identityKey: [UInt8], name: String, model: String?) {
        lock.withLock {
            var peers = loadPeers()
            guard let index = peers.firstIndex(where: { $0.identityKey == identityKey }) else { return }
            let newModel = model ?? peers[index].model
            guard peers[index].name != name || peers[index].model != newModel else { return }
            peers[index].name = name
            peers[index].model = newModel
            try? storage.write(Self.peersAccount, (try? JSONEncoder().encode(peers)) ?? Data())
        }
    }

    public func forgetAllPeers() {
        lock.withLock { storage.delete(Self.peersAccount) }
    }

    private func loadPeers() -> [TrustedPeer] {
        guard let data = storage.read(Self.peersAccount) else { return [] }
        return (try? JSONDecoder().decode([TrustedPeer].self, from: data)) ?? []
    }
}

public final class MemoryStorage: TrustStore.Storage, @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String: Data] = [:]
    public init() {}
    public func read(_ account: String) -> Data? { lock.withLock { items[account] } }
    public func write(_ account: String, _ data: Data) throws { lock.withLock { items[account] = data } }
    public func delete(_ account: String) { _ = lock.withLock { items.removeValue(forKey: account) } }
}

public struct KeychainStorage: TrustStore.Storage {
    public struct Failure: Error, CustomStringConvertible {
        public let status: OSStatus
        public var description: String { "Keychain error \(status)" }
    }

    public let service: String
    public init(service: String) { self.service = service }

    private func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    public func read(_ account: String) -> Data? {
        var request = query(account)
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(request as CFDictionary, &result) == errSecSuccess else { return nil }
        return result as? Data
    }

    public func write(_ account: String, _ data: Data) throws {
        let status = SecItemUpdate(query(account) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecSuccess { return }
        guard status == errSecItemNotFound else { throw Failure(status: status) }
        var item = query(account)
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let added = SecItemAdd(item as CFDictionary, nil)
        guard added == errSecSuccess else { throw Failure(status: added) }
    }

    public func delete(_ account: String) {
        SecItemDelete(query(account) as CFDictionary)
    }
}
