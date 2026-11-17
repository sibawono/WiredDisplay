// Renders the WiredDisplay icons: an iPad in the style of the Sidecar icon.
//
// usage: swift scripts/make-icons.swift <output-dir>
// writes: AppIcon-iPad-1024.png (full bleed, Continuity style; iPadOS applies the mask),
//         AppIcon.iconset/ (the same artwork in the macOS squircle, for iconutil),
//         MenuBar-preview.png (the menu bar glyph at 8x, both states).
import AppKit

let out = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ".")
try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

/// Draws the artwork into a 1024x1024 coordinate space (origin bottom-left).
/// `squircle`: macOS style (inset rounded square with shadow) vs full bleed.
func drawIcon(squircle: Bool) {
    let canvas = NSRect(x: 0, y: 0, width: 1024, height: 1024)
    let tile = squircle ? canvas.insetBy(dx: 100, dy: 100) : canvas
    let tilePath = squircle ? NSBezierPath(roundedRect: tile, xRadius: 185, yRadius: 185) : NSBezierPath(rect: tile)
    if squircle {
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
        shadow.shadowBlurRadius = 28
        shadow.shadowOffset = NSSize(width: 0, height: -12)
        shadow.set()
        color(0x0E1F5C).setFill()
        tilePath.fill()
        NSGraphicsContext.restoreGraphicsState()
    }
    NSGraphicsContext.saveGraphicsState()
    tilePath.addClip()
    NSGradient(starting: color(0x3B6CF0), ending: color(0x0B1A4E))!.draw(in: tile, angle: -90)

    // Everything below scales with the tile so both variants share proportions.
    let s = tile.width / 1024
    func r(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> NSRect {
        NSRect(x: tile.minX + x * s, y: tile.minY + y * s, width: w * s, height: h * s)
    }

    // Soft glow behind the screen.
    NSGradient(starting: color(0x7FB2FF, 0.45), ending: color(0x7FB2FF, 0))!
        .draw(in: NSBezierPath(ovalIn: r(130, 300, 764, 600)), relativeCenterPosition: .zero)

    // Screen: white bezel, content gradient inside.
    let bezel = r(196, 420, 632, 430)
    let bezelPath = NSBezierPath(roundedRect: bezel, xRadius: 54 * s, yRadius: 54 * s)
    NSColor.white.setFill()
    bezelPath.fill()
    let content = bezel.insetBy(dx: 26 * s, dy: 26 * s)
    let contentPath = NSBezierPath(roundedRect: content, xRadius: 32 * s, yRadius: 32 * s)
    NSGraphicsContext.saveGraphicsState()
    contentPath.addClip()
    NSGradient(colors: [color(0x9FD4FF), color(0x4F86F7), color(0x2448B8)])!.draw(in: content, angle: -60)
    // A highlight band, suggesting a lit display.
    let band = NSBezierPath()
    band.move(to: NSPoint(x: content.minX, y: content.maxY - 120 * s))
    band.line(to: NSPoint(x: content.minX + 230 * s, y: content.maxY))
    band.line(to: NSPoint(x: content.minX + 340 * s, y: content.maxY))
    band.line(to: NSPoint(x: content.minX, y: content.maxY - 190 * s))
    band.close()
    NSColor.white.withAlphaComponent(0.18).setFill()
    band.fill()
    NSGraphicsContext.restoreGraphicsState()

    // USB-C plug entering the screen from below: metal tip, body, cable.
    let tip = r(462, 360, 100, 66)
    color(0xC9D3E6).setFill()
    NSBezierPath(roundedRect: tip, xRadius: 20 * s, yRadius: 20 * s).fill()
    color(0x8E9BB5).setFill()
    NSBezierPath(roundedRect: r(482, 382, 60, 16), xRadius: 8 * s, yRadius: 8 * s).fill() // the port slot
    let body = r(440, 196, 144, 176)
    NSColor.white.setFill()
    NSBezierPath(roundedRect: body, xRadius: 40 * s, yRadius: 40 * s).fill()
    color(0xD7DEEC).setFill()
    NSBezierPath(roundedRect: r(472, 228, 80, 14), xRadius: 7 * s, yRadius: 7 * s).fill()   // grip lines
    NSBezierPath(roundedRect: r(472, 256, 80, 14), xRadius: 7 * s, yRadius: 7 * s).fill()
    NSColor.white.setFill()
    NSBezierPath(roundedRect: r(490, -40, 44, 250), xRadius: 22 * s, yRadius: 22 * s).fill() // cable
    NSGraphicsContext.restoreGraphicsState()
}

/// iPad icon, in the style of Apple's Sidecar icon: white line art on a
/// vivid blue gradient, no bevels or glow. Just an iPad in landscape,
/// centred; no plug or cable (user request).
func drawContinuityIcon() {
    let tile = NSRect(x: 0, y: 0, width: 1024, height: 1024)
    NSGradient(colors: [color(0x5AB8FF), color(0x1F7BFF), color(0x0A52E0)],
               atLocations: [0, 0.55, 1], colorSpace: .sRGB)!.draw(in: tile, angle: -90)
    let white = NSColor.white
    let stroke: CGFloat = 46

    // iPad, landscape: thick rounded outline (the bezel), translucent screen.
    let device = NSRect(x: 512 - 330, y: 512 - 236, width: 660, height: 472)
    let outline = NSBezierPath(roundedRect: device.insetBy(dx: stroke / 2, dy: stroke / 2), xRadius: 72, yRadius: 72)
    outline.lineWidth = stroke
    white.setStroke()
    outline.stroke()
    let screen = device.insetBy(dx: stroke + 26, dy: stroke + 26)
    white.withAlphaComponent(0.22).setFill()
    NSBezierPath(roundedRect: screen, xRadius: 26, yRadius: 26).fill()
    // A soft diagonal sheen on the screen, like a lit display.
    NSGraphicsContext.saveGraphicsState()
    NSBezierPath(roundedRect: screen, xRadius: 26, yRadius: 26).addClip()
    let sheen = NSBezierPath()
    sheen.move(to: NSPoint(x: screen.minX, y: screen.minY + 70))
    sheen.line(to: NSPoint(x: screen.minX + 280, y: screen.maxY))
    sheen.line(to: NSPoint(x: screen.minX + 400, y: screen.maxY))
    sheen.line(to: NSPoint(x: screen.minX, y: screen.minY - 30))
    sheen.close()
    white.withAlphaComponent(0.14).setFill()
    sheen.fill()
    NSGraphicsContext.restoreGraphicsState()
    // Front camera dot on the long (top) edge, as on iPad Air in landscape.
    let camera = NSRect(x: device.midX - 10, y: device.maxY - stroke / 2 - 10, width: 20, height: 20)
    color(0x2A86FF).setFill()
    NSBezierPath(ovalIn: camera).fill()

}

/// macOS icon: the same Continuity artwork as the iPad icon, inside the
/// macOS squircle (inset tile with a soft drop shadow), so the Mac app, the
/// iPad home screen and the iPad splash screen all show one icon.
func drawMacContinuityIcon() {
    let tile = NSRect(x: 100, y: 100, width: 824, height: 824)
    let shape = NSBezierPath(roundedRect: tile, xRadius: 185, yRadius: 185)
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.3)
    shadow.shadowBlurRadius = 28
    shadow.shadowOffset = NSSize(width: 0, height: -12)
    shadow.set()
    color(0x1F7BFF).setFill()
    shape.fill()
    NSGraphicsContext.restoreGraphicsState()
    NSGraphicsContext.saveGraphicsState()
    shape.addClip()
    let transform = NSAffineTransform()
    transform.translateX(by: tile.minX, yBy: tile.minY)
    transform.scale(by: tile.width / 1024)
    transform.concat()
    drawContinuityIcon()
    NSGraphicsContext.restoreGraphicsState()
}

