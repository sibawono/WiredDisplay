import AppKit
import CoreGraphics
import os

/// What the Mac is doing, as independent dimensions (they combine: a
/// screensaver can run on a locked session; a display can sleep while
/// locked; a wake event does not mean unlocked). WiredDisplay reacts to
/// transitions (docs/POWER_LOCK_WAKE.md):
/// - input from the iPad is injected only while the session is active,
///   unlocked and awake (never typed into the lock screen, never replayed);
/// - before system sleep the session is closed cleanly and no reconnect is
///   attempted until the Mac has woken;
/// - after wake, unlock, screensaver end or display wake the stream is
///   reconciled (display mode, fresh keyframe) instead of assumed ready.
struct PowerState: Equatable, Sendable, CustomStringConvertible {
    var systemAsleep = false
    var displaysAsleep = false
    var locked = false
    var screensaver = false
    /// False while another user's session is in front (fast user switching).
    var sessionActive = true

    /// iPad input may reach the Mac only in an awake, unlocked, active session.
    var allowsInput: Bool { !systemAsleep && !locked && sessionActive }

    var description: String {
        "sleep \(systemAsleep ? "Y" : "n") displays-asleep \(displaysAsleep ? "Y" : "n") locked \(locked ? "Y" : "n") " +
            "screensaver \(screensaver ? "Y" : "n") session-active \(sessionActive ? "Y" : "n")"
    }
}

/// The Mac's power/lock state, readable from any thread (input gating).
let currentPowerState = OSAllocatedUnfairLock(initialState: PowerState())

@MainActor
final class PowerMonitor {
    static let shared = PowerMonitor()

    private var current: OSAllocatedUnfairLock<PowerState> { currentPowerState }
    /// Main queue: (old, new) on every change.
    var onChange: [(PowerState, PowerState) -> Void] = []
    private var tokens: [NSObjectProtocol] = []
    private var started = false

    func start() {
        guard !started else { return }
        started = true
        // The session can already be locked at launch (login item after a
        // restart with "require password").
        let session = CGSessionCopyCurrentDictionary() as? [String: Any]
        let lockedNow = (session?["CGSSessionScreenIsLocked"] as? Bool) ?? false
        let onConsole = (session?[kCGSessionOnConsoleKey as String] as? Bool) ?? true
        update("launch") { $0.locked = lockedNow; $0.sessionActive = onConsole }

        let workspace = NSWorkspace.shared.notificationCenter
        observe(workspace, NSWorkspace.willSleepNotification) { $0.systemAsleep = true }
        observe(workspace, NSWorkspace.didWakeNotification) { $0.systemAsleep = false }
        observe(workspace, NSWorkspace.screensDidSleepNotification) { $0.displaysAsleep = true }
        observe(workspace, NSWorkspace.screensDidWakeNotification) { $0.displaysAsleep = false }
        observe(workspace, NSWorkspace.sessionDidResignActiveNotification) { $0.sessionActive = false }
        observe(workspace, NSWorkspace.sessionDidBecomeActiveNotification) { $0.sessionActive = true }
        let distributed = DistributedNotificationCenter.default()
        observe(distributed, Notification.Name("com.apple.screenIsLocked")) { $0.locked = true }
        observe(distributed, Notification.Name("com.apple.screenIsUnlocked")) { $0.locked = false }
        observe(distributed, Notification.Name("com.apple.screensaver.didstart")) { $0.screensaver = true }
        observe(distributed, Notification.Name("com.apple.screensaver.didstop")) { $0.screensaver = false }
        // Notifications can be missed (a screensaver that exits without
        // "didstop", an event before launch): every 2 s, compare with what
        // the system reports and correct the state (measured: a screensaver
        // ended without notifications left it stale).
        let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.reconcile() }
        }
        RunLoop.main.add(timer, forMode: .common)
        reconcileTimer = timer
    }

    private var reconcileTimer: Timer?

    /// The session dictionary is the authority for "locked" and "on console";
    /// the screensaver runs as its own app.
    private func reconcile() {
        let session = CGSessionCopyCurrentDictionary() as? [String: Any]
        let lockedNow = (session?["CGSSessionScreenIsLocked"] as? Bool) ?? false
        let onConsole = (session?[kCGSessionOnConsoleKey as String] as? Bool) ?? true
        let saverRunning = NSWorkspace.shared.runningApplications
            .contains { $0.bundleIdentifier == "com.apple.ScreenSaver.Engine" }
        let state = current.withLock { $0 }
        guard state.locked != lockedNow || state.sessionActive != onConsole || state.screensaver != saverRunning,
              !state.systemAsleep else { return }
        update("reconcile") { $0.locked = lockedNow; $0.sessionActive = onConsole; $0.screensaver = saverRunning }
    }

    private func observe(_ center: NotificationCenter, _ name: Notification.Name, _ change: @escaping @Sendable (inout PowerState) -> Void) {
        tokens.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.update(name.rawValue, change) }
        })
    }

    private func update(_ event: String, _ change: (inout PowerState) -> Void) {
        // Unchecked: the closure runs synchronously under the lock.
        let (old, new) = current.withLockUnchecked { state -> (PowerState, PowerState) in
            let old = state
            change(&state)
            return (old, state)
        }
        Log.info("power: \(event) -> \(new)")
        guard old != new else { return }
        for handler in onChange { handler(old, new) }
    }
}
