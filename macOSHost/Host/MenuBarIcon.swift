import AppKit

/// Menu bar glyph: a screen with a USB-C plug underneath. Drawn as a vector
/// template image, so it is crisp at any scale and follows the menu bar's
/// light/dark appearance. While streaming the screen is filled.
enum MenuBarGlyph {
    static func image(streaming: Bool) -> NSImage {
        let image = NSImage(size: NSSize(width: 22, height: 16), flipped: false) { _ in
            NSColor.black.set()
            // Screen (top): 18 x 10 pt, 1.5 pt outline.
            let screen = NSRect(x: 2, y: 6, width: 18, height: 10)
            let outline = NSBezierPath(roundedRect: screen.insetBy(dx: 0.75, dy: 0.75), xRadius: 2, yRadius: 2)
            outline.lineWidth = 1.5
            outline.stroke()
            if streaming {
                NSBezierPath(roundedRect: screen.insetBy(dx: 3, dy: 3), xRadius: 0.75, yRadius: 0.75).fill()
            }
            // USB-C plug under the screen: thin metal tip, a gap, rounded body, cable.
            NSBezierPath(roundedRect: NSRect(x: 9.6, y: 4.5, width: 2.8, height: 1.5), xRadius: 0.5, yRadius: 0.5).fill()
            NSBezierPath(roundedRect: NSRect(x: 8.9, y: 1.6, width: 4.2, height: 2.5), xRadius: 1.1, yRadius: 1.1).fill()
            NSBezierPath(rect: NSRect(x: 10.45, y: 0, width: 1.1, height: 1.8)).fill()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = streaming ? "WiredDisplay (streaming)" : "WiredDisplay"
        return image
    }
}
