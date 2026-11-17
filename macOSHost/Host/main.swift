import AppKit
import ApplicationServices
import AVFoundation
import CoreGraphics
import ServiceManagement
import SwiftUI
import WDSession

// WiredDisplay host: a menu-bar app (no Dock icon). Run it as an app bundle
// (scripts/build-host-app.sh, then `open`) so Screen Recording and
// Accessibility are granted to WiredDisplayHost itself, not to a terminal.
//
// Flags: --allow-input        start with touch input enabled (default off, D-006)
//        --codec h264|hevc    default hevc (if the iPad supports it, else h264)
//        --bitrate-mbps N     default 80 (5...150)
//        --chroma 420|444|hybrid  default hybrid (4:2:0 motion, 4:4:4 when still);
//                             the menu's Quality presets set chroma + depth and are remembered
//        --depth 8|10         default 10 (HEVC Main10, smooth gradients)
//        --color srgb|p3      default srgb; p3 is experimental (BUG-033)
//        --fps N              default 60 (24...120)
//        --space native|more|most  default more: "looks like" one step larger than native

/// The menu bar item and its panel (a popover with tabs and cards).
@MainActor
final class StatusMenu: NSObject, NSPopoverDelegate {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let popover = NSPopover()
    private let model = PanelModel()
    private var controller: HostController?
    private var state: HostController.State = .waitingForDevice
    private var ticker: Timer?
    private var brightnessKeys: BrightnessKeys?

    func attach(_ controller: HostController) {
        self.controller = controller
        item.button?.image = MenuBarGlyph.image(streaming: false)
        item.button?.toolTip = "WiredDisplay"
        item.button?.target = self
        item.button?.action = #selector(togglePanel)
        model.actions = makeActions(controller)
        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self
        popover.contentViewController = NSHostingController(rootView: StatusPanelView(model: model))
        controller.onBrightnessChange = { [weak self] value in
            MainActor.assumeIsolated { self?.model.snapshot.brightness = value }
        }
        let keys = BrightnessKeys(controller: controller)
        keys.start()
        brightnessKeys = keys
        refresh()
    }

    func show(_ state: HostController.State) {
        self.state = state
        let streaming: Bool
        if case .streaming = state { streaming = true } else { streaming = false }
        item.button?.image = MenuBarGlyph.image(streaming: streaming)
        refresh()
    }

