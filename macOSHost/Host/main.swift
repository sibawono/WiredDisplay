import AppKit
import ApplicationServices
import AVFoundation
import CoreGraphics
import ScreenCaptureKit
import ServiceManagement
import SwiftUI
import WDHostCore
import WDSession
import WDTransport

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
//        --space native|more|most  default native: one capture pixel per panel pixel

/// The menu bar item and its panel (a popover with tabs and cards).
@MainActor
final class StatusMenu: NSObject {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let popover = GlassPopover()
    private let model = PanelModel()
    private var fleet: HostFleet?
    /// The iPad the panel shows (several iPads, D-041).
    private var controller: HostController? { fleet?.focus }
    private var state: HostController.State { controller.map { fleet?.state(of: $0) ?? .waitingForDevice } ?? .waitingForDevice }
    private var ticker: Timer?
    private var terminationObservers: [NSObjectProtocol] = []
    private var signalSources: [DispatchSourceSignal] = []
    private var shuttingDown = false

    func attach(_ fleet: HostFleet) {
        self.fleet = fleet
        registerTerminationHandlers()
        item.button?.image = MenuBarGlyph.image(streaming: false)
        item.button?.toolTip = "WiredDisplay"
        item.button?.target = self
        item.button?.action = #selector(togglePanel)
        model.actions = makeActions(fleet)
        popover.onShow = { [weak self] in self?.panelShown() }
        popover.onClose = { [weak self] in self?.panelClosed() }
        let host = NSHostingController(rootView: StatusPanelView(model: model))
        host.sizingOptions = .preferredContentSize // follows tab height changes
        popover.contentViewController = host
        fleet.onChange = { [weak self] in MainActor.assumeIsolated { self?.fleetChanged() } }
        fleet.onControllerAdded = { [weak self] controller in
            MainActor.assumeIsolated {
                guard let self else { return }
                controller.onBrightnessChange = { [weak self, weak controller] value in
                    MainActor.assumeIsolated {
                        guard let self, let controller, controller === self.controller else { return }
                        self.model.snapshot.brightness = value
                    }
                }
                // One shared tap on its own thread; the keys act on the iPad
                // that has the pointer (C-3).
                BrightnessKeys.shared.add(controller)
            }
        }
        fleet.onControllerRemoved = { controller in
            BrightnessKeys.shared.remove(controller)
        }
        refresh()
    }

    private func fleetChanged() {
        let streaming = fleet?.controllers.contains { $0.status.iPadName != nil } ?? false
        item.button?.image = MenuBarGlyph.image(streaming: streaming)
        refresh()
    }

    @objc private func togglePanel() {
        if popover.isShown {
            popover.performClose()
            return
        }
        guard let button = item.button else { return }
        refresh()
        NSApp.activate(ignoringOtherApps: true)
        // Size the popover to its content BEFORE showing it: it was placed for
        // 320 pt and then grew upward past the menu bar (user report).
        if let view = popover.contentViewController?.view {
            view.layoutSubtreeIfNeeded()
            popover.contentSize = view.fittingSize
        }
        popover.show(below: button)
        ticker = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    // MARK: self-check (`--self-check-panel <dir>`)

    /// Opens the real popover, captures every tab, then presses a switch and
    /// the brightness slider with real mouse events (Accessibility) and
    /// captures while held, to check the Liquid Glass lens is not clipped and
    /// the text layout. The switch used (headphone switching) is toggled back.
    func selfCheck(to directory: String) async {
        func capture(_ name: String) async {
            guard let window = popover.window,
                  let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true),
                  let target = content.windows.first(where: { $0.windowID == CGWindowID(window.windowNumber) }) else {
                Log.warn("self-check: popover window not capturable"); return
            }
            let configuration = SCStreamConfiguration()
            configuration.width = Int(window.frame.width * window.backingScaleFactor)
            configuration.height = Int(window.frame.height * window.backingScaleFactor)
            configuration.showsCursor = false
            guard let image = try? await SCScreenshotManager.captureImage(
                contentFilter: SCContentFilter(desktopIndependentWindow: target), configuration: configuration) else { return }
            try? NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?
                .write(to: URL(fileURLWithPath: "\(directory)/check-\(name).png"))
        }
        func find<T: NSView>(_ type: T.Type, in view: NSView) -> [T] {
            (view as? T).map { [$0] } ?? [] + view.subviews.flatMap { find(type, in: $0) }
        }
        /// Screen point (CG, top-left origin) of a view's centre.
        func point(of view: NSView) -> CGPoint? {
            guard let window = view.window, let screen = NSScreen.screens.first else { return nil }
            let rect = window.convertToScreen(view.convert(view.bounds, to: nil))
            return CGPoint(x: rect.midX, y: screen.frame.maxY - rect.midY)
        }
        func mouse(_ type: CGEventType, _ at: CGPoint) {
            CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: at, mouseButton: .left)?.post(tap: .cghidEventTap)
        }
        let pause: (Int) async -> Void = { ms in try? await Task.sleep(for: .milliseconds(ms)) }

