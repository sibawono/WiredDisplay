import AVFoundation
import SwiftUI
import UIKit
import VideoToolbox
import WDSession

/// Owns the long-lived objects. Created once; the session is built on first
/// activation because the screen's size is only reliable once a scene exists.
@MainActor
final class AppModel {
    let connection = ConnectionModel()
    let videoView = VideoView(frame: .zero)
    let audio = ClientAudio()
    private(set) var session: ClientSession?
    private var sink: SwitchableSink?

    /// Experimental Metal renderer (D-040), remembered.
    func setMetalRenderer(_ on: Bool) {
        UserDefaults.standard.set(on, forKey: VideoView.metalRendererKey)
        let usable = on && videoView.metalRenderer != nil
        videoView.usesMetal = usable
        sink?.select(metal: usable)
        ClientLog.write("renderer: \(usable ? "Metal (experimental)" : "system display layer")")
    }
    /// Diagnostics: the E-05 loopback echo on 127.0.0.1:9000, so cable
    /// throughput can be measured with `wd-usbmux-probe echo` without swapping
    /// apps (free teams cannot register more App IDs). Foreground only.
    private let echoLog = EventLog()
    private lazy var echo = EchoServer(events: echoLog)
    /// Off unless asked for (audit C-7): launch with `-diagnosticEcho YES`
    /// (e.g. `xcrun devicectl device process launch … -- -diagnosticEcho YES`).
    private var echoEnabled: Bool { UserDefaults.standard.bool(forKey: "diagnosticEcho") }

    private var inBackground = false
    /// What the user turned on; a failed start clears `audio`'s state but not this.
    private var wantedAudio = (speaker: false, microphone: false)

    /// In the background the session lives only as long as audio does.
    private func audioInterrupted(began: Bool) {
        guard inBackground, audio.isActive else { return }
        if began {
            session?.stop(reason: "audio interrupted in the background")
        } else {
            session?.start()
        }
    }

