import CVirtualDisplay
import CoreGraphics
import Foundation
import WDHostCore
import WDSession

/// Owns the virtual display for one session. It never changes the main display
/// or mirroring (D-015); on a headless Mac it is the only display, so macOS
/// makes it the main display by itself.
final class VirtualDisplayController {
    enum Error: Swift.Error, CustomStringConvertible {
        case unavailable(String)
        case createFailed(String)
        case notOnline(CGDirectDisplayID)

        var description: String {
            switch self {
            case .unavailable(let reason): return "virtual display API unavailable: \(reason)"
            case .createFailed(let reason): return "virtual display creation failed: \(reason)"
            case .notOnline(let id): return "virtual display \(id) did not come online"
            }
        }
    }

    private var handle: WDVirtualDisplayHandle?

    var displayID: CGDirectDisplayID? { handle.map(\.displayID) }

    typealias Space = DisplaySpace

    static func modeSizes(panelWidth: UInt32, panelHeight: UInt32, hiDPI: Bool) -> [Space: CGSize] {
        DisplaySpace.modeSizes(panelWidth: panelWidth, panelHeight: panelHeight, hiDPI: hiDPI)
    }

    /// Creates a display matching the client's panel. Pixel dimensions are
    /// rounded down to even values (required for @2x modes). `space` picks the
    /// default mode; the others stay selectable in System Settings.
    func create(for hello: Hello, refreshHz: Double, wideColor: Bool, space: Space = .native,
                serialNumber: UInt32 = 1) throws -> StreamConfig {
        if let error = WDVirtualDisplayCheckAvailability() { throw Error.unavailable(error.localizedDescription) }
        let width = UInt32(min(hello.pixelWidth, 8192)) & ~1
        let height = UInt32(min(hello.pixelHeight, 8192)) & ~1
        let hiDPI = hello.scale >= 2
        let config = WDVirtualDisplayConfig()
        config.name = "WiredDisplay (\(hello.deviceName.isEmpty ? "iPad" : hello.deviceName))"
        config.pixelsWide = width
        config.pixelsHigh = height
        // Physical size from the iPad's pixel density (264 ppi for Air/Pro/iPad,
        // 326 for mini; older clients send 0) so macOS picks sane UI scaling.
        let ppi = Double(hello.pixelsPerInch == 0 ? 264 : hello.pixelsPerInch)
        config.sizeInMillimeters = CGSize(width: Double(width) / ppi * 25.4, height: Double(height) / ppi * 25.4)
        config.hiDPI = hiDPI
        config.refreshRate = refreshHz
        config.wideColor = wideColor // only with --color p3 (BUG-033)
        config.serialNumber = serialNumber
        let sizes = Self.modeSizes(panelWidth: width, panelHeight: height, hiDPI: hiDPI)
        let ordered = [space] + Space.allCases.filter { $0 != space }
        config.modeSizes = ordered.compactMap { sizes[$0] }.map { NSValue(size: $0) }

        let created: WDVirtualDisplayHandle
        do {
            created = try WDVirtualDisplayHandle.create(with: config)
        } catch {
            throw Error.createFailed(error.localizedDescription)
        }
        handle = created
        guard waitUntilOnline(created.displayID, timeout: 3) else {
            destroy()
            throw Error.notOnline(created.displayID)
        }
        // Points from the mode we requested, not from CGDisplayBounds, which can
        // still report the pixel size before the HiDPI mode applies (finding C).
        let points = sizes[space] ?? CGSize(width: Double(width / 2), height: Double(height / 2))
        let bounds = CGDisplayBounds(created.displayID)
        Log.info("virtual display \(created.displayID) online: \(width)x\(height) px panel, default mode \(space) " +
                 "\(Int(points.width))x\(Int(points.height)) pt, modes \(ordered.compactMap { sizes[$0] }.map { "\(Int($0.width))x\(Int($0.height))" }), " +
                 "bounds now \(bounds), hiDPI \(hiDPI), " +
                 "Display P3 \(wideColor ? (created.appliedWideColor ? "applied" : "NOT available") : "off (sRGB)")")
        if Int(bounds.width.rounded()) != Int(points.width) {
            // Normal when macOS restores a mode the user picked earlier.
            Log.info("display bounds \(bounds.size) differ from the default \(points) pt mode (a remembered choice?)")
        }
        return StreamConfig(pixelWidth: width, pixelHeight: height, pointWidth: UInt32(points.width),
                            pointHeight: UInt32(points.height), refreshHz: UInt16(refreshHz), codec: .h264)
    }

    /// Only ever called with WiredDisplay's own virtual display. It may be the
    /// main display when it is the Mac's only screen (D-043); a mirrored one is not changed.
    static func canChangeSpace(on displayID: CGDirectDisplayID) -> Bool {
        CGDisplayIsOnline(displayID) != 0 && CGDisplayIsInMirrorSet(displayID) == 0
    }

    func setSpace(_ space: Space, config: StreamConfig, hiDPI: Bool) -> Bool {
        guard let displayID, Self.canChangeSpace(on: displayID),
              let size = Self.modeSizes(panelWidth: config.pixelWidth, panelHeight: config.pixelHeight,
                                        hiDPI: hiDPI)[space],
              let current = CGDisplayCopyDisplayMode(displayID),
              let modes = CGDisplayCopyAllDisplayModes(displayID,
                    [kCGDisplayShowDuplicateLowResolutionModes: true] as CFDictionary) as? [CGDisplayMode] else {
            return false
        }
        let width = Int(size.width), height = Int(size.height), scale = hiDPI ? 2 : 1
        guard let mode = modes.first(where: {
            $0.width == width && $0.height == height &&
                $0.pixelWidth == width * scale && $0.pixelHeight == height * scale &&
                abs($0.refreshRate - current.refreshRate) < 0.1
        }) else { return false }
        if mode.ioDisplayModeID == current.ioDisplayModeID { return true }

        var change: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&change) == .success, let change else { return false }
        guard CGConfigureDisplayWithDisplayMode(change, displayID, mode, nil) == .success,
              Self.canChangeSpace(on: displayID) else {
            CGCancelDisplayConfiguration(change)
            return false
        }
        return CGCompleteDisplayConfiguration(change, .forSession) == .success
    }

    func destroy() {
        guard let handle else { return }
        let id = handle.displayID
        handle.invalidate()
        self.handle = nil
        Log.info("virtual display \(id) released")
    }

    private func waitUntilOnline(_ id: CGDirectDisplayID, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            var count: UInt32 = 0
            var ids = [CGDirectDisplayID](repeating: 0, count: 32)
            if CGGetOnlineDisplayList(32, &ids, &count) == .success, ids.prefix(Int(count)).contains(id) { return true }
            Thread.sleep(forTimeInterval: 0.1)
        } while Date() < deadline
        return false
    }
}
