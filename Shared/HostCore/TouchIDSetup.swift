import Foundation

/// What the Security tab says about iPad Touch ID / Face ID for the Mac, from what is on disk.
public struct TouchIDSetup: Sendable, Equatable {
    public enum Part: String, Sendable, CaseIterable {
        case sudoModule = "sudo module"
        case lockScreenPlugin = "Lock Screen plugin"
        case key = "this iPad's key"
    }

    public enum Status: Sendable, Equatable {
        case notInstalled
        /// Some parts are on disk, others are missing.
        case partial(missing: [Part])
        /// Installed for another key: the iPad was re-enrolled since Install Extras ran.
        case keyChanged
        case installed
    }

    public let sudoModule: Bool
    public let lockScreenPlugin: Bool
    /// The base64 key installed for this user (`pam_keys/<user>.pub`), if any.
    public let installedKey: String?
    /// The connected iPad's current key, base64, if it sent one.
    public let iPadKey: String?

    public init(sudoModule: Bool, lockScreenPlugin: Bool, installedKey: String?, iPadKey: String?) {
        self.sudoModule = sudoModule
        self.lockScreenPlugin = lockScreenPlugin
        self.installedKey = installedKey?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.iPadKey = iPadKey?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public var status: Status {
        let hasKey = !(installedKey ?? "").isEmpty
        var missing: [Part] = []
        if !sudoModule { missing.append(.sudoModule) }
        if !lockScreenPlugin { missing.append(.lockScreenPlugin) }
        if !hasKey { missing.append(.key) }
        if missing.count == Part.allCases.count { return .notInstalled }
        if !missing.isEmpty { return .partial(missing: missing) }
        if let iPadKey, !iPadKey.isEmpty, iPadKey != installedKey { return .keyChanged }
        return .installed
    }
}
