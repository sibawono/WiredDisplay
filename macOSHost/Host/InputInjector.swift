import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import IOKit.pwr_mgt
import WDHostCore
import WDSession

/// Turns validated client input into CGEvents on one display (R-INP-01).
///
/// Safety (D-006, spec §6):
/// - `isEnabled` is read on every event from the controller's single source of
///   truth, so turning input off takes effect immediately (review finding 2).
/// - Requires the Accessibility permission; without it events are dropped.
/// - Positions are normalized and validated by the decoder, then clamped onto
///   this display's bounds. If the display is gone, input is dropped and any
///   held button released, never redirected to another display (finding A).
/// - Before a scroll the cursor is moved onto this display, because macOS
///   scrolls the window under the real cursor (finding 3).
/// - `releaseAll()` lifts any held button; the session calls it on disconnect.
/// - Only moves and scrolls are rate-limited; button releases always pass
///   (finding 6).
///
/// Keyboard (R-INP-02): HID usages from the iPad's hardware keyboard become
/// key events with the modifier flags tracked here. Key repeat is generated
/// here (the iPad sends one down/up per press) at the Mac's own repeat
/// settings. Keystrokes are NEVER logged, only counted. `releaseAll()` lifts
/// every held key and modifier too.
///
/// Concurrency: used only from the session's serial queue (`queue`).
// All mutable state is accessed exclusively on `queue`.
final class InputInjector: @unchecked Sendable {
    private let displayID: CGDirectDisplayID
    private let isEnabled: @Sendable () -> Bool
    private let source = CGEventSource(stateID: .hidSystemState)
    private var heldButton: PointerButton = .none
    private var lastPoint: CGPoint?
    private var lastDown: (time: TimeInterval, point: CGPoint, button: PointerButton, count: Int64)?
    private var scrollRemainder = CGPoint.zero
    private var windowStart = Date()
    private var eventsInWindow = 0
    private var warnedNoPermission = false
    static let maxMovesPerSecond = 500

    // Keyboard state.
    private let queue: DispatchQueue
    private var heldKeys = Set<UInt16>()       // HID usages currently down (incl. modifiers)
    private var capsLock = false
    private var repeatTimer: DispatchSourceTimer?
    private var keysSinceLog = 0

    /// The Mac's power/lock state (docs/POWER_LOCK_WAKE.md).
    private let power: @Sendable () -> PowerState
    private var loggedPowerBlock = false

    init(displayID: CGDirectDisplayID, queue: DispatchQueue, isEnabled: @escaping @Sendable () -> Bool,
         power: @escaping @Sendable () -> PowerState = { PowerState() }) {
        self.displayID = displayID
        self.queue = queue
        self.isEnabled = isEnabled
        self.power = power
    }

    /// Diagnostics (E-07): every non-move event is logged with where it was
    /// posted and where the real cursor ended up; moves are counted.
    private var movesSinceLog = 0
    private var loggedDisabled = false

    private func trace(_ what: String, _ point: CGPoint? = nil) {
        let cursor = CGEvent(source: nil)?.location ?? .zero
        let target = point.map { String(format: " at (%.0f,%.0f)", $0.x, $0.y) } ?? ""
        Log.info(String(format: "INPUT %@%@ cursor now (%.0f,%.0f) display %u bounds %@ moves since last %d",
                        what, target, cursor.x, cursor.y, displayID,
                        NSStringFromRect(NSRectFromCGRect(CGDisplayBounds(displayID))), movesSinceLog))
        movesSinceLog = 0
    }