func png(size: Int, scale: CGFloat = 1, draw: () -> Void) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGraphicsContext.current?.imageInterpolation = .high
    let transform = NSAffineTransform()
    transform.scale(by: CGFloat(size) / 1024 * scale)
    transform.concat()
    draw()
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

// iPad: full bleed, opaque (App Store rule: no alpha). Flattened through a
// CGContext without alpha; a 3-channel NSBitmapImageRep context renders black.
let iPadRep = NSBitmapImageRep(data: png(size: 1024) { drawContinuityIcon() })!
let flat = CGContext(data: nil, width: 1024, height: 1024, bitsPerComponent: 8, bytesPerRow: 0,
                     space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
flat.draw(iPadRep.cgImage!, in: CGRect(x: 0, y: 0, width: 1024, height: 1024))
let flatImage = flat.makeImage()!
// Guard against an all-black result: sample the centre of the screen artwork.
let probe = NSBitmapImageRep(cgImage: flatImage).colorAt(x: 180, y: 512)!
guard probe.brightnessComponent > 0.3 else { fatalError("iPad icon rendered dark (\(probe)); refusing to write it") }
let iPadURL = out.appendingPathComponent("AppIcon-iPad-1024.png") as CFURL
let destination = CGImageDestinationCreateWithURL(iPadURL, "public.png" as CFString, 1, nil)!
CGImageDestinationAddImage(destination, flatImage, nil)
guard CGImageDestinationFinalize(destination) else { fatalError("could not write the iPad icon") }

// macOS iconset.
let iconset = out.appendingPathComponent("AppIcon.iconset")
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
        try png(size: base * scale) { drawMacContinuityIcon() }.write(to: iconset.appendingPathComponent(name))
    }
}

// Menu bar glyph preview (the host draws the same shapes at runtime: MenuBarIcon.swift).
let preview = png(size: 1024) {
    NSColor(white: 0.93, alpha: 1).setFill(); NSRect(x: 0, y: 0, width: 1024, height: 1024).fill()
    for (index, streaming) in [false, true].enumerated() {
        let image = MenuBarGlyph.image(streaming: streaming)
        image.draw(in: NSRect(x: 112 + CGFloat(index) * 440, y: 330, width: 22 * 16, height: 16 * 16))
    }
}
try preview.write(to: out.appendingPathComponent("MenuBar-preview.png"))
print("icons written to \(out.path)")
