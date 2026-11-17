import CVirtualDisplay
import CoreGraphics
import Foundation

// Phase 0 experiment E-03: does CGVirtualDisplay register a usable HiDPI display
// on this OS, and does WindowServer leave the existing arrangement alone?
//
//   wd-vdisplay-probe check
//       No side effects. Verifies the private API surface and ABI.
//   wd-vdisplay-probe create --confirm [--seconds N] [--width W --height H] [--no-hidpi]
//       Creates a virtual display, reports the display list before/during/after,
//       then removes it. Never changes the main display or mirroring itself.
//       If the main display or any pre-existing display changes while it is up,
//       it removes the display immediately and exits non-zero.

struct DisplayInfo: Equatable {
    var id: CGDirectDisplayID
    var isMain: Bool
    var mirrorsID: CGDirectDisplayID
    var bounds: CGRect
    var pixels: CGSize
    var modePixels: CGSize
}

func snapshot() -> [DisplayInfo] {
    var count: UInt32 = 0
    var ids = [CGDirectDisplayID](repeating: 0, count: 32)
    guard CGGetOnlineDisplayList(UInt32(ids.count), &ids, &count) == .success else { return [] }
    return ids.prefix(Int(count)).map { id in
        let mode = CGDisplayCopyDisplayMode(id)
        return DisplayInfo(id: id, isMain: CGDisplayIsMain(id) != 0, mirrorsID: CGDisplayMirrorsDisplay(id),
                           bounds: CGDisplayBounds(id),
                           pixels: CGSize(width: CGDisplayPixelsWide(id), height: CGDisplayPixelsHigh(id)),
                           modePixels: CGSize(width: mode?.pixelWidth ?? 0, height: mode?.pixelHeight ?? 0))
    }.sorted { $0.id < $1.id }
}

func describe(_ label: String, _ displays: [DisplayInfo]) {
    print("[\(label)] \(displays.count) online display(s)")
    for d in displays {
        let scale = d.bounds.width > 0 ? d.modePixels.width / d.bounds.width : 0
        print("  id=\(d.id) main=\(d.isMain) mirrors=\(d.mirrorsID) bounds=\(d.bounds) "
            + "modePixels=\(Int(d.modePixels.width))x\(Int(d.modePixels.height)) backingScale=\(scale)")
    }
}

func fail(_ message: String, code: Int32 = 1) -> Never {
    FileHandle.standardError.write(Data(("error: " + message + "\n").utf8))
    exit(code)
}

let commandLine = Array(CommandLine.arguments.dropFirst())
guard let command = commandLine.first else { fail("usage: wd-vdisplay-probe check | create --confirm [...]", code: 64) }
let arguments = Array(commandLine.dropFirst())

@MainActor
func value(_ flag: String) -> String? {
    guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return nil }
    return arguments[index + 1]
}

if let error = WDVirtualDisplayCheckAvailability() {
    fail("CGVirtualDisplay unavailable, failing closed: \(error.localizedDescription)", code: 2)
}
print("CGVirtualDisplay private surface present with expected ABI")

switch command {
case "check":
    describe("current", snapshot())
case "create":
    guard arguments.contains("--confirm") else {
        fail("create adds a display to the live WindowServer session; pass --confirm to proceed", code: 64)
    }
    let seconds = min(max(Int(value("--seconds") ?? "8") ?? 8, 2), 60)
    let config = WDVirtualDisplayConfig()
    config.name = "WiredDisplay Probe"
    // iPad Air 13-inch (M2) panel: 2732 x 2048 px, 264 ppi => 262.9 x 197.1 mm.
    config.pixelsWide = UInt32(value("--width") ?? "2732") ?? 2732
    config.pixelsHigh = UInt32(value("--height") ?? "2048") ?? 2048
    config.sizeInMillimeters = CGSize(width: 262.9, height: 197.1)
    config.hiDPI = !arguments.contains("--no-hidpi")
    config.refreshRate = 60

    let before = snapshot()
    describe("before", before)

    let handle: WDVirtualDisplayHandle
    do {
        handle = try WDVirtualDisplayHandle.create(with: config)
    } catch {
        fail("create failed: \(error.localizedDescription)", code: 3)
    }
    print("created virtual display id=\(handle.displayID); holding for \(seconds)s")

    var disturbed = false
    for tick in 0..<(seconds * 2) {
        Thread.sleep(forTimeInterval: 0.5)
        let now = snapshot()
        if tick == 1 { describe("during", now) }
        // Rollback trigger: every display that existed before must be unchanged.
        let survivors = now.filter { $0.id != handle.displayID }
        if survivors != before {
            describe("DISTURBED", now)
            disturbed = true
            break
        }
    }
    handle.invalidate()
    Thread.sleep(forTimeInterval: 1.5)
    let after = snapshot()
    describe("after", after)
    if after != before { fail("display arrangement did not return to the initial state", code: 4) }
    if disturbed { fail("existing displays changed while the virtual display was up; removed it", code: 5) }
    print("RESULT: virtual display registered and removed; existing arrangement untouched")
default:
    fail("unknown command \(command)", code: 64)
}