    func activate() {
        ClientLog.write("app active")
        inBackground = false
        videoView.isHidden = false
        if session == nil {
            let sink = SwitchableSink(standard: DisplayLayerSink(videoView.displayLayer.sampleBufferRenderer),
                                      metal: videoView.metalRenderer)
            self.sink = sink
            // Metal is the default since the user found it better (D-040).
            setMetalRenderer(UserDefaults.standard.object(forKey: VideoView.metalRendererKey) as? Bool ?? true)
            let session = ClientSession(model: connection, renderer: sink,
                                        hello: makeHello(), speakerSink: audio.speakerBuffer)
            videoView.onInput = { [weak session] event in session?.send(event) }
            audio.onMicrophone = { [weak session] packet in session?.sendMicrophone(packet) }
            audio.onError = { [weak self] message in self?.connection.lastError = message }
            audio.onStateChange = { [weak self, weak session] speaker, microphone in
                guard let self else { return }
                connection.speakerOn = speaker
                connection.microphoneOn = microphone
                session?.setAudioRoute(speaker: speaker, microphone: microphone)
                // Without audio iPadOS suspends the app; an open listener would then accept and never answer.
                if inBackground, !speaker, !microphone { session?.stop(reason: "audio stopped in the background") }
            }
            // iPadOS snapshots the app for the switcher right after this; hide the Mac desktop first.
            NotificationCenter.default.addObserver(forName: UIScene.didEnterBackgroundNotification, object: nil,
                                                   queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.videoView.isHidden = true }
            }
            NotificationCenter.default.addObserver(forName: AVAudioSession.interruptionNotification, object: nil,
                                                   queue: .main) { [weak self] note in
                let began = (note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt)
                    == AVAudioSession.InterruptionType.began.rawValue
                MainActor.assumeIsolated { self?.audioInterrupted(began: began) }
            }
            session.onBrightness = { [weak self] value in self?.applyBrightness(value) }
            videoView.onShapeChange = { [weak self] portrait in self?.viewShapeChanged(portrait: portrait) }
            session.onCursor = { [weak self] x, y, visible in self?.videoView.setCursor(x: x, y: y, visible: visible) }
            session.onCursorImage = { [weak self] image in
                self?.videoView.setCursorImage(png: image.png, width: image.width, height: image.height,
                                               hotX: image.hotX, hotY: image.hotY)
            }
            NotificationCenter.default.addObserver(forName: UIScreen.brightnessDidChangeNotification, object: nil,
                                                   queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.reportBrightness() }
            }
            self.session = session
            // Mac audio on the iPad speaker is on by default; the microphone is not.
            setAudio(speaker: true, microphone: false)
        } else if !audio.isActive, wantedAudio.speaker || wantedAudio.microphone {
            // Audio that failed while away (another app held the audio session) comes back with the app.
            setAudio(speaker: wantedAudio.speaker, microphone: wantedAudio.microphone)
        }
        session?.setVideoActive(true)
        reportBrightness()
        session?.start()
        if echoEnabled { echo.start() }
        UIApplication.shared.isIdleTimerDisabled = true
    }

    /// Leaving the foreground: with audio running, keep the session and pause
    /// video (D-018); otherwise end the session as before.
    func deactivate(reason: String) {
        ClientLog.write("app leaving foreground: \(reason) (audio active \(audio.isActive))")
        if echoEnabled { echo.stop(reason: "app not active") }
        session?.send(.releaseAll)
        inBackground = true
        if audio.isActive {
            session?.setVideoActive(false)
        } else {
            session?.stop(reason: reason)
        }
        UIApplication.shared.isIdleTimerDisabled = false
    }

    // MARK: brightness (D-033)

    private var screen: UIScreen? {
        UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.screen }.first
    }
    /// The last value the Mac set, so applying it is not reported back as a
    /// user change (that echo made quick key presses jump back).
    private var appliedBrightness: Float?
    private var hudToken = 0

    private func applyBrightness(_ value: Float) {
        guard let screen else { return }
        appliedBrightness = value
        screen.brightness = CGFloat(value)
        hudToken += 1
        let token = hudToken
        connection.brightnessHUD = (value, token)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            guard let self, connection.brightnessHUD?.token == token else { return }
            connection.brightnessHUD = nil
        }
    }

    private func reportBrightness() {
        guard let screen else { return }
        let value = Float(screen.brightness)
        if let applied = appliedBrightness, abs(applied - value) < 0.01 { return }
        appliedBrightness = nil
        session?.sendBrightness(min(max(value, 0), 1))
    }

    func setAudio(speaker: Bool, microphone: Bool) {
        wantedAudio = (speaker, microphone)
        connection.speakerOn = speaker
        connection.microphoneOn = microphone
        // The route is sent from onStateChange once audio really runs (or fails).
        audio.apply(speaker: speaker, microphone: microphone)
        if !speaker && !microphone { session?.setAudioRoute(speaker: false, microphone: false) }
    }

    func setMicrophone(_ enabled: Bool) {
        guard enabled else { return setAudio(speaker: audio.speakerOn, microphone: false) }
        Task { @MainActor in
            if await ClientAudio.requestMicrophonePermission() {
                setAudio(speaker: audio.speakerOn, microphone: true)
            } else {
                connection.lastError = "Microphone permission denied (Settings › Privacy & Security › Microphone)"
                connection.microphoneOn = false
            }
        }
    }

    /// For the controls panel: what this iPad tells the Mac.
    var deviceInfo: DeviceInfo {
        let hello = makeHello()
        return DeviceInfo(model: Self.modelIdentifier(), panel: "\(hello.pixelWidth) × \(hello.pixelHeight) px",
                          pixelsPerInch: Int(hello.pixelsPerInch), maxRefreshHz: Int(hello.maxRefreshHz),
                          hevcHardware: hello.codecs.contains(VideoCodec.hevc))
    }

    private func makeHello() -> Hello {
        let screen = UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.screen }.first
        let (width, height) = Self.panelPixels(portrait: Self.isPortrait)
        let scale = UInt8(clamping: Int((screen?.nativeScale ?? 2).rounded()))
        let refresh = UInt16(clamping: screen?.maximumFramesPerSecond ?? 60)
        // HEVC only where it is decoded in hardware (D-031); H.264 always.
        let codecs: CodecSet = VTIsHardwareDecodeSupported(kCMVideoCodecType_HEVC) ? [.h264, .hevc] : [.h264]
        return Hello(role: .client, deviceName: UIDevice.current.name, pixelWidth: width, pixelHeight: height,
                     scale: max(scale, 1), maxRefreshHz: max(refresh, 1), codecs: codecs,
                     pixelsPerInch: Self.pixelsPerInch())
    }

    // MARK: orientation (D-039)

    static var isPortrait: Bool {
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        return scene?.effectiveGeometry.interfaceOrientation.isPortrait ?? false
    }

    /// Panel pixels in the given orientation (nativeBounds is portrait-up).
    static func panelPixels(portrait: Bool) -> (UInt32, UInt32) {
        let screen = UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.screen }.first
        let native = screen?.nativeBounds.size ?? CGSize(width: 2048, height: 2732)
        let long = UInt32(max(native.width, native.height)), short = UInt32(min(native.width, native.height))
        return portrait ? (short, long) : (long, short)
    }

    private var orientationWork: DispatchWorkItem?

    /// The view changed shape: after it settles, tell the Mac (rotation).
    func viewShapeChanged(portrait: Bool) {
        orientationWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                let (width, height) = Self.panelPixels(portrait: portrait)
                self?.session?.setPanelSize(width: width, height: height)
            }
        }
        orientationWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    /// iPad mini panels are 326 ppi; every other iPad on iPadOS 17+ is 264.
    /// Hardware model identifier, e.g. "iPad14,10".
    static func modelIdentifier() -> String {
        var info = utsname()
        uname(&info)
        return withUnsafeBytes(of: &info.machine) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
    }

    private static func pixelsPerInch() -> UInt16 {
        let model = modelIdentifier()
        // mini 5 (iPad11,1/2), mini 6 (iPad14,1/2), mini A17 Pro (iPad16,1/2).
        let minis: Set<String> = ["iPad11,1", "iPad11,2", "iPad14,1", "iPad14,2", "iPad16,1", "iPad16,2"]
        return minis.contains(model) ? 326 : 264
    }
}