    func handle(_ event: InputEvent) {
        firePendingUp() // a held-back mouse-up goes before anything newer
        // Logged: clicks and gesture boundaries only. Moves, scroll steps and
        // gesture steps are counted (at 60-120 Hz they filled the log and
        // slowed the session queue); keystrokes are never logged.
        switch event {
        case .pointer(.move, _, _, _), .stylus(.move, _, _, _): movesSinceLog += 1
        case .key, .scroll, .gestureScroll: break
        case .magnify(_, .changed), .rotate(_, .changed): gestureSteps += 1
        case .magnify, .rotate: break // boundaries are logged when posted
        case .pointer, .stylus: break // down/up are logged when posted
        case .releaseAll: trace("received \(event)")
        }
        guard isEnabled() else {
            if !loggedDisabled {
                loggedDisabled = true
                Log.info("INPUT dropped: input from the iPad is off (logged once until it is enabled again)")
            }
            return releaseAll()
        }
        loggedDisabled = false
        // Locked (macOS also reports the screensaver as locked), asleep or
        // another user in front: nothing may be clicked, scrolled or typed —
        // no keystroke reaches the password field and no tap made to wake the
        // Mac is replayed as a click afterwards. A pointer move alone still
        // passes while the session is ours and awake: it wakes the display or
        // dismisses the screensaver, like nudging the Mac's own mouse.
        let state = power()
        if !state.allowsInput {
            if !loggedPowerBlock {
                loggedPowerBlock = true
                Log.info("INPUT limited: Mac \(state); only pointer moves pass until it is unlocked and awake")
            }
            releaseAll()
            switch InputGate.decision(for: event, state: state) {
            case .moveOnly:
                guard case .pointer(_, _, let x, let y) = event, withinRateLimit(), let bounds = liveBounds() else { return }
                lastPoint = clamp(CGPoint(x: bounds.minX + CGFloat(x) * bounds.width,
                                          y: bounds.minY + CGFloat(y) * bounds.height), to: bounds)
                post(.mouseMoved, at: lastPoint!, button: .none, clickState: 0)
            case .wakeAndDrop:
                wakeDisplays()
            case .drop, .inject:
                break
            }
            return
        }
        loggedPowerBlock = false
        guard AXIsProcessTrusted() else {
            if !warnedNoPermission {
                Log.warn("input dropped: Accessibility permission not granted to this app")
                warnedNoPermission = true
            }
            return
        }
        guard let bounds = liveBounds() else {
            Log.warn("input dropped: virtual display \(displayID) is not online")
            return releaseAll()
        }

        switch event {
        case .pointer(let phase, let button, let x, let y):
            let point = clamp(CGPoint(x: bounds.minX + CGFloat(x) * bounds.width,
                                      y: bounds.minY + CGFloat(y) * bounds.height), to: bounds)
            switch phase {
            case .move:
                guard withinRateLimit() else { return }
                move(to: point)
            case .down:
                press(button, at: point)
                trace("posted \(button) down", point)
            case .up:
                release(button, at: point)
                trace("posted \(button) up", point)
            }
        case .stylus(let phase, let x, let y, let pressure):
            let point = clamp(CGPoint(x: bounds.minX + CGFloat(x) * bounds.width,
                                      y: bounds.minY + CGFloat(y) * bounds.height), to: bounds)
            switch phase {
            case .move:
                guard withinRateLimit() else { return }
                lastPoint = point
                post(heldButton == .left ? .leftMouseDragged : .mouseMoved, at: point,
                     button: heldButton == .left ? .left : .none,
                     clickState: heldButton == .left ? 1 : 0, pressure: Double(pressure))
            case .down:
                if heldButton != .none { releaseAll() }
                lastPoint = point
                let now = ProcessInfo.processInfo.systemUptime
                var count: Int64 = 1
                if let last = lastDown, last.button == .left, now - last.time <= NSEvent.doubleClickInterval,
                   hypot(last.point.x - point.x, last.point.y - point.y) <= 6 {
                    count = min(last.count + 1, 3)
                }
                lastDown = (now, point, .left, count)
                heldButton = .left
                post(.leftMouseDown, at: point, button: .left, clickState: count, pressure: Double(pressure))
                trace("posted stylus down", point)
            case .up:
                guard heldButton == .left else { return }
                lastPoint = point
                heldButton = .none
                let clicks = lastDown?.count ?? 1
                post(.leftMouseUp, at: point, button: .left, clickState: clicks, pressure: 0)
                trace("posted stylus up", point)
            }
        case .scroll(let dx, let dy):
            guard withinRateLimit() else { return }
            scroll(dx: CGFloat(dx), dy: CGFloat(dy), bounds: bounds)
        case .releaseAll:
            releaseAll()
        case .key(let usage, let down):
            key(usage, down: down)
        case .gestureScroll(let dx, let dy, let phase, let momentum):
            guard withinRateLimit() || phase != .changed && phase != .none else { return }
            gestureScroll(dx: CGFloat(dx), dy: CGFloat(dy), phase: phase, momentum: momentum, bounds: bounds)
        case .magnify(let delta, let phase):
            guard withinRateLimit() || phase != .changed else { return }
            transform(hidType: Self.hidZoom, value: Double(delta), phase: phase)
        case .rotate(let degrees, let phase):
            guard withinRateLimit() || phase != .changed else { return }
            transform(hidType: Self.hidRotation, value: Double(degrees), phase: phase)
        }
    }