        if !popover.isShown { togglePanel() }
        await pause(900)
        for tab in PanelModel.Tab.allCases {
            model.tab = tab
            await pause(400)
            await capture("tab-\(tab.rawValue)")
        }
        guard let root = popover.contentViewController?.view else { return }
        // Switch: the Audio tab's headphone switching (a preference only).
        model.tab = .audio
        await pause(400)
        if let control = find(NSSwitch.self, in: root).first ?? find(NSButton.self, in: root).first(where: { $0.className.contains("Switch") }), let at = point(of: control) {
            let before = fleet?.audioRouter.isEnabled
            mouse(.leftMouseDown, at)
            await pause(350)
            await capture("switch-pressed")
            mouse(.leftMouseDragged, CGPoint(x: at.x - 8, y: at.y))
            await pause(250)
            await capture("switch-dragged")
            mouse(.leftMouseUp, CGPoint(x: at.x - 8, y: at.y))
            await pause(500)
            if fleet?.audioRouter.isEnabled != before { // put the setting back
                mouse(.leftMouseDown, at)
                mouse(.leftMouseUp, at)
                await pause(400)
            }
        }
        // Slider: press and hold the brightness knob without moving it.
        model.tab = .display
        await pause(400)
        if let slider = find(NSSlider.self, in: root).first, let window = slider.window,
           let screen = NSScreen.screens.first, let cell = slider.cell as? NSSliderCell {
            let knob = slider.convert(cell.knobRect(flipped: slider.isFlipped), to: nil)
            let rect = window.convertToScreen(knob)
            let at = CGPoint(x: rect.midX, y: screen.frame.maxY - rect.midY)
            mouse(.leftMouseDown, at)
            await pause(350)
            await capture("slider-pressed")
            mouse(.leftMouseUp, at)
        }
        await pause(300)
        popover.performClose()
        Log.info("self-check: captures written to \(directory)")
    }

    private func panelShown() {
        let window = popover.window
        let screen = window?.screen
        Log.info("panel shown: \(window?.frame ?? .zero) on \(screen?.localizedName ?? "no screen"), visible \(screen?.visibleFrame ?? .zero)")
    }

    private func panelClosed() {
        ticker?.invalidate()
        ticker = nil
    }

    private func refresh() {
        guard let controller else {
            // No cabled device yet: the panel still shows status, saved settings and paired iPads.
            let defaults = UserDefaults.standard
            let opts = fleet?.options
            var waiting = PanelSnapshot()
            waiting.quality = opts.flatMap { QualityPreset(chroma: $0.chroma, tenBit: $0.tenBit) } ?? QualityPreset.saved
            waiting.inputEnabled = opts?.allowInput ?? defaults.bool(forKey: HostController.allowInputKey)
            waiting.matchRefresh = defaults.object(forKey: HostController.refreshKey) as? Bool ?? true
            waiting.localCursor = defaults.object(forKey: HostController.localCursorKey) as? Bool ?? true
            waiting.paired = TrustStore(keychainService: "dev.wireddisplay.host").peers
                .map { .init(name: $0.name, model: $0.model, key: String($0.fingerprint.prefix(8))) }
            waiting.accessibility = AXIsProcessTrusted()
            waiting.screenRecording = CGPreflightScreenCaptureAccess()
            waiting.openAtLogin = LoginItem.isEnabled
            waiting.keepDisplayAwake = HostController.keepDisplayAwake
            waiting.keepMacAwake = HostController.keepMacAwake
            waiting.transportMode = opts?.transportMode ?? HostController.savedTransportMode
            waiting.androidUSBDevices = Self.androidUSBDevicesSnapshot()
            waiting.autoSwitchAudio = fleet?.audioRouter.isEnabled ?? true
            waiting.autoSwitchMicrophone = fleet?.audioRouter.usesHeadsetMicrophone ?? true
            waiting.bothSpeakers = HostController.bothSpeakers
            waiting.bothSpeakersDelayMs = HostController.bothSpeakersDelayMs
            waiting.bothSpeakersBalance = HostController.bothSpeakersBalance
            waiting.version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
            model.snapshot = waiting
            return
        }
        var snapshot = Self.snapshot(controller: controller, state: state)
        snapshot.otherIPads = (fleet?.controllers ?? []).filter { $0 !== controller }.compactMap { $0.status.iPadName }
        model.snapshot = snapshot
    }

    static func snapshot(controller: HostController, state: HostController.State) -> PanelSnapshot {
        let status = controller.status
        var s = PanelSnapshot()
        switch state {
        case .streaming:
            let transport = status.activeTransport.map { " (\($0.rawValue))" } ?? ""
            (s.stateText, s.stateColor) = ("Streaming to \(status.iPadName ?? "iPad")\(transport)", .green)
        case .paused(let why): (s.stateText, s.stateColor) = ("Paused: \(why)", .orange)
        case .waitingForDevice: (s.stateText, s.stateColor) = ("Waiting for the iPad", .orange)
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
        s.displaySpace = status.displaySpace
        s.canChangeDisplaySpace = controller.canChangeDisplaySpace
        s.displaySpaceError = status.displaySpaceError
        s.pixels = [status.pixelSize.map { "\($0) px" }, status.refreshHz.map { "\($0) Hz" }]
            .compactMap { $0 }.joined(separator: " · ")
        if let codec = status.codec, let encoding = status.encoding { s.encoding = "\(codec) · \(encoding)" }
        s.limitNote = controller.decodeLimitNote.map { "Limited for this iPad: \($0)" }
        s.canResetDecodeLimits = controller.canResetDecodeLimits
        s.brightness = controller.brightness
        s.quality = controller.qualityPreset
        s.inputEnabled = controller.isInputEnabled
        s.accessibility = AXIsProcessTrusted()
        s.screenRecording = CGPreflightScreenCaptureAccess()
        s.speaker = status.speaker
        s.microphone = status.microphone
        s.autoSwitchAudio = controller.audioRouter.isEnabled
        s.matchRefresh = controller.refreshFollowsIPad
        s.localCursor = controller.localCursor
        s.autoSwitchMicrophone = controller.audioRouter.usesHeadsetMicrophone
        s.bothSpeakers = HostController.bothSpeakers
        s.bothSpeakersDelayMs = HostController.bothSpeakersDelayMs
        s.bothSpeakersBalance = HostController.bothSpeakersBalance
        s.paired = controller.trust.peers.map { .init(name: $0.name, model: $0.model, key: String($0.fingerprint.prefix(8))) }
        if status.iPadName != nil { s.connectionCode = controller.connectionCode.withLock { $0 } }
        let bioKey = controller.biometricPublicKey
        s.touchID = TouchIDSetup(
            sudoModule: FileManager.default.fileExists(atPath: "/usr/local/lib/pam/pam_wireddisplay.so"),
            lockScreenPlugin: FileManager.default.fileExists(atPath: "/Library/Security/SecurityAgentPlugins/WiredDisplayAuth.bundle"),
            installedKey: try? String(contentsOfFile: "/Library/Application Support/WiredDisplay/pam_keys/\(NSUserName()).pub", encoding: .utf8),
            iPadKey: bioKey.map { Data($0).base64EncodedString() })
        s.pamAllowWiFi = UserDefaults.standard.bool(forKey: HostFleet.pamAllowWiFiKey)
        if let bioKey {
            s.pamEnrolledKeyFingerprint = String(SecureChannel.fingerprint(bioKey).prefix(8))
        }
        s.openAtLogin = LoginItem.isEnabled
        s.keepDisplayAwake = HostController.keepDisplayAwake
        s.keepMacAwake = HostController.keepMacAwake
        s.transportMode = controller.transportMode
        s.androidUSBDevices = Self.androidUSBDevicesSnapshot()
        s.loginNeedsApproval = LoginItem.needsApproval
        s.version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
        return s
    }

    private static func androidUSBDevicesSnapshot() -> [PanelSnapshot.AndroidUSBDevice] {
        let approved = HostController.aoaApprovedSerials()
        return AoaClient.listDevices().map { dev in
            PanelSnapshot.AndroidUSBDevice(
                serial: dev.serial,
                name: dev.product ?? "Android Device",
                inAccessoryMode: dev.inAccessoryMode,
                approved: approved.contains(dev.serial)
            )
        }
    }

    private func makeActions(_ fleet: HostFleet) -> PanelActions {
        var a = PanelActions()
        a.setDisplaySpace = { fleet.focus?.setDisplaySpace($0) }
        a.setBrightness = { fleet.focus?.setBrightness($0) }
        a.setQuality = { [weak self] preset in
            fleet.setQuality(preset)
            self?.refresh()
        }
        a.resetDecodeLimits = { [weak self] in
            fleet.resetDecodeLimits()
            self?.refresh()
        }
        a.setInput = { [weak self] enable in
            if enable && !AXIsProcessTrusted() {
                // Shows the system prompt that leads to Privacy & Security > Accessibility.
                // Literal value of kAXTrustedCheckOptionPrompt (the C global is not
                // concurrency-safe to reference under Swift 6).
                let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
                _ = AXIsProcessTrustedWithOptions(options)
            }
            fleet.setInputEnabled(enable)
            self?.refresh()
        }
        a.setOpenAtLogin = { [weak self] enable in
            LoginItem.set(enable)
            if LoginItem.needsApproval { SMAppService.openSystemSettingsLoginItems() }
            self?.refresh()
        }
        a.setAutoSwitchAudio = { fleet.audioRouter.isEnabled = $0 }
        a.setMatchRefresh = { fleet.setRefreshFollowsIPad($0) }
        a.setKeepDisplayAwake = { fleet.setKeepAwake(display: $0) }
        a.setKeepMacAwake = { fleet.setKeepAwake(mac: $0) }
        a.setTransportMode = { [weak self] mode in
            fleet.setTransportMode(mode)
            self?.refresh()
        }
        a.setAndroidAoaApproved = { [weak self] serial, approved in
            fleet.setAndroidAoaApproved(serial: serial, approved: approved)
            self?.refresh()
        }
        a.setLocalCursor = { fleet.setLocalCursor($0) }
        a.setAutoSwitchMicrophone = { fleet.audioRouter.usesHeadsetMicrophone = $0 }
        a.setBothSpeakers = { fleet.setBothSpeakers($0) }
        a.setBothSpeakersDelayMs = { fleet.setBothSpeakersDelayMs($0) }
        a.setBothSpeakersBalance = { fleet.setBothSpeakersBalance($0) }
        a.openDisplaySettings = { Self.open("x-apple.systempreferences:com.apple.Displays-Settings.extension") }
        a.openSoundSettings = { Self.open("x-apple.systempreferences:com.apple.Sound-Settings.extension") }
        a.openAccessibility = { Self.open("x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") }
        a.openScreenRecording = { Self.open("x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") }
        a.forgetPaired = { [weak self] in self?.forgetPaired() }
        a.setPamAllowWiFi = { [weak self] allow in
            fleet.setPamAllowWiFi(allow)
            self?.refresh()
        }
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
        popover.performClose()
        let alert = NSAlert()
        alert.messageText = "Forget all paired iPads?"
        alert.informativeText = "The next iPad that connects is paired automatically. The current session keeps running until it disconnects."
        alert.addButton(withTitle: "Forget")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        (controller?.trust ?? TrustStore(keychainService: "dev.wireddisplay.host")).forgetAllPeers()
        fleet?.forgetDecodeLimits()
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
            let timer = Timer(timeInterval: 120, repeats: false) { _ in
                MainActor.assumeIsolated { NSApp.abortModal() }
            }
            RunLoop.main.add(timer, forMode: .modalPanel)
            defer { timer.invalidate() }
            return alert.runModal() == .alertFirstButtonReturn
        }
    }

    private func registerTerminationHandlers() {
        guard terminationObservers.isEmpty && signalSources.isEmpty else { return }
        let powerOff = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.willPowerOffNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.handBackOnTermination(reason: "Mac shutting down or restarting") }
        }
        let willTerminate = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.handBackOnTermination(reason: "application terminating") }
        }
        terminationObservers = [powerOff, willTerminate]

        for sig in [SIGTERM, SIGINT] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            let name = sig == SIGTERM ? "SIGTERM" : "SIGINT"
            source.setEventHandler { [weak self] in
                MainActor.assumeIsolated { self?.handBackOnTermination(reason: name, exitAfter: true) }
            }
            source.resume()
            signalSources.append(source)
        }
    }

    private func handBackOnTermination(reason: String, exitAfter: Bool = false) {
        if !shuttingDown {
            shuttingDown = true
            Log.info("WiredDisplayHost stopping (\(reason)); handing audio back")
            popover.performClose()
            fleet?.stop()
        }
        fleet?.audioRouter.handBackBeforeQuit()
        if exitAfter { exit(0) }
    }

    private func quit() {
        shuttingDown = true
        popover.performClose()
        fleet?.stop()
        fleet?.audioRouter.handBackBeforeQuit()
        // Give teardown (release buttons, stop capture, remove display) a
        // moment; hand the audio back once more in case a late audio route
        // from the iPad arrived meanwhile.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            self?.fleet?.audioRouter.handBackBeforeQuit()
            NSApp.terminate(nil)
        }
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
    sample.looksLike = "1366 × 1024"
    sample.displaySpace = .native
    sample.canChangeDisplaySpace = true
    sample.pixels = "2732 × 2048 px · 60 Hz"
    sample.encoding = "HEVC · 4:2:0 · 10-bit"
    sample.brightness = 0.7
    sample.quality = .pro
    sample.inputEnabled = true
    sample.accessibility = true
    sample.screenRecording = true
    sample.speaker = true
    sample.paired = [.init(name: "Alex’s iPad", model: "iPad Air 13-inch (M2)", key: "0d7238ca"), .init(name: "iPad", model: nil, key: "77c0e3a7")]
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