@main
struct WiredDisplayClientApp: App {
    @State private var app = AppModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView(app: app, connection: app.connection)
                .onChange(of: scenePhase, initial: true) { _, phase in
                    switch phase {
                    case .active: app.activate()
                    case .background: app.deactivate(reason: "iPad app moved to background")
                    default: break
                    }
                }
        }
    }
}

struct RootView: View {
    let app: AppModel
    let connection: ConnectionModel
    @State private var showControls = false

    var body: some View {
        ZStack(alignment: .topTrailing) {
            VideoSurface(view: app.videoView, streamConfig: connection.streamConfig)
                .ignoresSafeArea()

            Group {
                if let code = connection.pairingCode {
                    ZStack {
                        Backdrop()
                        PairingScreen(macName: connection.macName, code: code) { accept in
                            app.session?.answerPairing(code: code, accept: accept)
                        }
                    }
                    .transition(.opacity.combined(with: .scale(scale: 0.98)))
                } else if connection.phase != .streaming {
                    ZStack {
                        Backdrop()
                        StatusScreen(info: statusInfo)
                    }
                    .transition(.opacity)
                }
            }
            .animation(.smooth(duration: 0.35), value: connection.pairingCode)
            .animation(.smooth(duration: 0.35), value: connection.phase)
            .animation(.easeOut(duration: 0.2), value: connection.brightnessHUD?.token)

            if let hud = connection.brightnessHUD {
                BrightnessHUD(value: hud.value)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .padding(.top, 28)
                    .transition(.opacity)
                    .allowsHitTesting(false)
            }

            GeometryReader { space in
                movableControls(in: space.size)
            }
        }
        .background(.black)
        .statusBarHidden(true)
        .persistentSystemOverlays(.hidden)
        .defersSystemGestures(on: .all)
        .preferredColorScheme(.dark)
    }

    /// Where the controls button sits: left or right edge (0 or 1) and height (0...1), remembered.
    @AppStorage("controlsEdgeX") private var controlsX = 1.0
    @AppStorage("controlsEdgeY") private var controlsY = 0.0
    @State private var controlsDrag = CGSize.zero
    @State private var controlsResting = false
    @State private var controlsTouched = 0
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOver
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// The button can be dragged anywhere and settles on the nearer side edge, so it can
    /// sit where it covers nothing the user is working on. A tap still opens the panel.
    private func movableControls(in space: CGSize) -> some View {
        let button = ControlsButton.footprint
        let range = CGSize(width: max(space.width - button, 0), height: max(space.height - button, 0))
        let origin = CGPoint(x: controlsX * range.width + controlsDrag.width, y: controlsY * range.height + controlsDrag.height)
        return ZStack(alignment: .topLeading) {
            if showControls {
                Color.black.opacity(0.25)
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture { showControls = false }
                    .accessibilityHidden(true)
                    .transition(.opacity)
                controlsPanel(in: space, buttonY: origin.y)
            }
            ControlsButton(streaming: connection.phase == .streaming, resting: controlsResting) {
                controlsTouched += 1
                showControls.toggle()
            }
            .offset(x: origin.x, y: origin.y)
            .highPriorityGesture(
                DragGesture(minimumDistance: 8)
                    .onChanged {
                        controlsDrag = $0.translation
                        controlsResting = false
                    }
                    .onEnded { drag in
                        let x = controlsX * range.width + drag.translation.width
                        let y = controlsY * range.height + drag.translation.height
                        withAnimation(reduceMotion ? nil : .snappy(duration: 0.25)) {
                            controlsX = x + button / 2 < space.width / 2 ? 0 : 1
                            controlsY = range.height > 0 ? min(max(y / range.height, 0), 1) : 0
                            controlsDrag = .zero
                        }
                        controlsTouched += 1
                    })
            // Fades out 4 s after the last touch while streaming and the panel is closed.
            .task(id: "\(controlsTouched) \(showControls) \(connection.phase == .streaming)") {
                controlsResting = false
                guard connection.phase == .streaming, !showControls, !voiceOver else { return }
                try? await Task.sleep(for: .seconds(4))
                guard !Task.isCancelled else { return }
                withAnimation(reduceMotion ? nil : .easeOut(duration: 0.6)) { controlsResting = true }
            }
            .accessibilityAction(named: "Move to the other side") { controlsX = controlsX < 0.5 ? 1 : 0 }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .animation(reduceMotion ? nil : .snappy(duration: 0.22), value: showControls)
    }

    /// The panel opens beside the button, on its side, and always fits on screen with a margin.
    /// It replaces the system popover, whose glass arrow and bottom edge clipped at the screen edge.
    private func controlsPanel(in space: CGSize, buttonY: CGFloat) -> some View {
        let width: CGFloat = 400, margin: CGFloat = 16, button = ControlsButton.footprint
        let height = max(min(700, space.height - 2 * margin), 0)
        let onRight = controlsX >= 0.5
        let x = min(max(onRight ? space.width - button - width : button, margin), max(space.width - width - margin, margin))
        let y = min(max(buttonY + button / 2 - height / 2, margin), max(space.height - height - margin, margin))
        let shape = RoundedRectangle(cornerRadius: 24, style: .continuous)
        return ControlsPanel(app: app, connection: connection)
            .frame(width: width, height: height)
            .background(Color(red: 0.05, green: 0.07, blue: 0.12), in: shape)
            .clipShape(shape)
            .overlay(shape.strokeBorder(.white.opacity(0.08)))
            .shadow(color: .black.opacity(0.4), radius: 24, y: 8)
            .background {
                // Escape on a hardware keyboard closes the panel.
                Button("Close") { showControls = false }
                    .keyboardShortcut(.cancelAction)
                    .hidden()
            }
            .accessibilityAddTraits(.isModal)
            .accessibilityAction(.escape) { showControls = false }
            .offset(x: x, y: y)
            .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: onRight ? .trailing : .leading)))
    }

    private var statusInfo: StatusInfo {
        let stage: StatusInfo.Stage
        switch connection.phase {
        case .starting, .streaming: stage = .starting
        case .waitingForMac: stage = .waitingForMac
        case .connecting: stage = .connecting
        case .failed(let reason): stage = .failed(reason)
        }
        return StatusInfo(stage: stage, macName: connection.macName, lastError: connection.lastError)
    }
}