    // MARK: waking the displays

    private var userActivity = IOPMAssertionID(0)
    private var lastWake = 0.0

    /// Declared user activity wakes the displays; the one-point pointer nudge also ends a
    /// screensaver. At most twice a second.
    private func wakeDisplays() {
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastWake >= 0.5 else { return }
        lastWake = now
        IOPMAssertionDeclareUserActivity("WiredDisplay: input on the iPad" as CFString, kIOPMUserActiveLocal, &userActivity)
        let cursor = CGEvent(source: nil)?.location ?? .zero
        post(.mouseMoved, at: CGPoint(x: cursor.x + 1, y: cursor.y), button: .none, clickState: 0)
        post(.mouseMoved, at: cursor, button: .none, clickState: 0)
        Log.info("INPUT woke the displays (the event itself was not passed on)")
    }

    // MARK: pinch and rotate (D-029)

    /// Undocumented CGEvent layout of trackpad gesture events, as used by
    /// Hammerspoon and others: event type 29 (NSEventTypeGesture) with an IOHID
    /// event type that AppKit turns into NSEventTypeMagnify / NSEventTypeRotate.
    /// Verified with NSEvent(cgEvent:) on macOS 27; may break in a later release,
    /// in which case pinch falls back to Command-plus / Command-minus.
    private static let gestureEventType = CGEventType(rawValue: 29)
    private static let hidZoom: Int64 = 8, hidRotation: Int64 = 5
    private static let fieldHIDType = CGEventField(rawValue: 110)
    private static let fieldZoomValue = CGEventField(rawValue: 113)
    private static let fieldRotationValue = CGEventField(rawValue: 114)
    private static let fieldPhase = CGEventField(rawValue: 132)
    private var gestureSteps = 0
    private var fallbackZoom = PinchZoomStepper()
    private var fallbackScale: CGFloat = 1

    private func transform(hidType: Int64, value: Double, phase: ScrollPhase) {
        let gesturePhase: Int64
        switch phase {
        case .began: gesturePhase = 1
        case .changed: gesturePhase = 2
        case .ended: gesturePhase = 4
        case .cancelled: gesturePhase = 8
        case .none: return
        }
        let name = hidType == Self.hidZoom ? "magnify" : "rotate"
        if phase == .began { gestureSteps = 0 }
        gestures.note(hidType == Self.hidZoom ? .magnify : .rotate, phase: phase)
        guard let type = Self.gestureEventType, let hid = Self.fieldHIDType, let zoom = Self.fieldZoomValue,
              let rotation = Self.fieldRotationValue, let phaseField = Self.fieldPhase,
              let event = CGEvent(source: nil) else {
            if hidType == Self.hidZoom { fallbackPinch(delta: value, phase: phase) }
            return
        }
        event.type = type
        event.location = CGEvent(source: nil)?.location ?? .zero // routed to the window under the cursor
        event.setIntegerValueField(hid, value: hidType)
        event.setIntegerValueField(phaseField, value: gesturePhase)
        event.setDoubleValueField(hidType == Self.hidZoom ? zoom : rotation, value: value)
        event.post(tap: .cghidEventTap)
        if phase != .changed { trace("posted \(name) \(phase) after \(gestureSteps) steps") }
    }

    /// Command-plus / Command-minus steps, as before D-029.
    private func fallbackPinch(delta: Double, phase: ScrollPhase) {
        switch phase {
        case .began: fallbackZoom.begin(); fallbackScale = 1
        case .changed:
            fallbackScale = max(0.05, fallbackScale + CGFloat(delta))
            for case .key(let usage, let down) in fallbackZoom.update(scale: fallbackScale) { key(usage, down: down) }
        default: break
        }
    }

    func releaseAll() {
        firePendingUp()
        releaseKeys()
        endOpenGestures()
        guard heldButton != .none else { return }
        Log.info("releasing held \(heldButton) button")
        let point = lastPoint ?? CGEvent(source: nil)?.location ?? .zero
        post(heldButton == .right ? .rightMouseUp : .leftMouseUp, at: point, button: heldButton, clickState: 1)
        heldButton = .none
    }