/// `--render-panel-live <dir>`: like `--render-panel`, but each tab is shown
/// in a real on-screen window (on the WiredDisplay screen if there is one)
/// and captured with ScreenCaptureKit, because Liquid Glass only renders in a
/// window on screen. Launch with `open -n … --args` so the app's own Screen
/// Recording permission applies. Captures only these windows.
@MainActor
func renderPanelLive(to directory: String) async {
    var sample = PanelSnapshot()
    sample.stateText = "Streaming to iPad"
    sample.stateColor = .green
    sample.connectedFor = "Connected for 12 min"
    sample.looksLike = "1536 × 1152"
    sample.displaySpace = .more
    sample.canChangeDisplaySpace = true
    sample.pixels = "2732 × 2048 px · 60 Hz"
    sample.encoding = "HEVC · 4:2:0 · 10-bit"
    sample.brightness = 0.7
    sample.quality = .pro
    sample.inputEnabled = true
    sample.accessibility = true
    sample.screenRecording = true
    sample.speaker = true
    sample.paired = [.init(name: "Alex’s iPad", model: "iPad Air 13-inch (M2)", key: "0d7238ca"), .init(name: "iPad", model: nil, key: "77c0e3a7")]
    sample.connectionCode = "190 333"
    sample.openAtLogin = true
    sample.version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    let screen = NSScreen.screens.first { $0.localizedName.contains("WiredDisplay") } ?? NSScreen.main
    for appearance in [NSAppearance.Name.aqua, .darkAqua] {
        for tab in PanelModel.Tab.allCases {
            let model = PanelModel()
            model.snapshot = sample
            model.tab = tab
            let host = NSHostingView(rootView: StatusPanelView(model: model))
            host.appearance = NSAppearance(named: appearance)
            host.frame.size = host.fittingSize
            let effect = NSVisualEffectView(frame: host.bounds)
            effect.material = .popover
            effect.blendingMode = .behindWindow
            effect.state = .active
            effect.wantsLayer = true
            effect.layer?.cornerRadius = 16
            effect.layer?.masksToBounds = true
            effect.addSubview(host)
            let window = NSPanel(contentRect: host.bounds, styleMask: [.borderless, .nonactivatingPanel],
                                 backing: .buffered, defer: false)
            window.isOpaque = false
            window.backgroundColor = .clear
            window.appearance = NSAppearance(named: appearance)
            window.contentView = effect
            window.level = .floating
            if let area = screen?.visibleFrame {
                window.setFrameOrigin(NSPoint(x: area.maxX - host.bounds.width - 24, y: area.maxY - host.bounds.height - 12))
            }
            window.orderFrontRegardless()
            try? await Task.sleep(for: .milliseconds(900))
            defer { window.orderOut(nil) }
            guard let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true),
                  let target = content.windows.first(where: { $0.windowID == CGWindowID(window.windowNumber) }) else {
                Log.warn("render-panel-live: window not shareable (Screen Recording permission?)")
                continue
            }
            let configuration = SCStreamConfiguration()
            let scale = window.backingScaleFactor
            configuration.width = Int(host.bounds.width * scale)
            configuration.height = Int(host.bounds.height * scale)
            configuration.showsCursor = false
            guard let image = try? await SCScreenshotManager.captureImage(
                contentFilter: SCContentFilter(desktopIndependentWindow: target), configuration: configuration) else { continue }
            let name = "\(directory)/live-\(tab.rawValue)-\(appearance == .aqua ? "light" : "dark").png"
            try? NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?
                .write(to: URL(fileURLWithPath: name))
        }
    }
}