    @objc private func togglePanel() {
        if popover.isShown {
            popover.performClose(nil)
            return
        }
        guard let button = item.button else { return }
        refresh()
        NSApp.activate(ignoringOtherApps: true)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        ticker = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    nonisolated func popoverDidClose(_ notification: Notification) {
        MainActor.assumeIsolated {
            ticker?.invalidate()
            ticker = nil
        }
    }

    private func refresh() {
        guard let controller else { return }
        model.snapshot = Self.snapshot(controller: controller, state: state)
    }

    static func snapshot(controller: HostController, state: HostController.State) -> PanelSnapshot {
        let status = controller.status
        var s = PanelSnapshot()
        switch state {
        case .streaming: (s.stateText, s.stateColor) = ("Streaming to \(status.iPadName ?? "iPad")", .green)
        case .waitingForDevice: (s.stateText, s.stateColor) = ("Waiting for the iPad on USB", .orange)
        case .connecting: (s.stateText, s.stateColor) = ("Connecting…", .orange)
        case .pairing(let code): (s.stateText, s.stateColor) = ("Pairing: confirm code \(code)", .blue)
        case .audioOnly(let device): (s.stateText, s.stateColor) = ("Audio only: \(device)", .teal)
        case .backingOff(let reason): (s.stateText, s.stateColor) = ("Retrying: \(reason.prefix(50))", .red)
        case .stopped: (s.stateText, s.stateColor) = ("Stopped", .gray)
        }
        if let since = status.streamingSince {
            let minutes = Int(Date().timeIntervalSince(since) / 60)
            s.connectedFor = minutes < 1 ? "Connected just now"
                : "Connected for " + (minutes >= 60 ? "\(minutes / 60) h \(minutes % 60) min" : "\(minutes) min")
        }
        s.looksLike = status.pointSize
        s.pixels = [status.pixelSize.map { "\($0) px" }, status.refreshHz.map { "\($0) Hz" }]
            .compactMap { $0 }.joined(separator: " · ")
        if let codec = status.codec, let encoding = status.encoding { s.encoding = "\(codec) · \(encoding)" }
        s.limitNote = controller.decodeLimitNote.map { "Limited for this iPad: \($0)" }
        s.brightness = controller.brightness
        s.quality = controller.qualityPreset
        s.inputEnabled = controller.isInputEnabled
        s.accessibility = AXIsProcessTrusted()
        s.screenRecording = CGPreflightScreenCaptureAccess()
        s.speaker = status.speaker
        s.microphone = status.microphone
        s.autoSwitchAudio = controller.audioRouter.isEnabled
        s.paired = controller.trust.peers.map { .init(name: $0.name, key: String($0.fingerprint.prefix(8))) }
        if status.iPadName != nil { s.connectionCode = controller.connectionCode.withLock { $0 } }
        s.openAtLogin = LoginItem.isEnabled
        s.loginNeedsApproval = LoginItem.needsApproval
        s.version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
        return s
    }

    private func makeActions(_ controller: HostController) -> PanelActions {
        var a = PanelActions()
        a.setBrightness = { controller.setBrightness($0) }
        a.setQuality = { controller.setQuality($0) }
        a.setInput = { [weak self] enable in
            if enable && !AXIsProcessTrusted() {
                // Shows the system prompt that leads to Privacy & Security > Accessibility.
                // Literal value of kAXTrustedCheckOptionPrompt (the C global is not
                // concurrency-safe to reference under Swift 6).
                let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
                _ = AXIsProcessTrustedWithOptions(options)
            }
            controller.setInputEnabled(enable)
            self?.refresh()
        }
        a.setOpenAtLogin = { [weak self] enable in
            LoginItem.set(enable)
            if LoginItem.needsApproval { SMAppService.openSystemSettingsLoginItems() }
            self?.refresh()
        }
        a.setAutoSwitchAudio = { controller.audioRouter.isEnabled = $0 }
        a.openDisplaySettings = { Self.open("x-apple.systempreferences:com.apple.Displays-Settings.extension") }
        a.openSoundSettings = { Self.open("x-apple.systempreferences:com.apple.Sound-Settings.extension") }
        a.openAccessibility = { Self.open("x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") }
        a.openScreenRecording = { Self.open("x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") }
        a.forgetPaired = { [weak self] in self?.forgetPaired() }
        a.showLog = {
            let log = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/WiredDisplayHost.log")
            NSWorkspace.shared.open([log], withApplicationAt: URL(fileURLWithPath: "/System/Applications/Utilities/Console.app"),
                                    configuration: NSWorkspace.OpenConfiguration())
        }
        a.quit = { [weak self] in self?.quit() }
        return a
    }

    private static func open(_ url: String) {
        if let url = URL(string: url) { NSWorkspace.shared.open(url) }
    }

    private func forgetPaired() {
        popover.performClose(nil)
        let alert = NSAlert()
        alert.messageText = "Forget all paired iPads?"
        alert.informativeText = "The next iPad that connects is paired automatically. The current session keeps running until it disconnects."
        alert.addButton(withTitle: "Forget")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        controller?.trust.forgetAllPeers()
        controller?.forgetDecodeLimits()
        Log.info("paired iPads forgotten by the user")
        refresh()
    }

    /// Called from the session thread; shows the alert on the main thread and
    /// waits. Gives up (rejects) after 2 minutes.
    nonisolated static func confirmPairing(_ peer: SecureChannel.Peer) -> Bool {
        DispatchQueue.main.sync {
            let alert = NSAlert()
            alert.messageText = "Pair a new iPad?"
            alert.informativeText = "An iPad that is not paired with this Mac wants to show the Mac's screen and send input.\n\n" +
                "Pair only if the WiredDisplay app on your iPad shows this code:\n\n\(peer.pairingCode)"
            alert.addButton(withTitle: "Pair")
            alert.addButton(withTitle: "Don't Pair")
            NSApp.activate(ignoringOtherApps: true)
            let timer = Timer(timeInterval: 120, repeats: false) { _ in NSApp.abortModal() }
            RunLoop.main.add(timer, forMode: .modalPanel)
            defer { timer.invalidate() }
            return alert.runModal() == .alertFirstButtonReturn
        }
    }

    private func quit() {
        popover.performClose(nil)
        controller?.stop()
        // Give teardown (release buttons, stop capture, remove display) a moment.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { NSApp.terminate(nil) }
    }
}

/// `--render-panel <dir>`: renders every panel tab with sample data to PNGs
/// (light and dark) for design review, then exits. No session is started.
@MainActor
func renderPanelPreviews(to directory: String) {
    var sample = PanelSnapshot()
    sample.stateText = "Streaming to iPad"
    sample.stateColor = .green
    sample.connectedFor = "Connected for 12 min"
    sample.looksLike = "1590 × 1192"
    sample.pixels = "3180 × 2384 px · 60 Hz"
    sample.encoding = "HEVC · 4:2:0 · 10-bit"
    sample.brightness = 0.7
    sample.quality = .pro
    sample.inputEnabled = true
    sample.accessibility = true
    sample.screenRecording = true
    sample.speaker = true
    sample.paired = [.init(name: "iPad", key: "0d7238ca")]
    sample.connectionCode = "190 333"
    sample.openAtLogin = true
    sample.version = "0.2.0"
    for appearance in [NSAppearance.Name.aqua, .darkAqua] {
        for tab in PanelModel.Tab.allCases {
            let model = PanelModel()
            model.snapshot = sample
            model.tab = tab
            let host = NSHostingView(rootView: StatusPanelView(model: model)
                .background(Color(nsColor: .windowBackgroundColor)))
            host.appearance = NSAppearance(named: appearance)
            host.frame.size = host.fittingSize
            host.layoutSubtreeIfNeeded()
            guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { continue }
            host.cacheDisplay(in: host.bounds, to: rep)
            let name = "\(directory)/panel-\(tab.rawValue)-\(appearance == .aqua ? "light" : "dark").png"
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: name))
        }
    }
}