    /// Trackpad gestures begun on the Mac but never ended (audit AUD-02).
    private var gestures = GestureTracker()

    /// Ends every gesture the Mac still sees as running, so no app stays
    /// mid-scroll (rubber band held) or mid-pinch after input stops.
    private func endOpenGestures() {
        for kind in gestures.takeOpen() {
            switch kind {
            case .scroll: postScrollBoundary(phase: Int64(CGScrollPhase.cancelled.rawValue),
                                             momentum: Int64(CGMomentumScrollPhase.none.rawValue))
            case .momentum: postScrollBoundary(phase: 0, momentum: Int64(CGMomentumScrollPhase.end.rawValue))
            case .magnify: transform(hidType: Self.hidZoom, value: 0, phase: .cancelled)
            case .rotate: transform(hidType: Self.hidRotation, value: 0, phase: .cancelled)
            }
            Log.info("INPUT ended open \(kind) gesture")
        }
    }

    private func postScrollBoundary(phase: Int64, momentum: Int64) {
        guard let event = CGEvent(scrollWheelEvent2Source: source, units: .pixel, wheelCount: 2,
                                  wheel1: 0, wheel2: 0, wheel3: 0) else { return }
        event.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        event.setIntegerValueField(.scrollWheelEventScrollPhase, value: phase)
        event.setIntegerValueField(.scrollWheelEventMomentumPhase, value: momentum)
        event.post(tap: .cghidEventTap)
    }

    // MARK: geometry

    private func liveBounds() -> CGRect? {
        guard CGDisplayIsOnline(displayID) != 0 else { return nil }
        let bounds = CGDisplayBounds(displayID)
        return bounds.isEmpty ? nil : bounds
    }

    private func clamp(_ point: CGPoint, to bounds: CGRect) -> CGPoint {
        CGPoint(x: min(max(point.x, bounds.minX), bounds.maxX.nextDown),
                y: min(max(point.y, bounds.minY), bounds.maxY.nextDown))
    }

    // MARK: pointer

    private func move(to point: CGPoint) {
        lastPoint = point
        switch heldButton {
        case .left: post(.leftMouseDragged, at: point, button: .left, clickState: 1)
        case .right: post(.rightMouseDragged, at: point, button: .right, clickState: 1)
        case .none: post(.mouseMoved, at: point, button: .none, clickState: 0)
        }
    }

    private func press(_ button: PointerButton, at point: CGPoint) {
        if heldButton != .none { releaseAll() } // never two buttons held
        lastPoint = point
        let now = ProcessInfo.processInfo.systemUptime
        // Double click: same button, within the system interval and 6 points.
        var count: Int64 = 1
        if let last = lastDown, last.button == button, now - last.time <= NSEvent.doubleClickInterval,
           hypot(last.point.x - point.x, last.point.y - point.y) <= 6 {
            count = min(last.count + 1, 3)
        }
        lastDown = (now, point, button, count)
        heldButton = button
        post(button == .right ? .rightMouseDown : .leftMouseDown, at: point, button: button, clickState: count)
    }

    /// A tap arrives as down+up in the same millisecond (E-07 log). Some apps
    /// ignore zero-length clicks, so hold the button at least this long.
    static let minimumClickDuration: TimeInterval = 0.025

    private func release(_ button: PointerButton, at point: CGPoint) {
        guard heldButton == button else { return } // unmatched up: ignore
        lastPoint = point
        heldButton = .none
        let clicks = lastDown?.count ?? 1
        let up: () -> Void = { [weak self] in
            self?.post(button == .right ? .rightMouseUp : .leftMouseUp, at: point, button: button, clickState: clicks)
        }
        let held = lastDown.map { ProcessInfo.processInfo.systemUptime - $0.time } ?? Self.minimumClickDuration
        guard held < Self.minimumClickDuration else { up(); return }
        // Too short: post the release a little later instead of sleeping, so
        // the session queue (audio, control, other input) never waits on it.
        // The next event posts it first, which keeps the order.
        pendingUp = up
        queue.asyncAfter(deadline: .now() + (Self.minimumClickDuration - held)) { [weak self] in self?.firePendingUp() }
    }

    /// A mouse-up held back by `release` (minimum click length).
    private var pendingUp: (() -> Void)?

    private func firePendingUp() {
        guard let up = pendingUp else { return }
        pendingUp = nil
        up()
    }

    // MARK: scroll

