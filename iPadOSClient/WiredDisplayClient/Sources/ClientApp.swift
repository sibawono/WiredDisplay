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
    /// Diagnostics: the E-05 loopback echo on 127.0.0.1:9000, so cable
    /// throughput can be measured with `wd-usbmux-probe echo` without swapping
    /// apps (free teams cannot register more App IDs). Foreground only.
    private let echoLog = EventLog()
    private lazy var echo = EchoServer(events: echoLog)

    func activate() {
        ClientLog.write("app active")
        if session == nil {
            let session = ClientSession(model: connection, renderer: videoView.displayLayer.sampleBufferRenderer,
                                        hello: makeHello(), speakerSink: audio.speakerBuffer)
            videoView.onInput = { [weak session] event in session?.send(event) }
            audio.onMicrophone = { [weak session] packet in session?.sendMicrophone(packet) }
            audio.onError = { [weak self] message in self?.connection.lastError = message }
            audio.onStateChange = { [weak self, weak session] speaker, microphone in
                guard let self else { return }
                connection.speakerOn = speaker
                connection.microphoneOn = microphone
                session?.setAudioRoute(speaker: speaker, microphone: microphone)
            }
            session.onBrightness = { [weak self] value in self?.applyBrightness(value) }
            NotificationCenter.default.addObserver(forName: UIScreen.brightnessDidChangeNotification, object: nil,
                                                   queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.reportBrightness() }
            }
            self.session = session
            // Mac audio on the iPad speaker is on by default; the microphone is not.
            setAudio(speaker: true, microphone: false)
        }
        session?.setVideoActive(true)
        reportBrightness()
        session?.start()
        echo.start()
        UIApplication.shared.isIdleTimerDisabled = true
    }

    /// Leaving the foreground: with audio running, keep the session and pause
    /// video (D-018); otherwise end the session as before.
    func deactivate(reason: String) {
        ClientLog.write("app leaving foreground: \(reason) (audio active \(audio.isActive))")
        echo.stop(reason: "app not active")
        session?.send(.releaseAll)
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
        let native = screen?.nativeBounds.size ?? CGSize(width: 2048, height: 2732)
        // Landscape-first: the long side is the width.
        let width = UInt32(max(native.width, native.height))
        let height = UInt32(min(native.width, native.height))
        let scale = UInt8(clamping: Int((screen?.nativeScale ?? 2).rounded()))
        let refresh = UInt16(clamping: screen?.maximumFramesPerSecond ?? 60)
        // HEVC only where it is decoded in hardware (D-031); H.264 always.
        let codecs: CodecSet = VTIsHardwareDecodeSupported(kCMVideoCodecType_HEVC) ? [.h264, .hevc] : [.h264]
        return Hello(role: .client, deviceName: UIDevice.current.name, pixelWidth: width, pixelHeight: height,
                     scale: max(scale, 1), maxRefreshHz: max(refresh, 1), codecs: codecs,
                     pixelsPerInch: Self.pixelsPerInch())
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

            ControlsButton(streaming: connection.phase == .streaming) { showControls.toggle() }
                .popover(isPresented: $showControls) {
                    ControlsPanel(app: app, connection: connection)
                }
        }
        .background(.black)
        .statusBarHidden(true)
        .persistentSystemOverlays(.hidden)
        .defersSystemGestures(on: .all)
        .preferredColorScheme(.dark)
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
    }
}

/// Binds the controls panel to the live session.
struct ControlsPanel: View {
    let app: AppModel
    let connection: ConnectionModel
    /// BUG-035: on = video composited by the GPU (dithered) instead of a
    /// hardware overlay plane, which showed rings in smooth gradients.
    @AppStorage(VideoView.smoothGradientsKey) private var smoothGradients = true

    var body: some View {
        ControlsContent(
            summary: summary,
            speaker: Binding(get: { connection.speakerOn },
                             set: { app.setAudio(speaker: $0, microphone: connection.microphoneOn) }),
            microphone: Binding(get: { connection.microphoneOn }, set: { app.setMicrophone($0) }),
            smoothGradients: Binding(get: { smoothGradients },
                                     set: { smoothGradients = $0; app.videoView.smoothGradients = $0 }),
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