func parseOptions() -> HostController.Options {
    var options = HostController.Options()
    // The last preset chosen in the menu; --chroma / --depth still override.
    // The user's last menu choice (D-006: off until they turn it on once).
    options.allowInput = UserDefaults.standard.bool(forKey: HostController.allowInputKey)
    if let saved = QualityPreset.saved {
        options.chroma = saved.chroma
        options.tenBit = saved.tenBit
    }
    var arguments = Array(CommandLine.arguments.dropFirst())
    func fail(_ message: String) -> Never {
        Log.error(message)
        FileHandle.standardError.write(Data((message + "\n").utf8))
        exit(64)
    }
    while !arguments.isEmpty {
        let flag = arguments.removeFirst()
        func value() -> String {
            guard !arguments.isEmpty else { fail("\(flag) needs a value") }
            return arguments.removeFirst()
        }
        switch flag {
        case "--allow-input": options.allowInput = true
        case "--test-decode-fallback": options.testDecodeFallback = true
        case "--trace-keys": continue // read by BrightnessKeys
        case "--codec":
            switch value() {
            case "h264": options.codec = .h264
            case "hevc": options.codec = .hevc
            case let other: fail("unknown codec \(other)")
            }
        case "--color":
            switch value() {
            case "p3": options.displayP3 = true
            case "srgb": options.displayP3 = false
            case let other: fail("unknown colour mode \(other)")
            }
        case "--chroma":
            let raw = value()
            guard let mode = ChromaMode(rawValue: raw) else { fail("unknown chroma mode \(raw) (420, 444, hybrid)") }
            options.chroma = mode
        case "--depth":
            switch value() {
            case "8": options.tenBit = false
            case "10": options.tenBit = true
            case let other: fail("unknown depth \(other) (8 or 10)")
            }
        case "--space":
            let raw = value()
            guard let space = VirtualDisplayController.Space(rawValue: raw) else { fail("unknown space \(raw) (native, more, most)") }
            options.space = space
        case "--bitrate-mbps":
            guard let mbps = Int(value()), (5...150).contains(mbps) else { fail("--bitrate-mbps expects 5...150") }
            options.bitrateMbps = mbps
        case "--fps":
            guard let fps = Int(value()), (24...120).contains(fps) else { fail("--fps expects 24...120") }
            options.fps = fps
        case let other where other.hasPrefix("-psn_"): continue // Finder launch argument
        default: fail("unknown flag \(flag)")
        }
    }
    return options
}

if let index = CommandLine.arguments.firstIndex(of: "--render-panel"), index + 1 < CommandLine.arguments.count {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    MainActor.assumeIsolated { renderPanelPreviews(to: CommandLine.arguments[index + 1]) }
    exit(0)
}

let options = parseOptions()
Log.info("WiredDisplayHost starting; input \(options.allowInput ? "enabled" : "disabled"), codec \(options.codec.map { "\($0)" } ?? "h264"), \(options.bitrateMbps) Mbit/s, \(options.fps) fps, colour \(options.displayP3 ? "Display P3" : "sRGB")")
if !CGPreflightScreenCaptureAccess() {
    Log.warn("Screen Recording not granted; requesting (the stream will be black until granted)")
    _ = CGRequestScreenCaptureAccess()
}

// Recording the "iPad Speaker" loopback counts as microphone access. Ask once
// at launch, while the Mac's screen is visible, instead of mid-session (BUG-024).
switch AVCaptureDevice.authorizationStatus(for: .audio) {
case .notDetermined:
    AVCaptureDevice.requestAccess(for: .audio) { granted in
        Log.info("Microphone permission (for Mac audio -> iPad): \(granted ? "granted" : "denied")")
    }
case .denied, .restricted:
    Log.warn("Microphone permission denied: Mac audio cannot reach the iPad (System Settings › Privacy & Security › Microphone)")
default:
    break
}

LoginItem.applyDefault()

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
MainActor.assumeIsolated {
    let menu = StatusMenu()
    let controller = HostController(options: options, confirmPairing: StatusMenu.confirmPairing) { state in
        Task { @MainActor in menu.show(state) }
    }
    menu.attach(controller)
    controller.start()
    // Keep both alive for the life of the process.
    objc_setAssociatedObject(app, "wd.menu", menu, .OBJC_ASSOCIATION_RETAIN)
    objc_setAssociatedObject(app, "wd.controller", controller, .OBJC_ASSOCIATION_RETAIN)
}
app.run()
