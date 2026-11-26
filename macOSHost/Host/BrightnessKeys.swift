import AppKit
import CoreGraphics

/// Brightness keys on the Mac's keyboard -> the iPad's real screen brightness
/// (D-033). The virtual display has no backlight, so macOS cannot dim it; this
/// catches the keys (system-defined events, as MonitorControl does) while an
/// iPad is connected and leaves them alone otherwise. Option-Shift = fine steps.
/// Needs Accessibility (an active event tap), which input injection uses too.
/// One event tap for every iPad (audit C-3), on its own thread: the tap is
/// active (it swallows brightness keys) and sees every key press, so on the
/// main thread each keystroke on the Mac waited for the host's UI work, and
/// there was one tap per iPad.
final class BrightnessKeys: @unchecked Sendable {
    static let shared = BrightnessKeys()

    private let lock = NSLock()
    private var controllers: [HostController] = []
    private var tap: CFMachPort? // tap thread only, after creation
    private var started = false
    private var warned = false

    // NX_SYSDEFINED event, subtype NX_SUBTYPE_AUX_CONTROL_BUTTONS, keys from ev_keymap.h.
    private static let systemDefined = CGEventType(rawValue: 14)!
    private static let auxControlButtons: Int16 = 8
    private static let brightnessUp = 2, brightnessDown = 3
    /// Key codes third-party keyboards send for display brightness (HID
    /// consumer "Display Brightness Increment/Decrement").
    private static let brightnessUpKeyCode: Int64 = 144, brightnessDownKeyCode: Int64 = 145
    /// `--trace-keys`: log system-defined events and function-key presses
    /// (never letters or digits) for 10 min, to see what a keyboard sends.
    static let tracing = CommandLine.arguments.contains("--trace-keys")
    private static let traceUntil = Date().addingTimeInterval(600)
    private static let functionKeyCodes: Set<Int64> = [122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111,
                                                                    105, 107, 113, 106, 64, 79, 80, 90, 145, 144, 160, 131, 177, 176]

    /// Adds an iPad's controller; starts the tap thread on first use.
    func add(_ controller: HostController) {
        let first = lock.withLock { () -> Bool in
            controllers.append(controller)
            defer { started = true }
            return !started
        }
        guard first else { return }
        let thread = Thread { [self] in
            install()
            // Keep the run loop alive while the tap is retried.
            let keepAlive = CFRunLoopTimerCreateWithHandler(nil, CFAbsoluteTimeGetCurrent() + 1e9, 0, 0, 0) { _ in }
            CFRunLoopAddTimer(CFRunLoopGetCurrent(), keepAlive, .commonModes)
            CFRunLoopRun()
        }
        thread.name = "wireddisplay.brightness-keys"
        thread.qualityOfService = .userInteractive
        thread.start()
    }

    /// Removes an unplugged iPad's controller so it can be deallocated.
    func remove(_ controller: HostController) {
        lock.withLock { controllers.removeAll { $0 === controller } }
    }

    /// The iPad the keys act on now: the first whose screen has the pointer
    /// (or the only display).
    private var target: HostController? {
        lock.withLock { controllers }.first { $0.brightnessKeysTargetIPad }
    }

    /// On the tap thread.
    private func install() {
        guard tap == nil else { return }
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        let callback: CGEventTapCallBack = { _, type, event, refcon in
            guard let refcon else { return Unmanaged.passUnretained(event) }
            return Unmanaged<BrightnessKeys>.fromOpaque(refcon).takeUnretainedValue().handle(type, event)
        }
        // HID level first: it sees the keys before session-level taps, so
        // WiredDisplay wins over other brightness utilities (BetterDisplay,
        // MonitorControl) for the iPad. Session level as a fallback.
        // Apple keyboards send brightness as system-defined events; many
        // third-party keyboards (e.g. ProtoArc K90) send key codes 144/145.
        let mask = (CGEventMask(1) << Self.systemDefined.rawValue) | (CGEventMask(1) << CGEventType.keyDown.rawValue)
            | (CGEventMask(1) << CGEventType.keyUp.rawValue)
        var level = "HID"
        var created = CGEvent.tapCreate(tap: .cghidEventTap, place: .headInsertEventTap, options: .defaultTap,
                                        eventsOfInterest: mask, callback: callback, userInfo: refcon)
        if created == nil {
            level = "session"
            created = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                        eventsOfInterest: mask, callback: callback, userInfo: refcon)
        }
        guard let tap = created else {
            if !warned {
                Log.warn("brightness keys: event tap unavailable (Accessibility not granted); retrying")
                warned = true
            }
            let retry = CFRunLoopTimerCreateWithHandler(nil, CFAbsoluteTimeGetCurrent() + 10, 0, 0, 0) { [weak self] _ in
                self?.install()
            }
            CFRunLoopAddTimer(CFRunLoopGetCurrent(), retry, .commonModes)
            return
        }
        self.tap = tap
        let source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        Log.info("brightness keys: listening at \(level) level")
    }

    /// Runs on the tap thread.
    private func handle(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        if Self.tracing, Date() < Self.traceUntil {
            if type == .keyDown {
                let code = event.getIntegerValueField(.keyboardEventKeycode)
                if Self.functionKeyCodes.contains(code) {
                    Log.info("trace-keys: keyDown function key code \(code) flags \(String(event.flags.rawValue, radix: 16))")
                }
            } else if type == Self.systemDefined, let ns = NSEvent(cgEvent: event) {
                Log.info("trace-keys: systemDefined subtype \(ns.subtype.rawValue) data1 \(String(ns.data1, radix: 16))")
            }
        }
        if type == .keyDown || type == .keyUp {
            let code = event.getIntegerValueField(.keyboardEventKeycode)
            guard code == Self.brightnessUpKeyCode || code == Self.brightnessDownKeyCode,
                  let controller = target else { return Unmanaged.passUnretained(event) }
            if type == .keyDown {
                let fine = event.flags.contains([.maskAlternate, .maskShift])
                _ = controller.stepBrightness(up: code == Self.brightnessUpKeyCode, fine: fine)
                Log.info("brightness key \(code == Self.brightnessUpKeyCode ? "up" : "down") (key code) -> iPad " +
                         (controller.brightness.map { String(format: "%.2f", $0) } ?? "-"))
            }
            return nil
        }
        guard type == Self.systemDefined, let ns = NSEvent(cgEvent: event),
              ns.subtype.rawValue == Self.auxControlButtons else { return Unmanaged.passUnretained(event) }
        let key = (ns.data1 & 0xFFFF_0000) >> 16
        let isDown = (ns.data1 & 0xFF00) >> 8 == 0x0A
        guard key == Self.brightnessUp || key == Self.brightnessDown else { return Unmanaged.passUnretained(event) }
        // No iPad, or the pointer is on another display: that display's own
        // controls (macOS, BetterDisplay, Sidecar) handle it.
        guard let controller = target else { return Unmanaged.passUnretained(event) }
        if isDown {
            let fine = ns.modifierFlags.contains([.option, .shift])
            _ = controller.stepBrightness(up: key == Self.brightnessUp, fine: fine)
            Log.info("brightness key \(key == Self.brightnessUp ? "up" : "down") -> iPad \(controller.brightness.map { String(format: "%.2f", $0) } ?? "-")")
        }
        return nil // swallow both down and up while an iPad is connected
    }
}