func parseOptions() -> HostController.Options {
    var options = HostController.Options()
    options.transportMode = HostController.savedTransportMode
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
        case "--render-panel", "--render-panel-live", "--self-check-panel": _ = arguments.isEmpty ? "" : arguments.removeFirst()
        case "--power-efficient": VideoEncoder.powerEfficient = true
        case "--periodic-keyframes": VideoEncoder.periodicKeyframes = true
        case "--own-downscale":
            switch value() {
            case "on": VideoEncoder.ownDownscale = true
            case "off": VideoEncoder.ownDownscale = false
            case let other: fail("--own-downscale expects on|off, got \(other)")
            }
        case "--chroma-filter":
            switch value() {
            case "on": VideoEncoder.filteredChroma = true
            case "off": VideoEncoder.filteredChroma = false
            case let other: fail("--chroma-filter expects on|off, got \(other)")
            }
        case "--force-refresh":
            guard let fps = Int(value()), (24...120).contains(fps) else { fail("--force-refresh expects 24...120") }
            options.forceRefresh = fps
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
        case "--transport":
            let raw = value()
            guard let mode = TransportMode(rawValue: raw) else { fail("unknown transport \(raw) (usb, auto, wifi)") }
            options.transportMode = mode
        case "--bitrate-mbps":
            guard let mbps = Int(value()), (5...150).contains(mbps) else { fail("--bitrate-mbps expects 5...150") }
            options.bitrateMbps = mbps
        case "--fps":
            guard let fps = Int(value()), (24...120).contains(fps) else { fail("--fps expects 24...120") }
            options.fps = fps
            options.fpsOverride = fps
        case let other where other.hasPrefix("-psn_"): continue // Finder launch argument
        default: fail("unknown flag \(flag)")
        }
    }
    return options
}