    private func scroll(dx: CGFloat, dy: CGFloat, bounds: CGRect) {
        // Scroll goes to the window under the real cursor: make sure it is here.
        let cursor = CGEvent(source: nil)?.location ?? .zero
        if !bounds.contains(cursor) {
            let target = lastPoint.map { clamp($0, to: bounds) } ?? CGPoint(x: bounds.midX, y: bounds.midY)
            move(to: target)
        }
        // Accumulate sub-point deltas so slow scrolls still move (finding 8).
        scrollRemainder.x += dx
        scrollRemainder.y += dy
        let wholeX = scrollRemainder.x.rounded(.towardZero)
        let wholeY = scrollRemainder.y.rounded(.towardZero)
        guard wholeX != 0 || wholeY != 0 else { return }
        scrollRemainder.x -= wholeX
        scrollRemainder.y -= wholeY
        guard let event = CGEvent(scrollWheelEvent2Source: source, units: .pixel, wheelCount: 2,
                                  wheel1: Int32(wholeY), wheel2: Int32(wholeX), wheel3: 0) else { return }
        if !flags.isEmpty { event.flags = flags }
        event.post(tap: .cghidEventTap)
    }

    /// Continuous ("trackpad") scroll: phase fields make AppKit treat it like a
    /// real trackpad (smooth, momentum, rubber band at the edges).
    private func gestureScroll(dx: CGFloat, dy: CGFloat, phase: ScrollPhase, momentum: MomentumPhase, bounds: CGRect) {
        if phase == .began {
            scrollRemainder = .zero
            let cursor = CGEvent(source: nil)?.location ?? .zero
            if !bounds.contains(cursor) {
                move(to: lastPoint.map { clamp($0, to: bounds) } ?? CGPoint(x: bounds.midX, y: bounds.midY))
            }
        }
        scrollRemainder.x += dx
        scrollRemainder.y += dy
        let wholeX = scrollRemainder.x.rounded(.towardZero)
        let wholeY = scrollRemainder.y.rounded(.towardZero)
        // Phase boundaries are posted even without movement.
        let boundary = (phase != .changed && phase != .none) || momentum == .begin || momentum == .end
        guard wholeX != 0 || wholeY != 0 || boundary else { return }
        scrollRemainder.x -= wholeX
        scrollRemainder.y -= wholeY
        guard let event = CGEvent(scrollWheelEvent2Source: source, units: .pixel, wheelCount: 2,
                                  wheel1: Int32(wholeY), wheel2: Int32(wholeX), wheel3: 0) else { return }
        event.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        let scrollPhase: Int64
        switch phase {
        case .none: scrollPhase = 0
        case .began: scrollPhase = Int64(CGScrollPhase.began.rawValue)
        case .changed: scrollPhase = Int64(CGScrollPhase.changed.rawValue)
        case .ended: scrollPhase = Int64(CGScrollPhase.ended.rawValue)
        case .cancelled: scrollPhase = Int64(CGScrollPhase.cancelled.rawValue)
        }
        let momentumPhase: Int64
        switch momentum {
        case .none: momentumPhase = Int64(CGMomentumScrollPhase.none.rawValue)
        case .begin: momentumPhase = Int64(CGMomentumScrollPhase.begin.rawValue)
        case .continue: momentumPhase = Int64(CGMomentumScrollPhase.continuous.rawValue)
        case .end: momentumPhase = Int64(CGMomentumScrollPhase.end.rawValue)
        }
        event.setIntegerValueField(.scrollWheelEventScrollPhase, value: scrollPhase)
        event.setIntegerValueField(.scrollWheelEventMomentumPhase, value: momentumPhase)
        if !flags.isEmpty { event.flags = flags }
        event.post(tap: .cghidEventTap)
        gestures.note(.scroll, phase: phase)
        gestures.note(momentum: momentum)
    }

