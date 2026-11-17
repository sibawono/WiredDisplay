import CoreGraphics
import Foundation

/// One-finger touch -> Mac input, modelled on Sidecar's direct touch and on
/// iPad conventions (D-026). Pure state machine, no UIKit, so it can be
/// unit-tested. Gestures with two or more fingers are handled by UIKit gesture
/// recognizers in the iPad app (scroll, right click, pinch, edit gestures);
/// they cancel the raw touch, which ends whatever this interpreter was doing.
///
/// - Tap (lifted before `holdDelay`, within `slop`): left click (move, down,
///   up). Two quick taps become a double click on the Mac, which counts clicks.
/// - Drag (moves beyond `slop` before `holdDelay`): scroll, content follows
///   the finger, with trackpad phases; on lift `fling` holds the release
///   velocity so the app can generate momentum.
/// - Hold (still for `holdDelay`), then move: left-button drag (select text,
///   move windows, drag files); lifting releases the button.
/// - Cancel: ends the scroll or releases the button.
///
/// Positions are normalized to the picture (0...1); `pointScale` converts
/// finger travel in view points into host points for scrolling.
public struct TouchInterpreter: Sendable {
    public enum State: Equatable, Sendable {
        case idle
        case pending(start: CGPoint, startTime: TimeInterval)
        case scrolling(last: CGPoint)
        case dragging
    }

    /// View points a finger may wander before a press becomes a scroll
    /// (UIKit's long-press allowance is 10 pt; 12 tolerated wobble on hardware).
    public var slop: CGFloat = 12
    /// Press-and-hold time before a drag (UIKit's drag-and-drop uses ~0.5 s;
    /// shorter feels closer to selecting text on the iPad).
    public var holdDelay: TimeInterval = 0.35
    public private(set) var state: State = .idle
    /// Release velocity of the last scroll, in host points per second; the
    /// app takes it (and clears it) to run momentum.
    public private(set) var fling: CGPoint?

    private var lastNormalized: CGPoint = .zero
    private var startNormalized: CGPoint = .zero
    private var samples: [Sample] = []
    private var scale: CGFloat = 1

    private struct Sample: Sendable {
        var time: TimeInterval
        var point: CGPoint
    }

    public init() {}

    public mutating func takeFling() -> CGPoint? {
        defer { fling = nil }
        return fling
    }

    /// - Parameters:
    ///   - viewPoint: finger position in view points.
    ///   - normalized: same position normalized to the picture, or nil if the
    ///     touch is outside the picture (letterbox): such touches are ignored.
    public mutating func began(viewPoint: CGPoint, normalized: CGPoint?, time: TimeInterval) -> [InputEvent] {
        guard state == .idle, let normalized else { return [] }
        startNormalized = normalized
        lastNormalized = normalized
        fling = nil
        samples = [Sample(time: time, point: viewPoint)]
        state = .pending(start: viewPoint, startTime: time)
        return []
    }

    public mutating func moved(viewPoint: CGPoint, normalized: CGPoint?, pointScale: CGFloat, time: TimeInterval) -> [InputEvent] {
        scale = pointScale
        switch state {
        case .pending(let start, _):
            guard hypot(viewPoint.x - start.x, viewPoint.y - start.y) > slop else { return [] }
            // Scroll what is under the finger: put the cursor there first.
            state = .scrolling(last: viewPoint)
            record(viewPoint, time)
            var events: [InputEvent] = [
                .pointer(phase: .move, button: .none, x: Float(startNormalized.x), y: Float(startNormalized.y)),
                .gestureScroll(dx: 0, dy: 0, phase: .began, momentum: .none),
            ]
            events += scrollDelta(from: start, to: viewPoint)
            return events
        case .scrolling(let last):
            state = .scrolling(last: viewPoint)
            record(viewPoint, time)
            return scrollDelta(from: last, to: viewPoint)
        case .dragging:
            guard let normalized else { return [] } // finger in the letterbox: hold position
            lastNormalized = normalized
            return [.pointer(phase: .move, button: .left, x: Float(normalized.x), y: Float(normalized.y))]
        case .idle:
            return []
        }
    }

