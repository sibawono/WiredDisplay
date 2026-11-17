import AppKit
import ApplicationServices
import AVFoundation
import CoreGraphics
import ServiceManagement
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

@MainActor
final class StatusMenu: NSObject {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let stateLine = NSMenuItem(title: "Starting…", action: nil, keyEquivalent: "")
    private let inputToggle = NSMenuItem(title: "Allow Input from iPad (touch, keyboard, trackpad)", action: #selector(toggleInput), keyEquivalent: "")
    private let permissions = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let loginToggle = NSMenuItem(title: "Open at Login", action: #selector(toggleLogin), keyEquivalent: "")
    private let pairedLine = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let qualityItem = NSMenuItem(title: "Quality", action: nil, keyEquivalent: "")
    private var qualityItems: [QualityPreset: NSMenuItem] = [:]
    private let forgetItem = NSMenuItem(title: "Forget Paired iPads…", action: #selector(forgetPaired), keyEquivalent: "")
    private var controller: HostController?

    func attach(_ controller: HostController) {
        self.controller = controller
        item.button?.image = MenuBarGlyph.image(streaming: false)
        item.button?.toolTip = "WiredDisplay host"
        let menu = NSMenu()
        stateLine.isEnabled = false
        permissions.isEnabled = false
        menu.addItem(stateLine)
        menu.addItem(permissions)
        menu.addItem(.separator())
        let qualityMenu = NSMenu()
        for preset in QualityPreset.allCases {
            let entry = NSMenuItem(title: preset.title, action: #selector(chooseQuality(_:)), keyEquivalent: "")
            entry.target = self
            entry.representedObject = preset.rawValue
            if #available(macOS 14.4, *) { entry.subtitle = preset.detail } else { entry.toolTip = preset.detail }
            qualityMenu.addItem(entry)
            qualityItems[preset] = entry
        }
        qualityItem.submenu = qualityMenu
        menu.addItem(qualityItem)
        inputToggle.target = self
        menu.addItem(inputToggle)
        loginToggle.target = self
        menu.addItem(loginToggle)
        menu.addItem(.separator())
        pairedLine.isEnabled = false
        menu.addItem(pairedLine)
        forgetItem.target = self
        menu.addItem(forgetItem)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit WiredDisplay", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
        item.menu = menu
        refresh()
    }

    func show(_ state: HostController.State) {
        switch state {
        case .waitingForDevice: stateLine.title = "Waiting for iPad on USB (open the app on the iPad)"
        case .connecting: stateLine.title = "Connecting…"
        case .streaming(let detail): stateLine.title = "Streaming: \(detail)"
        case .audioOnly(let device): stateLine.title = "Audio only: \(device) (iPad app in background)"
        case .backingOff(let reason): stateLine.title = "Retrying: \(reason.prefix(80))"
        case .pairing(let code): stateLine.title = "Pairing a new iPad: code \(code)"
        case .stopped: stateLine.title = "Stopped"
        }
        let streaming: Bool
        if case .streaming = state { streaming = true } else { streaming = false }
        item.button?.image = MenuBarGlyph.image(streaming: streaming)
        refresh()
    }

    private func refresh() {
        inputToggle.state = (controller?.isInputEnabled ?? false) ? .on : .off
        let screen = CGPreflightScreenCaptureAccess() ? "granted" : "MISSING"
        let accessibility = AXIsProcessTrusted() ? "granted" : "MISSING"
        let currentQuality = controller?.qualityPreset
        for (preset, entry) in qualityItems { entry.state = preset == currentQuality ? .on : .off }
        qualityItem.title = "Quality: " + (currentQuality.map { $0.title.components(separatedBy: " — ").first ?? $0.title } ?? "Custom")
        loginToggle.state = LoginItem.isEnabled ? .on : .off
        let paired = controller?.trust.peers ?? []
        pairedLine.title = paired.isEmpty ? "Paired iPads: none (the next iPad pairs automatically)"
            : "Paired: " + paired.map { "\($0.name) (\($0.fingerprint.prefix(8)))" }.joined(separator: ", ")
        forgetItem.isEnabled = !paired.isEmpty
        if let code = controller?.connectionCode.withLock({ $0 }) { pairedLine.title += " · connection code \(code)" }
        loginToggle.title = LoginItem.needsApproval ? "Open at Login (approve in Login Items)" : "Open at Login"
        permissions.title = "Screen Recording: \(screen) · Accessibility: \(accessibility)"
    }

    @objc private func toggleInput() {
        guard let controller else { return }
        let enable = !controller.isInputEnabled
        if enable && !AXIsProcessTrusted() {
            // Shows the system prompt that leads to Privacy & Security > Accessibility.
            // Literal value of kAXTrustedCheckOptionPrompt (the C global is not
            // concurrency-safe to reference under Swift 6).
            let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(options)
        }
        controller.setInputEnabled(enable)
        refresh()
    }

    @objc private func chooseQuality(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let preset = QualityPreset(rawValue: raw) else { return }
        controller?.setQuality(preset)
        refresh()
    }

    @objc private func forgetPaired() {
        let alert = NSAlert()
        alert.messageText = "Forget all paired iPads?"
        alert.informativeText = "The next iPad that connects is paired automatically. The current session keeps running until it disconnects."
        alert.addButton(withTitle: "Forget")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        controller?.trust.forgetAllPeers()
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

    @objc private func toggleLogin() {
        LoginItem.set(!LoginItem.isEnabled)
        if LoginItem.needsApproval { SMAppService.openSystemSettingsLoginItems() }
        refresh()
    }

    @objc private func quit() {
        controller?.stop()
        // Give teardown (release buttons, stop capture, remove display) a moment.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { NSApp.terminate(nil) }
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