if let index = CommandLine.arguments.firstIndex(of: "--render-panel-live"), index + 1 < CommandLine.arguments.count {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let directory = CommandLine.arguments[index + 1]
    Task { @MainActor in
        await renderPanelLive(to: directory)
        exit(0)
    }
    app.run()
}

if let index = CommandLine.arguments.firstIndex(of: "--render-panel"), index + 1 < CommandLine.arguments.count {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    MainActor.assumeIsolated { renderPanelPreviews(to: CommandLine.arguments[index + 1]) }
    exit(0)
}

let options = parseOptions()
Log.info("WiredDisplayHost starting; input \(options.allowInput ? "enabled" : "disabled"), codec \(options.codec.map { "\($0)" } ?? "h264"), \(options.bitrateMbps) Mbit/s, \(options.fpsOverride.map { "\($0) fps" } ?? "refresh follows the iPad (max 120)"), colour \(options.displayP3 ? "Display P3" : "sRGB")")
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
    // One controller per cabled iPad (D-041).
    let fleet = HostFleet(options: options, confirmPairing: StatusMenu.confirmPairing)
    menu.attach(fleet)
    fleet.start()
    // Sleep, wake, lock, screensaver, user switching (docs/POWER_LOCK_WAKE.md).
    PowerMonitor.shared.onChange.append { old, new in
        for controller in fleet.controllers { controller.powerChanged(from: old, to: new) }
    }
    PowerMonitor.shared.start()
    if let index = CommandLine.arguments.firstIndex(of: "--self-check-panel"), index + 1 < CommandLine.arguments.count {
        let directory = CommandLine.arguments[index + 1]
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(6))
            await menu.selfCheck(to: directory)
        }
    }
    // Keep both alive for the life of the process.
    objc_setAssociatedObject(app, "wd.menu", menu, .OBJC_ASSOCIATION_RETAIN)
    objc_setAssociatedObject(app, "wd.fleet", fleet, .OBJC_ASSOCIATION_RETAIN)
}
app.run()
