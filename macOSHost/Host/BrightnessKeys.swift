import AppKit
import CoreGraphics

/// Brightness keys on the Mac's keyboard -> the iPad's real screen brightness
/// (D-033). The virtual display has no backlight, so macOS cannot dim it; this
/// catches the keys (system-defined events, as MonitorControl does) while an
/// iPad is connected and leaves them alone otherwise. Option-Shift = fine steps.
/// Needs Accessibility (an active event tap), which input injection uses too.
@MainActor
final class BrightnessKeys {
    nonisolated private let controller: HostController
    // Set once on the main thread; the tap callback runs on the main run loop too.
    nonisolated(unsafe) private var tap: CFMachPort?
    private var retry: Timer?
    private var warned = false

    // NX_SYSDEFINED event, subtype NX_SUBTYPE_AUX_CONTROL_BUTTONS, keys from ev_keymap.h.
    nonisolated private static let systemDefined = CGEventType(rawValue: 14)!
    nonisolated private static let auxControlButtons: Int16 = 8
    nonisolated private static let brightnessUp = 2, brightnessDown = 3
    /// Key codes third-party keyboards send for display brightness (HID
    /// consumer "Display Brightness Increment/Decrement").
    nonisolated private static let brightnessUpKeyCode: Int64 = 144, brightnessDownKeyCode: Int64 = 145
    /// `--trace-keys`: log system-defined events and function-key presses
    /// (never letters or digits) for 10 min, to see what a keyboard sends.
    nonisolated static let tracing = CommandLine.arguments.contains("--trace-keys")
    nonisolated private static let traceUntil = Date().addingTimeInterval(600)
    nonisolated private static let functionKeyCodes: Set<Int64> = [122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111,
                                                                    105, 107, 113, 106, 64, 79, 80, 90, 145, 144, 160, 131, 177, 176]

    init(controller: HostController) {
        self.controller = controller
    }

    func start() {
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
            retry = Timer.scheduledTimer(withTimeInterval: 10, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated { self?.start() }
            }
            return
        }
        self.tap = tap
        let source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        Log.info("brightness keys: listening at \(level) level")
    }

    /// Runs on the main run loop (the tap source is added there).
    nonisolated private func handle(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
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
                  controller.brightnessKeysTargetIPad else { return Unmanaged.passUnretained(event) }
            if type == .keyDown {
                let fine = event.flags.contains([.maskAlternate, .maskShift])
                controller.stepBrightness(up: code == Self.brightnessUpKeyCode, fine: fine)
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
        guard controller.brightnessKeysTargetIPad else { return Unmanaged.passUnretained(event) }
        if isDown {
            let fine = ns.modifierFlags.contains([.option, .shift])
            controller.stepBrightness(up: key == Self.brightnessUp, fine: fine)
            Log.info("brightness key \(key == Self.brightnessUp ? "up" : "down") -> iPad \(controller.brightness.map { String(format: "%.2f", $0) } ?? "-")")
        }
        return nil // swallow both down and up while an iPad is connected
    }
}