    private func post(_ type: CGEventType, at point: CGPoint, button: PointerButton, clickState: Int64, pressure: Double? = nil) {
        let mouseButton: CGMouseButton = button == .right ? .right : .left
        guard let event = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: point,
                                  mouseButton: mouseButton) else {
            Log.warn("INPUT CGEvent creation failed for type \(type.rawValue)")
            return
        }
        if clickState > 0 { event.setIntegerValueField(.mouseEventClickState, value: clickState) }
        if let pressure {
            event.setIntegerValueField(.mouseEventSubtype, value: Int64(CGEventMouseSubtype.tabletPoint.rawValue))
            event.setDoubleValueField(.tabletEventPointPressure, value: min(max(pressure, 0), 1))
        }
        if !flags.isEmpty { event.flags = flags }
        event.post(tap: .cghidEventTap)
    }

    // MARK: keyboard

    private var flags: CGEventFlags {
        var flags: CGEventFlags = []
        for usage in heldKeys {
            switch KeyMap.modifier(forUsage: usage) {
            case .control: flags.insert(.maskControl)
            case .shift: flags.insert(.maskShift)
            case .option: flags.insert(.maskAlternate)
            case .command: flags.insert(.maskCommand)
            case nil: break
            }
        }
        if capsLock { flags.insert(.maskAlphaShift) }
        return flags
    }

    private func key(_ usage: UInt16, down: Bool) {
        guard let virtualKey = KeyMap.virtualKey(forUsage: usage) else { return }
        keysSinceLog += 1
        if keysSinceLog == 1 || keysSinceLog % 200 == 0 { Log.info("INPUT keyboard events: \(keysSinceLog)") }
        if usage == KeyMap.capsLockUsage {
            // Toggle on press, like the real key; the release does nothing.
            guard down else { return }
            capsLock.toggle()
            postKey(virtualKey, down: capsLock, usage: usage)
            return
        }
        if down {
            guard heldKeys.insert(usage).inserted else { return } // duplicate down
        } else {
            guard heldKeys.remove(usage) != nil else { return }   // unmatched up
        }
        postKey(virtualKey, down: down, usage: usage)
        guard KeyMap.modifier(forUsage: usage) == nil else { return }
        if down { startRepeat(usage: usage, virtualKey: virtualKey) } else { stopRepeat() }
    }

    private func postKey(_ virtualKey: UInt16, down: Bool, usage: UInt16, autorepeat: Bool = false) {
        guard let event = CGEvent(keyboardEventSource: source, virtualKey: virtualKey, keyDown: down) else { return }
        if KeyMap.modifier(forUsage: usage) != nil || usage == KeyMap.capsLockUsage {
            // macOS global hotkeys and App Switcher release listen for .flagsChanged
            // on modifier transitions rather than .keyDown/.keyUp.
            event.type = .flagsChanged
        }
        var flags = self.flags
        if KeyMap.isFunctionCluster(usage) { flags.insert(.maskSecondaryFn) }
        if KeyMap.isNumericPad(usage) { flags.insert(.maskNumericPad) }
        event.flags = flags
        if autorepeat { event.setIntegerValueField(.keyboardEventAutorepeat, value: 1) }
        event.post(tap: .cghidEventTap)
    }

    /// Repeats the last pressed key at the Mac's repeat delay and rate until it
    /// is released or another key goes down (as a real keyboard does).
    private func startRepeat(usage: UInt16, virtualKey: UInt16) {
        stopRepeat()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        let interval = max(NSEvent.keyRepeatInterval, 0.015)
        timer.schedule(deadline: .now() + max(NSEvent.keyRepeatDelay, 0.1), repeating: interval)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            guard self.heldKeys.contains(usage), self.isEnabled() else { return self.stopRepeat() }
            self.postKey(virtualKey, down: true, usage: usage, autorepeat: true)
        }
        timer.resume()
        repeatTimer = timer
    }

    private func stopRepeat() {
        repeatTimer?.cancel()
        repeatTimer = nil
    }

    /// Lifts every held key, modifiers last, so nothing stays stuck on the Mac.
    private func releaseKeys() {
        stopRepeat()
        guard !heldKeys.isEmpty else { return }
        let ordered = heldKeys.sorted { (KeyMap.modifier(forUsage: $0) == nil ? 0 : 1) < (KeyMap.modifier(forUsage: $1) == nil ? 0 : 1) }
        Log.info("releasing \(ordered.count) held key(s)")
        for usage in ordered {
            heldKeys.remove(usage)
            if let virtualKey = KeyMap.virtualKey(forUsage: usage) { postKey(virtualKey, down: false, usage: usage) }
        }
    }

    private func withinRateLimit() -> Bool {
        let now = Date()
        if now.timeIntervalSince(windowStart) >= 1 {
            windowStart = now
            eventsInWindow = 0
        }
        eventsInWindow += 1
        return eventsInWindow <= Self.maxMovesPerSecond
    }
}
