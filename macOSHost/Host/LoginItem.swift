import Foundation
import ServiceManagement

/// "Open at Login" via SMAppService (macOS 13+): registers this app bundle as a
/// login item, visible in System Settings › General › Login Items. On by
/// default the first time the host runs; the menu toggle turns it off for good.
/// A login launch has no command-line flags, so it starts with the defaults
/// (touch input off, D-006) and connects as soon as the iPad app is open.
enum LoginItem {
    private static let configuredKey = "loginItemConfigured"

    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }
    static var needsApproval: Bool { SMAppService.mainApp.status == .requiresApproval }

    /// First launch only: enable it once, then respect what the user chose.
    static func applyDefault() {
        guard !UserDefaults.standard.bool(forKey: configuredKey) else { return }
        set(true)
    }

    static func set(_ enabled: Bool) {
        UserDefaults.standard.set(true, forKey: configuredKey)
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            Log.info("Open at Login \(enabled ? "enabled" : "disabled") (status \(SMAppService.mainApp.status.rawValue))")
        } catch {
            Log.warn("Open at Login: \(enabled ? "register" : "unregister") failed: \(error.localizedDescription)")
        }
    }
}
