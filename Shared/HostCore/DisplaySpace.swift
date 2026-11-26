import CoreGraphics

/// "Looks like" sizes offered for the virtual display: `native` is the panel at @2x; `more` and
/// `most` scale the UI down. The panel is always streamed at its native pixels.
public enum DisplaySpace: String, CaseIterable, Sendable {
    case native, more, most

    public var title: String {
        switch self {
        case .native: return "Default"
        case .more: return "More Space"
        case .most: return "Most Space"
        }
    }

    public var factor: Double {
        switch self {
        case .native: return 1
        case .more: return 1.125
        case .most: return 1.25
        }
    }

    /// Point sizes for every space: even sides, the panel's aspect.
    public static func modeSizes(panelWidth: UInt32, panelHeight: UInt32, hiDPI: Bool) -> [DisplaySpace: CGSize] {
        let divisor = hiDPI ? 2.0 : 1.0
        var sizes: [DisplaySpace: CGSize] = [:]
        for space in allCases {
            let width = (Double(panelWidth) / divisor * space.factor / 2).rounded() * 2
            let height = (width * Double(panelHeight) / Double(panelWidth) / 2).rounded() * 2
            sizes[space] = CGSize(width: width, height: height)
        }
        return sizes
    }

    /// The space whose size is exactly these points, if any (a size the user set by hand is none).
    public static func matching(points: CGSize, panelWidth: UInt32, panelHeight: UInt32, hiDPI: Bool) -> DisplaySpace? {
        let sizes = modeSizes(panelWidth: panelWidth, panelHeight: panelHeight, hiDPI: hiDPI)
        return allCases.first { sizes[$0] == points }
    }

    /// Physical display dimensions in millimeters that macOS 26.1/27 will bring online at HiDPI.
    /// macOS 26.1 refuses virtual displays under ~160 cm^2 with >2000 px descriptors, and
    /// macOS 27 falls back to 1x when width < 166 mm (common in portrait).
    public static func safePhysicalSizeMillimeters(pixelWidth: UInt32, pixelHeight: UInt32,
                                                   pixelsPerInch: UInt16, hiDPI: Bool) -> CGSize {
        let w = Double(max(pixelWidth, 1))
        let h = Double(max(pixelHeight, 1))
        let ppi = Double(pixelsPerInch == 0 ? 264 : pixelsPerInch)
        var mmW = w / ppi * 25.4
        var mmH = h / ppi * 25.4

        guard hiDPI else { return CGSize(width: mmW, height: mmH) }

        let minWidthMm = 175.0
        let minAreaMm2 = 16_500.0
        if mmW < minWidthMm {
            let scale = minWidthMm / mmW
            mmW *= scale
            mmH *= scale
        }
        let area = mmW * mmH
        if area < minAreaMm2 {
            let scale = (minAreaMm2 / area).squareRoot()
            mmW *= scale
            mmH *= scale
        }
        return CGSize(width: mmW, height: mmH)
    }
}

/// What ScreenCaptureKit should deliver.
public enum CaptureSizing {
    /// The display's full HiDPI framebuffer when it is larger than the panel with the same aspect,
    /// so the encoder's area filter does the downscale; otherwise the panel size.
    public static func size(panel: CGSize, framebuffer: CGSize?, ownDownscale: Bool, wantsBGRA: Bool) -> CGSize {
        guard ownDownscale, wantsBGRA, let source = framebuffer,
              source.width > panel.width, source.height > panel.height,
              source.width <= 8192, source.height <= 8192,
              abs(source.width / source.height - panel.width / panel.height) < 0.005 else { return panel }
        return source
    }
}