/// Bridges the UIKit video view and keeps its stream size in sync.
struct VideoSurface: UIViewRepresentable {
    let view: VideoView
    let streamConfig: StreamConfig?

    func makeUIView(context: Context) -> VideoView { view }

    func updateUIView(_ uiView: VideoView, context: Context) {
        uiView.streamSize = streamConfig.map { CGSize(width: Int($0.pointWidth), height: Int($0.pointHeight)) }
        uiView.streamRefreshHz = streamConfig.map { Int($0.refreshHz) } ?? 0
        uiView.metalRenderer?.setStreamGeometry(streamConfig)
    }
}

/// Binds the controls panel to the live session.
struct ControlsPanel: View {
    let app: AppModel
    let connection: ConnectionModel
    /// BUG-035: on = video composited by the GPU (dithered) instead of a
    /// hardware overlay plane, which showed rings in smooth gradients.
    @AppStorage(VideoView.smoothGradientsKey) private var smoothGradients = true
    @AppStorage(VideoView.metalRendererKey) private var metalRenderer = true

    var body: some View {
        ControlsContent(
            summary: summary,
            speaker: Binding(get: { connection.speakerOn },
                             set: { app.setAudio(speaker: $0, microphone: connection.microphoneOn) }),
            microphone: Binding(get: { connection.microphoneOn }, set: { app.setMicrophone($0) }),
            smoothGradients: Binding(get: { smoothGradients },
                                     set: { smoothGradients = $0; app.videoView.smoothGradients = $0 }),
            metalRenderer: app.videoView.metalRenderer == nil ? nil
                : Binding(get: { metalRenderer }, set: { metalRenderer = $0; app.setMetalRenderer($0) }),
            pairedMacs: connection.pairedMacs.map { PairedMacRow(name: $0.name, fingerprint: $0.fingerprint) },
            forgetPaired: { app.session?.forgetPairedMacs() },
            reconnect: {
                app.deactivate(reason: "user reconnect")
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { app.activate() }
            },
            device: app.deviceInfo)
    }

    private var summary: SessionSummary {
        let config = connection.streamConfig
        return SessionSummary(
            macName: connection.macName,
            streaming: connection.phase == .streaming,
            logicalSize: config.map { "\($0.pointWidth) × \($0.pointHeight)" },
            detail: config.map { "\($0.pixelWidth) × \($0.pixelHeight) px · \($0.refreshHz) Hz · \($0.codec == .hevc ? "HEVC" : "H.264")" },
            framesShown: connection.framesShown,
            framesDropped: connection.framesDropped)
    }
}
