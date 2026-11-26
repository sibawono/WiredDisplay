import AppKit
import os
import CoreGraphics
import WDSession

/// Local cursor (D-038, after OpenDisplay): the cursor is left out of the
/// video and the iPad draws it from a position stream (~1 ms behind) instead
/// of waiting for the encoder (~16 ms). Position is sampled at 120 Hz on its
/// own queue; the cursor image is checked at 30 Hz on the main thread
/// (NSCursor is AppKit) and sent only when it changes.
final class CursorEcho: @unchecked Sendable {
    private let queue = DispatchQueue(label: "wireddisplay.cursor", qos: .userInteractive)
    private let send: @Sendable (ControlMessage) -> Void
    private let displayID: CGDirectDisplayID
    private var positionTimer: DispatchSourceTimer?
    private var imageTimer: DispatchSourceTimer?
    private var last: (x: Float, y: Float, visible: Bool) = (-1, -1, false)
    private var lastImageKey = 0
    /// Set by the position poll: the image is only checked while the pointer
    /// is on this display (audit B-8: it was TIFF-encoded 30 times a second
    /// on the main thread whatever the pointer did).
    private let onDisplay = OSAllocatedUnfairLock(initialState: false)

    init(displayID: CGDirectDisplayID, send: @escaping @Sendable (ControlMessage) -> Void) {
        self.displayID = displayID
        self.send = send
    }

    func start() {
        let position = DispatchSource.makeTimerSource(queue: queue)
        position.schedule(deadline: .now(), repeating: .milliseconds(8), leeway: .milliseconds(1))
        position.setEventHandler { [weak self] in self?.pollPosition() }
        position.resume()
        positionTimer = position
        let image = DispatchSource.makeTimerSource(queue: .main)
        image.schedule(deadline: .now(), repeating: .milliseconds(33))
        image.setEventHandler { [weak self] in self?.pollImage() }
        image.resume()
        imageTimer = image
    }

    func stop() {
        positionTimer?.cancel()
        imageTimer?.cancel()
        positionTimer = nil
        imageTimer = nil
    }

    deinit { stop() }

    private func pollPosition() {
        guard let location = CGEvent(source: nil)?.location else { return }
        let bounds = CGDisplayBounds(displayID)
        guard bounds.width > 0, bounds.height > 0 else { return }
        let inside = bounds.contains(location)
        let arrived = onDisplay.withLock { was in defer { was = inside }; return inside && !was }
        if arrived { DispatchQueue.main.async { [weak self] in self?.pollImage() } } // new shape at once
        let visible = inside && Self.cursorShown()
        if visible {
            let x = Float((location.x - bounds.minX) / bounds.width)
            let y = Float((location.y - bounds.minY) / bounds.height)
            guard !last.visible || abs(x - last.x) > 0.0002 || abs(y - last.y) > 0.0002 else { return }
            last = (x, y, true)
            send(.cursor(x: min(max(x, 0), 1), y: min(max(y, 0), 1), visible: true))
        } else if last.visible {
            last.visible = false
            send(.cursor(x: 0, y: 0, visible: false))
        }
    }

    /// Hidden while typing (macOS hides the pointer) and by apps that hide it.
    private static func cursorShown() -> Bool {
        typealias Fn = @convention(c) () -> Int32
        struct Lookup { static let fn: Fn? = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGCursorIsVisible")
            .map { unsafeBitCast($0, to: Fn.self) } }
        return Lookup.fn.map { $0() != 0 } ?? true
    }

    private func pollImage() {
        guard onDisplay.withLock({ $0 }), let cursor = NSCursor.currentSystem else { return }
        let display = CGDisplayBounds(displayID).size // points, current mode
        guard display.width > 0, display.height > 0 else { return }
        let image = cursor.image
        // Key from the bitmap's bytes (cheap) rather than a TIFF encoding;
        // the PNG is only made when the shape actually changed.
        var proposed = CGRect(origin: .zero, size: image.size)
        guard let bitmap = image.cgImage(forProposedRect: &proposed, context: nil, hints: nil),
              let bytes = bitmap.dataProvider?.data as Data? else { return }
        var hasher = Hasher()
        hasher.combine(bytes)
        hasher.combine(bitmap.width)
        hasher.combine(cursor.hotSpot.x)
        hasher.combine(cursor.hotSpot.y)
        hasher.combine(Int(display.width))
        let key = hasher.finalize()
        guard key != lastImageKey else { return }
        guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]),
              png.count <= CursorImage.maxPNGBytes else { return }
        lastImageKey = key
        let size = image.size
        let hot = cursor.hotSpot // top-left origin in image points
        send(.cursorImage(CursorImage(png: [UInt8](png),
                                      width: Float(size.width / display.width),
                                      height: Float(size.height / display.height),
                                      hotX: size.width > 0 ? Float(hot.x / size.width) : 0,
                                      hotY: size.height > 0 ? Float(hot.y / size.height) : 0)))
    }
}
