import AppKit

/// Menu bar glyph: an iPad in landscape with its home bar, matching the app
/// icon (user request). Drawn as a vector template image, so it is crisp at
/// any scale and follows the menu bar's light/dark appearance. While
/// streaming the screen is filled and the home bar is cut out of it.
enum MenuBarGlyph {
    static func image(streaming: Bool) -> NSImage {
        let image = NSImage(size: NSSize(width: 22, height: 16), flipped: false) { _ in
            NSColor.black.set()
            // iPad body: 19 x 13.5 pt, 1.5 pt bezel, rounded like the hardware.
            let body = NSRect(x: 1.5, y: 1.25, width: 19, height: 13.5)
            let outline = NSBezierPath(roundedRect: body.insetBy(dx: 0.75, dy: 0.75), xRadius: 3, yRadius: 3)
            outline.lineWidth = 1.5
            outline.stroke()
            // Home bar: a short pill near the bottom edge of the screen.
            let homeBar = NSRect(x: body.midX - 3, y: body.minY + 2.6, width: 6, height: 1.3)
            let homeBarPath = NSBezierPath(roundedRect: homeBar, xRadius: 0.65, yRadius: 0.65)
            if streaming {
                // Lit screen above the home bar, with a clear gap between them.
                var lit = body.insetBy(dx: 2.75, dy: 2.75)
                let bottom = homeBar.maxY + 1.1
                lit.size.height -= bottom - lit.minY
                lit.origin.y = bottom
                NSBezierPath(roundedRect: lit, xRadius: 1.2, yRadius: 1.2).fill()
            }
            homeBarPath.fill()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = streaming ? "WiredDisplay (streaming)" : "WiredDisplay"
        return image
    }
}