    /// Call when the hold timer fires: the button goes down, ready to drag.
    public mutating func holdElapsed(time: TimeInterval) -> [InputEvent] {
        guard case .pending(_, let startTime) = state, time - startTime >= holdDelay - 0.001 else { return [] }
        state = .dragging
        let x = Float(startNormalized.x), y = Float(startNormalized.y)
        return [.pointer(phase: .move, button: .none, x: x, y: y),
                .pointer(phase: .down, button: .left, x: x, y: y)]
    }

    public mutating func ended(time: TimeInterval) -> [InputEvent] {
        defer { state = .idle }
        switch state {
        case .pending:
            let x = Float(startNormalized.x), y = Float(startNormalized.y)
            return [.pointer(phase: .move, button: .none, x: x, y: y),
                    .pointer(phase: .down, button: .left, x: x, y: y),
                    .pointer(phase: .up, button: .left, x: x, y: y)]
        case .scrolling:
            fling = releaseVelocity(at: time)
            return [.gestureScroll(dx: 0, dy: 0, phase: .ended, momentum: .none)]
        case .dragging:
            return [.pointer(phase: .up, button: .left, x: Float(lastNormalized.x), y: Float(lastNormalized.y))]
        case .idle:
            return []
        }
    }

    /// A gesture recognizer (two or more fingers) took over, or the system
    /// cancelled the touch. A pending tap is dropped, never clicked.
    public mutating func cancelled() -> [InputEvent] {
        defer { state = .idle }
        switch state {
        case .scrolling: return [.gestureScroll(dx: 0, dy: 0, phase: .cancelled, momentum: .none)]
        case .dragging: return [.pointer(phase: .up, button: .left, x: Float(lastNormalized.x), y: Float(lastNormalized.y))]
        case .idle, .pending: return []
        }
    }

    // MARK: helpers

    private func scrollDelta(from: CGPoint, to: CGPoint) -> [InputEvent] {
        let limit = SessionCodec.maxScrollDelta
        let dx = Float((to.x - from.x) * scale), dy = Float((to.y - from.y) * scale)
        guard dx != 0 || dy != 0 else { return [] }
        return [.gestureScroll(dx: min(max(dx, -limit), limit), dy: min(max(dy, -limit), limit),
                               phase: .changed, momentum: .none)]
    }

    private mutating func record(_ point: CGPoint, _ time: TimeInterval) {
        samples.append(Sample(time: time, point: point))
        samples.removeAll { time - $0.time > 0.1 }
    }

    /// Average velocity over the last 100 ms; zero if the finger stopped
    /// before lifting (no momentum after a pause, like UIScrollView).
    private func releaseVelocity(at time: TimeInterval) -> CGPoint {
        guard let first = samples.first, let last = samples.last, time - last.time < 0.05,
              last.time - first.time > 0.005 else { return .zero }
        let dt = last.time - first.time
        return CGPoint(x: (last.point.x - first.point.x) / dt * scale, y: (last.point.y - first.point.y) / dt * scale)
    }
}

/// Three-finger edit gestures (Sidecar): pinch in = copy, pinch in twice =
/// cut, pinch out = paste, swipe left = undo, swipe right = redo. Pure
/// classification so it can be unit-tested; the app feeds start/end spread
/// (mean distance of the fingers from their centroid) and centroid travel.
public enum EditGesture: Equatable, Sendable {
    case copy, cut, paste, undo, redo

    public static func classify(startSpread: CGFloat, endSpread: CGFloat, travel: CGVector,
                                previous: EditGesture?, sincePrevious: TimeInterval) -> EditGesture? {
        guard startSpread > 1 else { return nil }
        let ratio = endSpread / startSpread
        if abs(travel.dx) > 80, abs(travel.dx) > abs(travel.dy) * 1.5, ratio > 0.75, ratio < 1.33 {
            return travel.dx < 0 ? .undo : .redo
        }
        if ratio < 0.7 {
            return previous == .copy && sincePrevious < 1.5 ? .cut : .copy
        }
        if ratio > 1.4 { return .paste }
        return nil
    }

