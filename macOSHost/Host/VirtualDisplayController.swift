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

    private func makeConfig(for hello: Hello, refreshHz: Double, wideColor: Bool, space: Space,
                            serialNumber: UInt32) -> (config: WDVirtualDisplayConfig, width: UInt32, height: UInt32, hiDPI: Bool, sizes: [Space: CGSize], ordered: [Space]) {
        let width = UInt32(min(hello.pixelWidth, 8192)) & ~1
        let height = UInt32(min(hello.pixelHeight, 8192)) & ~1
        let hiDPI = hello.scale >= 2
        let config = WDVirtualDisplayConfig()
        config.name = "WiredDisplay (\(hello.deviceName.isEmpty ? "iPad" : hello.deviceName))"
        config.pixelsWide = width
        config.pixelsHigh = height
        config.sizeInMillimeters = DisplaySpace.safePhysicalSizeMillimeters(
            pixelWidth: width, pixelHeight: height, pixelsPerInch: hello.pixelsPerInch, hiDPI: hiDPI
        )
        config.hiDPI = hiDPI
        config.refreshRate = refreshHz
        config.wideColor = wideColor // only with --color p3 (BUG-033)
        config.serialNumber = serialNumber
        let sizes = Self.modeSizes(panelWidth: width, panelHeight: height, hiDPI: hiDPI)
        let ordered = [space] + Space.allCases.filter { $0 != space }
        config.modeSizes = ordered.compactMap { sizes[$0] }.map { NSValue(size: $0) }
        return (config, width, height, hiDPI, sizes, ordered)
    }

    /// Creates a display matching the client's panel. Pixel dimensions are
    /// rounded down to even values (required for @2x modes). `space` picks the
    /// default mode; the others stay selectable in System Settings.
    func create(for hello: Hello, refreshHz: Double, wideColor: Bool, space: Space = .native,
                serialNumber: UInt32 = 1) throws -> StreamConfig {
        if let error = WDVirtualDisplayCheckAvailability() { throw Error.unavailable(error.localizedDescription) }

        // Retry with serial offsets if macOS poisoned the previous display identity
        // (e.g. after "Stop Extending" in system UI).
        let serialOffsets: [UInt32] = [0, 100, 200]
        var lastError: Swift.Error?
        for offset in serialOffsets {
            let candidateSerial = serialNumber &+ offset
            let built = makeConfig(for: hello, refreshHz: refreshHz, wideColor: wideColor, space: space,
                                   serialNumber: candidateSerial)
            let created: WDVirtualDisplayHandle
            do {
                created = try WDVirtualDisplayHandle.create(with: built.config)
            } catch {
                lastError = Error.createFailed(error.localizedDescription)
                continue
            }
            handle = created
            if waitUntilOnline(created.displayID, timeout: 3) {
                if offset != 0 {
                    Log.warn("virtual display came online with fallback serial \(candidateSerial) (offset +\(offset))")
                }
                let points = built.sizes[space] ?? CGSize(width: Double(built.width / 2), height: Double(built.height / 2))
                let bounds = CGDisplayBounds(created.displayID)
                Log.info("virtual display \(created.displayID) online: \(built.width)x\(built.height) px panel, default mode \(space) " +
                         "\(Int(points.width))x\(Int(points.height)) pt, modes \(built.ordered.compactMap { built.sizes[$0] }.map { "\(Int($0.width))x\(Int($0.height))" }), " +
                         "bounds now \(bounds), hiDPI \(built.hiDPI), " +
                         "Display P3 \(wideColor ? (created.appliedWideColor ? "applied" : "NOT available") : "off (sRGB)")")
                if Int(bounds.width.rounded()) != Int(points.width) {
                    Log.info("display bounds \(bounds.size) differ from the default \(points) pt mode (a remembered choice?)")
                }
                return StreamConfig(pixelWidth: built.width, pixelHeight: built.height, pointWidth: UInt32(points.width),
                                    pointHeight: UInt32(points.height), refreshHz: UInt16(refreshHz), codec: .h264)
            }
            let failedID = created.displayID
            destroy()
            lastError = Error.notOnline(failedID)
            Log.warn("virtual display \(failedID) (serial \(candidateSerial)) did not come online; retrying next serial offset")
        }
        throw lastError ?? Error.createFailed("unknown virtual display failure")
    }

    /// Updates modes in place (preserving window placement across rotation).
    /// Returns nil if the handle is absent or macOS rejects the mode change.
    func resizeInPlace(for hello: Hello, refreshHz: Double, wideColor: Bool, space: Space = .native,
                       serialNumber: UInt32 = 1) -> StreamConfig? {
        guard let handle else { return nil }
        let built = makeConfig(for: hello, refreshHz: refreshHz, wideColor: wideColor, space: space,
                               serialNumber: serialNumber)
        do {
            try handle.apply(built.config)
        } catch {
            Log.warn("in-place virtual display resize failed (\(error)); caller will rebuild")
            return nil
        }
        let points = built.sizes[space] ?? CGSize(width: Double(built.width / 2), height: Double(built.height / 2))
        Log.info("virtual display \(handle.displayID) resized in place to \(built.width)x\(built.height) px (\(Int(points.width))x\(Int(points.height)) pt)")
        return StreamConfig(pixelWidth: built.width, pixelHeight: built.height, pointWidth: UInt32(points.width),
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