    /// Key sequence (HID usages): Command (+ Shift) + letter.
    public var keys: [InputEvent] {
        let command: UInt16 = 0xE3, shift: UInt16 = 0xE1
        let letter: UInt16
        var modifiers = [command]
        switch self {
        case .copy: letter = 0x06   // C
        case .cut: letter = 0x1B    // X
        case .paste: letter = 0x19  // V
        case .undo: letter = 0x1D   // Z
        case .redo: letter = 0x1D; modifiers.append(shift)
        }
        return modifiers.map { .key(usage: $0, down: true) } + [.key(usage: letter, down: true), .key(usage: letter, down: false)]
            + modifiers.reversed().map { .key(usage: $0, down: false) }
    }
}

/// Turns UIKit's cumulative pinch scale and rotation (radians, clockwise
/// positive) into the incremental magnify / rotate events macOS expects
/// (D-029). Pure, so it can be unit-tested.
public struct TransformTracker: Sendable {
    private var lastScale: CGFloat = 1
    private var lastRotation: CGFloat = 0

    public init() {}

    public mutating func beganPinch() -> InputEvent { lastScale = 1; return .magnify(delta: 0, phase: .began) }
    public mutating func beganRotation() -> InputEvent { lastRotation = 0; return .rotate(degrees: 0, phase: .began) }

    /// `scale`: UIPinchGestureRecognizer.scale (cumulative, 1 at start).
    public mutating func pinch(scale: CGFloat) -> InputEvent? {
        guard scale > 0, scale.isFinite else { return nil }
        let limit = CGFloat(SessionCodec.maxMagnifyDelta)
        let delta = min(max(scale - lastScale, -limit), limit)
        lastScale = scale
        return delta == 0 ? nil : .magnify(delta: Float(delta), phase: .changed)
    }

    /// `rotation`: UIRotationGestureRecognizer.rotation (cumulative radians).
    public mutating func rotation(radians: CGFloat) -> InputEvent? {
        guard radians.isFinite else { return nil }
        let limit = CGFloat(SessionCodec.maxRotateDelta)
        let degrees = min(max(-(radians - lastRotation) * 180 / .pi, -limit), limit)
        lastRotation = radians
        return degrees == 0 ? nil : .rotate(degrees: Float(degrees), phase: .changed)
    }

    public static func endPinch(cancelled: Bool) -> InputEvent { .magnify(delta: 0, phase: cancelled ? .cancelled : .ended) }
    public static func endRotation(cancelled: Bool) -> InputEvent { .rotate(degrees: 0, phase: cancelled ? .cancelled : .ended) }
}

/// Pinch zoom as Command-plus / Command-minus steps: the host's fallback when
/// it cannot create a magnify gesture event (no public API for those, D-029). One step per `stepRatio` of finger spread.
public struct PinchZoomStepper: Sendable {
    public var stepRatio: CGFloat = 1.3
    private var anchor: CGFloat = 1

    public init() {}

    public mutating func begin() { anchor = 1 }

    /// `scale`: UIPinchGestureRecognizer's cumulative scale. Returns the keys
    /// for each step crossed since the last call.
    public mutating func update(scale: CGFloat) -> [InputEvent] {
        guard scale > 0, scale.isFinite else { return [] }
        var events: [InputEvent] = []
        while scale / anchor >= stepRatio {
            anchor *= stepRatio
            events += Self.step(zoomIn: true)
        }
        while anchor / scale >= stepRatio {
            anchor /= stepRatio
            events += Self.step(zoomIn: false)
        }
        return events
    }

    static func step(zoomIn: Bool) -> [InputEvent] {
        let command: UInt16 = 0xE3, key: UInt16 = zoomIn ? 0x2E : 0x2D // "=" / "-"
        return [.key(usage: command, down: true), .key(usage: key, down: true),
                .key(usage: key, down: false), .key(usage: command, down: false)]
    }
}
