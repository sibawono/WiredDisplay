import SwiftUI

// Presentation for the iPad app. SwiftUI on plain values (UIKit only for font metrics, no
// session objects), so every state can be rendered and reviewed on its own.

extension Font {
    /// A design size that follows Dynamic Type, capped at 125 % so the Controls panel keeps its layout.
    /// At the default text size it is exactly `size`.
    static func wd(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: min(UIFontMetrics.default.scaledValue(for: size), size * 1.25), weight: weight)
    }
}

enum Brand {
    // Website studio-dark palette (site.css).
    static let bg = Color(red: 0.027, green: 0.035, blue: 0.047)           // #07090c
    static let tile = Color(red: 0.067, green: 0.082, blue: 0.106)         // #11151b
    static let tileElevated = Color(red: 0.094, green: 0.118, blue: 0.153) // #181e27
    static let hair = Color(red: 0.145, green: 0.176, blue: 0.224)         // #252d39
    static let text = Color(red: 0.953, green: 0.961, blue: 0.973)         // #f3f5f8
    static let muted = Color(red: 0.604, green: 0.643, blue: 0.698)        // #9aa4b2
    static let soft = Color(red: 0.706, green: 0.745, blue: 0.796)         // #b4becb

    static let blue = Color(red: 0.106, green: 0.431, blue: 0.761)         // #1b6ec2
    static let signal = Color(red: 0.322, green: 0.659, blue: 1.0)         // #52a8ff (video lane)
    static let laneAudio = Color(red: 0.749, green: 0.353, blue: 0.949)    // #bf5af2 (audio lane)
    static let laneInput = Color(red: 0.188, green: 0.820, blue: 0.345)    // #30d158 (input lane)
    static let secondaryText = muted
    static let action = blue
    static let tileGradient = LinearGradient(
        colors: [signal, blue, Color(red: 0.04, green: 0.32, blue: 0.88)],
        startPoint: .top, endPoint: .bottom
    )
}

/// Solid studio-dark backdrop matching the WiredDisplay product page.
struct Backdrop: View {
    var body: some View {
        Brand.bg.ignoresSafeArea()
    }
}

/// App icon tile used on pairing and header surfaces.
struct IconTile: View {
    var symbol: String?
    var size: CGFloat = 72

    var body: some View {
        Group {
            if let symbol {
                RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
                    .fill(Brand.tileGradient)
                    .overlay(
                        Image(systemName: symbol)
                            .font(.system(size: size * 0.44, weight: .medium))
                            .foregroundStyle(.white)
                    )
            } else {
                Image("AppIconArt")
                    .resizable()
                    .interpolation(.high)
                    .clipShape(RoundedRectangle(cornerRadius: size * 0.225, style: .continuous))
            }
        }
        .frame(width: size, height: size)
        .overlay(RoundedRectangle(cornerRadius: size * 0.225, style: .continuous).strokeBorder(.white.opacity(0.1)))
    }
}

// MARK: - Connection status

struct StatusInfo: Equatable {
    enum Stage: Equatable { case starting, waitingForMac, connecting, failed(String) }
    var stage: Stage
    var macName: String
    var activeTransport: String? = nil
    var wifiConnected: Bool = false
    var wifiName: String? = nil
    var lastError: String?
}

struct StatusScreen: View {
    let info: StatusInfo
    @AppStorage("wd.onboardingDone") private var onboardingDone = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var waitingSince = Date()
    @State private var appeared = false
    static let replugHintDelay: TimeInterval = 20

    private let iconGradient = LinearGradient(
        colors: [Brand.signal, Brand.laneAudio],
        startPoint: .topLeading, endPoint: .bottomTrailing
    )

    var body: some View {
        Group {
            if !onboardingDone {
                OnboardingView {
                    withAnimation(reduceMotion ? nil : .spring(response: 0.5, dampingFraction: 0.88)) {
                        onboardingDone = true
                    }
                }
                .transition(.opacity)
            } else {
                waitingHome
                    .transition(.opacity)
            }
        }
        .animation(.smooth, value: info)
        .onChange(of: info.stage, initial: true) { _, stage in
            if stage == .waitingForMac { waitingSince = Date() }
        }
    }

    private var waitingHome: some View {
        GeometryReader { geo in
            let wide = geo.size.width >= 760
            ScrollView {
                VStack(spacing: 0) {
                    Spacer(minLength: 24)

                    VStack(spacing: 28) {
                        // Hero section matching OnboardingView
                        VStack(spacing: 14) {
                            IconTile(size: 84)
                                .shadow(color: Brand.signal.opacity(0.22), radius: 22, y: 8)
                            Text(heroTitle)
                                .font(.system(size: wide ? 38 : 30, weight: .bold))
                                .tracking(-0.8)
                                .foregroundStyle(Brand.text)
                                .multilineTextAlignment(.center)
                            Text(heroSubtitle)
                                .font(.wd(17))
                                .foregroundStyle(Brand.muted)
                                .multilineTextAlignment(.center)
                                .frame(maxWidth: 540)

                            statusPill
                                .padding(.top, 2)
                        }
                        .opacity(appeared ? 1 : 0)
                        .offset(y: appeared ? 0 : 10)

                        // 3 cards matching OnboardingView's 1:1 square card layout
                        let cards = statusCards
                        if wide {
                            HStack(alignment: .top, spacing: 18) {
                                ForEach(Array(cards.enumerated()), id: \.offset) { idx, item in
                                    OnboardingFeatureCard(
                                        symbol: item.symbol,
                                        title: item.title,
                                        detail: item.detail,
                                        gradient: iconGradient,
                                        square: true,
                                        highlighted: item.highlighted,
                                        badge: item.badge
                                    )
                                    .opacity(appeared ? 1 : 0)
                                    .offset(y: appeared ? 0 : 14)
                                    .animation(reduceMotion ? nil : .spring(response: 0.55, dampingFraction: 0.86).delay(Double(idx) * 0.08), value: appeared)
                                }
                            }
                            .frame(maxWidth: 840)
                        } else {
                            VStack(spacing: 12) {
                                ForEach(Array(cards.enumerated()), id: \.offset) { idx, item in
                                    OnboardingFeatureCard(
                                        symbol: item.symbol,
                                        title: item.title,
                                        detail: item.detail,
                                        gradient: iconGradient,
                                        square: false,
                                        highlighted: item.highlighted,
                                        badge: item.badge
                                    )
                                    .opacity(appeared ? 1 : 0)
                                    .offset(y: appeared ? 0 : 12)
                                    .animation(reduceMotion ? nil : .spring(response: 0.55, dampingFraction: 0.86).delay(Double(idx) * 0.07), value: appeared)
                                }
                            }
                            .frame(maxWidth: 520)
                        }

                        TimelineView(.periodic(from: .now, by: 1)) { context in
                            if info.stage == .waitingForMac,
                               context.date.timeIntervalSince(waitingSince) >= Self.replugHintDelay {
                                ReplugHint()
                                    .frame(maxWidth: wide ? 840 : 520)
                                    .transition(.opacity.combined(with: .move(edge: .bottom)))
                            }
                        }

                        if let note {
                            Text(note)
                                .font(.wd(13))
                                .foregroundStyle(.orange)
                                .multilineTextAlignment(.center)
                                .frame(maxWidth: 600)
                        }

                        Button {
                            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.3)) {
                                onboardingDone = false
                            }
                        } label: {
                            Label("Overview", systemImage: "rectangle.stack")
                                .font(.wd(14, weight: .medium))
                                .foregroundStyle(Brand.soft)
                                .padding(.horizontal, 18)
                                .padding(.vertical, 10)
                                .background(Brand.tile, in: Capsule())
                                .overlay(Capsule().strokeBorder(Brand.hair))
                        }
                        .buttonStyle(.plain)
                        .opacity(appeared ? 1 : 0)
                    }
                    .padding(.horizontal, wide ? 40 : 24)

                    Spacer(minLength: 24)
                }
                .frame(minWidth: geo.size.width, minHeight: geo.size.height)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .onAppear {
            if reduceMotion { appeared = true }
            else { withAnimation(.spring(response: 0.6, dampingFraction: 0.86)) { appeared = true } }
        }
    }

    private var isConnectingWiFi: Bool {
        info.stage == .connecting && info.activeTransport == "Wi-Fi"
    }

    private var isConnectingUSB: Bool {
        info.stage == .connecting && info.activeTransport == "USB-C"
    }

    private var wifiLabel: String {
        if let ssid = info.wifiName, !ssid.isEmpty {
            return "Wi-Fi · \(ssid)"
        }
        return info.wifiConnected ? "Wi-Fi" : "Wi-Fi off"
    }

    private var heroTitle: String {
        switch info.stage {
        case .starting:
            return "Starting WiredDisplay…"
        case .waitingForMac:
            return "Ready to Connect"
        case .connecting:
            return info.macName.isEmpty ? "Connecting to Mac…" : "Connecting to \(info.macName)…"
        case .failed:
            return "Unable to Start"
        }
    }

    private var heroSubtitle: String {
        switch info.stage {
        case .starting:
            return "Preparing USB-C and encrypted local Wi-Fi listeners."
        case .waitingForMac:
            return "Plug in a USB-C cable or stay on the same local Wi-Fi network as your Mac."
        case .connecting:
            if isConnectingWiFi {
                if let ssid = info.wifiName, !ssid.isEmpty {
                    return "Establishing encrypted local Wi-Fi session on “\(ssid)”."
                }
                return "Establishing encrypted local Wi-Fi session with your Mac."
            } else if isConnectingUSB {
                return "Establishing encrypted USB-C session with your Mac."
            }
            return "Establishing encrypted session with your Mac."
        case .failed(let reason):
            return reason
        }
    }

    private var statusPill: some View {
        HStack(spacing: 8) {
            switch info.stage {
            case .failed:
                Image(systemName: "exclamationmark.circle.fill")
                    .font(.wd(12))
                    .foregroundStyle(.red)
            case .connecting, .starting:
                ProgressView().controlSize(.mini).tint(Brand.signal)
            case .waitingForMac:
                WaitingDot()
            }

            if info.stage == .connecting {
                Image(systemName: isConnectingWiFi ? "wifi" : "cable.connector")
                    .font(.wd(12, weight: .semibold))
                    .foregroundStyle(Brand.signal)
                Text(connectingPillText)
                    .font(.wd(13, weight: .medium))
                    .foregroundStyle(Brand.text)
            } else if info.stage == .waitingForMac {
                Text("Listening:")
                    .font(.wd(13, weight: .regular))
                    .foregroundStyle(Brand.muted)
                Image(systemName: "cable.connector")
                    .font(.wd(11, weight: .semibold))
                    .foregroundStyle(Brand.signal)
                Text("USB-C")
                    .font(.wd(13, weight: .medium))
                    .foregroundStyle(Brand.text)
                Text("·")
                    .foregroundStyle(Brand.muted)
                Image(systemName: info.wifiConnected ? "wifi" : "wifi.slash")
                    .font(.wd(11, weight: .semibold))
                    .foregroundStyle(info.wifiConnected ? Brand.signal : Brand.muted)
                Text(wifiLabel)
                    .font(.wd(13, weight: .medium))
                    .foregroundStyle(info.wifiConnected ? Brand.text : Brand.muted)
            } else if info.stage == .starting {
                Text("Starting listeners…")
                    .font(.wd(13, weight: .medium))
                    .foregroundStyle(Brand.muted)
            } else {
                Text("Listener stopped")
                    .font(.wd(13, weight: .medium))
                    .foregroundStyle(.red)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
        .background(Brand.tileElevated, in: Capsule())
        .overlay(
            Capsule().strokeBorder(
                info.stage == .connecting ? Brand.signal.opacity(0.6)
                    : (info.stage == .waitingForMac ? Brand.hair : .red.opacity(0.45))
            )
        )
    }

    private var connectingPillText: String {
        if isConnectingWiFi {
            if let ssid = info.wifiName, !ssid.isEmpty {
                return "Connecting via Wi-Fi · \(ssid)"
            }
            return "Connecting via Wi-Fi"
        }
        if isConnectingUSB {
            return "Connecting via USB-C"
        }
        return "Connecting…"
    }

    private struct StatusCardItem {
        let symbol: String
        let title: String
        let detail: String
        let highlighted: Bool
        let badge: String?
    }

    private var statusCards: [StatusCardItem] {
        let connectSymbol: String
        let connectTitle: String
        let connectDetail: String
        let connectBadge: String?

        if isConnectingUSB {
            connectSymbol = "cable.connector"
            connectTitle = "Connecting via USB-C"
            connectDetail = "Wired USB-C link active for lowest latency and full Retina clarity."
            connectBadge = "USB-C"
        } else if isConnectingWiFi {
            connectSymbol = "wifi"
            connectTitle = "Connecting via Wi-Fi"
            if let ssid = info.wifiName, !ssid.isEmpty {
                connectDetail = "Connected to “\(ssid)”. Streaming over encrypted local Wi-Fi."
                connectBadge = "Wi-Fi · \(ssid)"
            } else {
                connectDetail = "Local Wi-Fi link active. Streaming over encrypted local network."
                connectBadge = "Wi-Fi"
            }
        } else {
            connectSymbol = "display.2"
            connectTitle = "01 · USB-C or Wi-Fi"
            connectDetail = "Plug in a USB-C cable for lowest latency, or stay on the same local Wi-Fi network as your Mac."
            connectBadge = info.wifiConnected ? "USB-C · \(wifiLabel)" : "USB-C ready"
        }

        return [
            StatusCardItem(
                symbol: connectSymbol,
                title: connectTitle,
                detail: connectDetail,
                highlighted: info.stage == .connecting,
                badge: connectBadge
            ),
            StatusCardItem(
                symbol: "menubar.rectangle",
                title: "02 · Mac menu bar",
                detail: "Open WiredDisplay on your Mac and pick USB-C, Auto, or Wi-Fi in the General tab.",
                highlighted: false,
                badge: "USB-C · Auto · Wi-Fi"
            ),
            StatusCardItem(
                symbol: "lock.shield",
                title: "03 · Pair once",
                detail: "Pair over the USB-C cable once and confirm the 6-digit code; Wi-Fi then works for that Mac. Video, audio, and input stay encrypted with AES-256-GCM.",
                highlighted: false,
                badge: "AES-256-GCM"
            ),
        ]
    }

    private var note: String? {
        if case .failed = info.stage { return nil }
        guard info.stage == .waitingForMac, let error = info.lastError, !error.isEmpty else { return nil }
        return "Last session: \(error)"
    }
}

// MARK: - Onboarding (first launch)

private struct OnboardingView: View {
    let onFinish: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var appeared = false

    private let iconGradient = LinearGradient(
        colors: [Brand.signal, Brand.laneAudio],
        startPoint: .topLeading, endPoint: .bottomTrailing
    )

    var body: some View {
        GeometryReader { geo in
            let wide = geo.size.width >= 760
            VStack(spacing: 0) {
                Spacer(minLength: 24)

                VStack(spacing: 28) {
                    VStack(spacing: 14) {
                        IconTile(size: 84)
                            .shadow(color: Brand.signal.opacity(0.22), radius: 22, y: 8)
                        Text("Welcome to WiredDisplay")
                            .font(.system(size: wide ? 38 : 30, weight: .bold))
                            .tracking(-0.8)
                            .foregroundStyle(Brand.text)
                            .multilineTextAlignment(.center)
                        Text("Use your iPad as a Retina Mac display over USB-C or encrypted local Wi-Fi.")
                            .font(.wd(17))
                            .foregroundStyle(Brand.muted)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: 540)
                    }
                    .opacity(appeared ? 1 : 0)
                    .offset(y: appeared ? 0 : 10)

                    // 3 feature cards matching the website's outlined gradient-icon card style
                    let cards: [(symbol: String, title: String, body: String)] = [
                        ("display.2", "USB-C or local Wi-Fi",
                         "Plug in a USB-C cable for lowest latency, or switch to encrypted local Wi-Fi when you want to move freely."),
                        ("speaker.wave.2", "Mac + iPad speakers together",
                         "Stream system audio to your iPad or play both speakers in sync, with 240 Hz Apple Pencil, touch, and keyboard."),
                        ("lock.shield", "Private and encrypted",
                         "Pair once with a 6-digit code. Video, audio, and input stay on your cable or local network with AES-256-GCM."),
                    ]

                    if wide {
                        HStack(alignment: .top, spacing: 18) {
                            ForEach(Array(cards.enumerated()), id: \.offset) { idx, item in
                                OnboardingFeatureCard(symbol: item.symbol, title: item.title, detail: item.body,
                                                      gradient: iconGradient, square: true)
                                    .opacity(appeared ? 1 : 0)
                                    .offset(y: appeared ? 0 : 14)
                                    .animation(reduceMotion ? nil : .spring(response: 0.55, dampingFraction: 0.86).delay(Double(idx) * 0.08), value: appeared)
                            }
                        }
                        .frame(maxWidth: 840)
                    } else {
                        VStack(spacing: 12) {
                            ForEach(Array(cards.enumerated()), id: \.offset) { idx, item in
                                OnboardingFeatureCard(symbol: item.symbol, title: item.title, detail: item.body,
                                                      gradient: iconGradient, square: false)
                                    .opacity(appeared ? 1 : 0)
                                    .offset(y: appeared ? 0 : 12)
                                    .animation(reduceMotion ? nil : .spring(response: 0.55, dampingFraction: 0.86).delay(Double(idx) * 0.07), value: appeared)
                            }
                        }
                        .frame(maxWidth: 520)
                    }

                    Button(action: onFinish) {
                        Text("Start Connecting")
                            .font(.wd(16, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(minWidth: 220, minHeight: 48)
                            .background(Brand.blue, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .padding(.top, 4)
                    .opacity(appeared ? 1 : 0)
                }
                .padding(.horizontal, wide ? 40 : 24)

                Spacer(minLength: 24)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onAppear {
            if reduceMotion { appeared = true }
            else { withAnimation(.spring(response: 0.6, dampingFraction: 0.86)) { appeared = true } }
        }
    }
}

private struct OnboardingFeatureCard: View {
    let symbol: String
    let title: String
    let detail: String
    let gradient: LinearGradient
    let square: Bool
    var highlighted: Bool = false
    var badge: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 36, weight: .light))
                .foregroundStyle(gradient)
                .frame(height: 42)

            VStack(alignment: .leading, spacing: 8) {
                Text(title)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(Brand.text)
                    .fixedSize(horizontal: false, vertical: true)
                Text(detail)
                    .font(.wd(14, weight: .regular))
                    .lineSpacing(3)
                    .foregroundStyle(Brand.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if square { Spacer(minLength: 0) }
            if let badge, !badge.isEmpty {
                Text(badge)
                    .font(.wd(11.5, weight: .medium))
                    .foregroundStyle(highlighted ? Brand.signal : Brand.soft)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(
                        highlighted ? Brand.signal.opacity(0.14) : Brand.tileElevated,
                        in: Capsule()
                    )
                    .overlay(
                        Capsule().strokeBorder(highlighted ? Brand.signal.opacity(0.45) : Brand.hair)
                    )
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .modifier(SquareAspectModifier(enabled: square))
        .background(Brand.tile, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .strokeBorder(highlighted ? Brand.signal.opacity(0.65) : Brand.hair, lineWidth: highlighted ? 1.5 : 1)
        )
    }
}

private struct SquareAspectModifier: ViewModifier {
    let enabled: Bool
    func body(content: Content) -> some View {
        if enabled {
            content.aspectRatio(1, contentMode: .fit)
        } else {
            content
        }
    }
}

/// Shown after a while without a Mac: covers both USB-C replug and Wi-Fi mode check.
private struct ReplugHint: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Not connecting yet?")
                .font(.wd(14, weight: .medium))
                .foregroundStyle(Brand.text)
            Text("If the Mac restarted, replug the USB-C cable. For Wi-Fi, set Connection to Auto or Wi-Fi in the Mac menu bar.")
                .font(.wd(13))
                .foregroundStyle(Brand.muted)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Brand.tileElevated, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Brand.hair))
    }
}

private struct WaitingDot: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var dim = false

    var body: some View {
        Circle()
            .fill(Brand.signal)
            .opacity(dim ? 0.35 : 1.0)
            .frame(width: 7, height: 7)
            .accessibilityHidden(true)
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.easeInOut(duration: 1.4).repeatForever(autoreverses: true)) {
                    dim = true
                }
            }
    }
}

// MARK: - Pairing

struct PairingScreen: View {
    let macName: String
    let code: String
    let answer: (Bool) -> Void

    var body: some View {
        VStack(spacing: 26) {
            IconTile(symbol: "lock.shield.fill", size: 84)
            VStack(spacing: 8) {
                Text("Pair with \(macName.isEmpty ? "this Mac" : "“\(macName)”")?")
                    .font(.system(size: 30, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                Text("Check that the WiredDisplay menu on the Mac shows the same code.")
                    .font(.body)
                    .foregroundStyle(.white.opacity(0.65))
                    .multilineTextAlignment(.center)
            }
            CodeView(code: code)
            Label("A paired Mac shows its screen here and receives this iPad’s touch, keyboard and microphone input.",
                  systemImage: "info.circle")
                .font(.footnote)
                .foregroundStyle(.white.opacity(0.5))
                .multilineTextAlignment(.leading)
                .frame(maxWidth: 440)
            HStack(spacing: 14) {
                Button { answer(false) } label: {
                    Text("Don’t Pair").frame(maxWidth: .infinity)
                }
                .buttonStyle(FilledButtonStyle(fill: .white.opacity(0.12)))
                Button { answer(true) } label: {
                    Text("Pair").fontWeight(.semibold).frame(maxWidth: .infinity)
                }
                .buttonStyle(FilledButtonStyle(fill: Brand.action))
                .keyboardShortcut(.defaultAction)
            }
            .frame(maxWidth: 440)
        }
        .padding(44)
        .frame(maxWidth: 600)
        .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 32, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 32, style: .continuous).strokeBorder(.white.opacity(0.1)))
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// "123 456" as two groups of digit cells.
private struct CodeView: View {
    let code: String

    var body: some View {
        let groups = code.split(separator: " ").map(String.init)
        HStack(spacing: 22) {
            ForEach(Array(groups.enumerated()), id: \.offset) { _, group in
                HStack(spacing: 8) {
                    ForEach(Array(group.enumerated()), id: \.offset) { _, digit in
                        Text(String(digit))
                            .font(.system(size: 44, weight: .semibold, design: .rounded).monospacedDigit())
                            .foregroundStyle(.white)
                            .frame(width: 56, height: 72)
                            .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Brand.blue.opacity(0.5)))
                    }
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Pairing code \(code)")
    }
}

// MARK: - Controls panel

struct SessionSummary: Equatable {
    var macName: String
    var streaming: Bool
    var activeTransport: String = "USB-C"
    var logicalSize: String?   // "1788 × 1340"
    var detail: String?        // "3180 × 2384 px · 60 Hz · HEVC"
    var framesShown: Int
    var framesDropped: Int
    var liveFPS: Int = 0
    var liveLatencyMs: Double? = nil
    var lastError: String? = nil
}

struct PairedMacRow: Identifiable, Equatable {
    var id: String { fingerprint }
    var name: String
    var fingerprint: String
}

/// What this iPad reports to the Mac (D-031), shown under "This iPad".
struct DeviceInfo: Equatable {
    var model: String
    var panel: String
    var pixelsPerInch: Int
    var maxRefreshHz: Int
    var hevcHardware: Bool
}

/// One-tap macOS shortcuts sent from the iPad Input tab (works without a hardware keyboard).
enum QuickAction: String, CaseIterable, Identifiable {
    case spotlight, missionControl, appSwitch, screenshot, dock, lockMac
    var id: String { rawValue }

    var title: String {
        switch self {
        case .spotlight: return "Spotlight"
        case .missionControl: return "Mission Ctrl"
        case .appSwitch: return "Switch App"
        case .screenshot: return "Screenshot"
        case .dock: return "Show Dock"
        case .lockMac: return "Lock Mac"
        }
    }

    var symbol: String {
        switch self {
        case .spotlight: return "magnifyingglass"
        case .missionControl: return "rectangle.3.group"
        case .appSwitch: return "square.on.square"
        case .screenshot: return "camera.viewfinder"
        case .dock: return "dock.rectangle"
        case .lockMac: return "lock.fill"
        }
    }

    /// USB HID keyboard usages (page 0x07), pressed in order and released in reverse.
    var usages: [UInt16] {
        switch self {
        case .spotlight: return [0xE3, 0x2C]         // ⌘ Space
        case .missionControl: return [0xE0, 0x52]    // ⌃ ↑
        case .appSwitch: return [0xE3, 0x2B]         // ⌘ Tab
        case .screenshot: return [0xE3, 0xE1, 0x22]  // ⌘ ⇧ 5
        case .dock: return [0xE3, 0xE2, 0x07]        // ⌘ ⌥ D
        case .lockMac: return [0xE0, 0xE3, 0x14]     // ⌃ ⌘ Q
        }
    }
}

struct ControlsContent: View {
    enum Tab: String, CaseIterable, Identifiable {
        case display, audio, input, more
        var id: String { rawValue }
        var title: String {
            switch self {
            case .display: return "Display"
            case .audio: return "Audio"
            case .input: return "Input"
            case .more: return "More"
            }
        }
        var symbol: String {
            switch self {
            case .display: return "display"
            case .audio: return "speaker.wave.2"
            case .input: return "pencil.and.scribble"
            case .more: return "gearshape"
            }
        }
    }

    let summary: SessionSummary
    @Binding var displaySpace: Int
    @Binding var qualityPreset: Int
    @Binding var brightness: Double
    @Binding var showStatsHUD: Bool
    @Binding var speaker: Bool
    @Binding var microphone: Bool
    @Binding var macVolume: Double
    @Binding var macMuted: Bool
    @Binding var smoothGradients: Bool
    var metalRenderer: Binding<Bool>? = nil
    @Binding var pencilAction: PencilAction
    var quickAction: (QuickAction) -> Void = { _ in }
    var showKeyboard: () -> Void = {}
    var sleepMac: () -> Void = {}
    let pairedMacs: [PairedMacRow]
    let forgetPaired: () -> Void
    var onBiometricKeyChanged: ([UInt8]) -> Void = { _ in }
    let reconnect: () -> Void
    var close: () -> Void = {}
    var device: DeviceInfo? = nil

    @State private var tab: Tab = .display
    @State private var confirmForget = false
    @State private var confirmSleep = false
    @State private var showGestures = false
    @State private var showShortcuts = false
    @State private var biometricFingerprint: String? = BiometricAuthKey.publicKey().map(BiometricAuthKey.fingerprint(of:))
    @State private var biometricError: String? = nil

    private static let qualityTitles = ["Balanced", "Pro", "Ultra", "High"]
    private static let qualityDetails = [
        "4:2:0 while moving, 4:4:4 when still · 10-bit",
        "Lowest latency 4:2:0 · 10-bit",
        "Sharpest 4:4:4 colour · 10-bit",
        "High Color: full 4:4:4 colour · 8-bit",
    ]

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal, 16)
                .padding(.top, 16)
                .padding(.bottom, 12)
            tabBar
                .padding(.horizontal, 16)
                .padding(.bottom, 10)
            Divider().overlay(.white.opacity(0.08))
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    switch tab {
                    case .display: displayTab
                    case .audio: audioTab
                    case .input: inputTab
                    case .more: moreTab
                    }
                }
                .padding(16)
            }
            Divider().overlay(.white.opacity(0.08))
            footer
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
        }
    }

    // MARK: header, tabs, footer

    private var header: some View {
        HStack(spacing: 12) {
            IconTile(size: 38)
            VStack(alignment: .leading, spacing: 3) {
                Text(summary.macName.isEmpty ? "WiredDisplay" : summary.macName)
                    .font(.headline)
                    .lineLimit(1)
                StatusPill(streaming: summary.streaming, transport: summary.activeTransport)
            }
            Spacer(minLength: 0)
            Button(action: close) {
                Image(systemName: "xmark")
                    .font(.wd(12, weight: .bold))
                    .foregroundStyle(.white.opacity(0.75))
                    .frame(width: 28, height: 28)
                    .background(.white.opacity(0.1), in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close controls")
        }
    }

    private var tabBar: some View {
        HStack(spacing: 6) {
            ForEach(Tab.allCases) { item in
                let selected = tab == item
                Button { tab = item } label: {
                    VStack(spacing: 4) {
                        Image(systemName: item.symbol)
                            .font(.wd(14, weight: selected ? .semibold : .regular))
                        Text(item.title)
                            .font(.wd(10.5, weight: selected ? .semibold : .medium))
                    }
                    .foregroundStyle(selected ? .white : .white.opacity(0.6))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .background(selected ? Brand.blue.opacity(0.28) : .white.opacity(0.04),
                                in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .strokeBorder(selected ? Brand.blue.opacity(0.6) : .white.opacity(0.06)))
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
    }

    private var footer: some View {
        Button(action: reconnect) {
            Label("Reconnect", systemImage: "arrow.clockwise")
                .font(.subheadline.weight(.semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(Brand.action, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .foregroundStyle(.white)
        }
        .buttonStyle(.plain)
    }

    // MARK: tabs

    private var displayTab: some View {
        Group {
            if let size = summary.logicalSize {
                card {
                    InfoRow(symbol: "rectangle.on.rectangle", title: "Looks like \(size)", value: nil)
                    if let detail = summary.detail {
                        InfoRow(symbol: "dial.medium", title: detail, value: nil, secondary: true)
                    }
                    if summary.streaming {
                        let fpsText = summary.liveFPS > 0 ? "\(summary.liveFPS) fps" : "—"
                        let latText = summary.liveLatencyMs.map { String(format: " · %.1f ms", $0) } ?? ""
                        InfoRow(symbol: "speedometer", title: "Live stream",
                                value: "\(fpsText)\(latText)", secondary: true)
                    }
                }
            }
            card("Display Space") {
                Picker("Display Space", selection: $displaySpace) {
                    Text("Default").tag(0)
                    Text("More").tag(1)
                    Text("Most").tag(2)
                }
                .pickerStyle(.segmented)
                .disabled(!summary.streaming)
                Text("Adjusts macOS UI scaling on this iPad.")
                    .font(.caption).foregroundStyle(Brand.secondaryText)
            }
            card("Quality") {
                Picker("Quality", selection: $qualityPreset) {
                    ForEach(0..<Self.qualityTitles.count, id: \.self) { idx in
                        Text(Self.qualityTitles[idx]).tag(idx)
                    }
                }
                .pickerStyle(.segmented)
                .disabled(!summary.streaming)
                if Self.qualityDetails.indices.contains(qualityPreset) {
                    Text(Self.qualityDetails[qualityPreset])
                        .font(.caption).foregroundStyle(Brand.secondaryText)
                }
            }
            card("Brightness") {
                HStack(spacing: 10) {
                    Image(systemName: "sun.min.fill")
                        .font(.caption)
                        .foregroundStyle(Brand.secondaryText)
                    Slider(value: $brightness, in: 0...1)
                        .tint(Brand.blue)
                    Image(systemName: "sun.max.fill")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.85))
                    Text("\(Int((brightness * 100).rounded()))%")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(Brand.secondaryText)
                        .frame(width: 34, alignment: .trailing)
                }
            }
            card("Renderer & HUD") {
                ToggleRow(symbol: "gauge.with.dots.needle.67percent", title: "Live stats HUD",
                          detail: "Show FPS and latency in the corner.", isOn: $showStatsHUD)
                if let metalRenderer {
                    Divider().overlay(.white.opacity(0.08))
                    ToggleRow(symbol: "bolt.horizontal", title: "Metal renderer",
                              detail: "Lower latency GPU path.", isOn: metalRenderer)
                    if !metalRenderer.wrappedValue {
                        Divider().overlay(.white.opacity(0.08))
                        ToggleRow(symbol: "circle.lefthalf.filled", title: "Smooth gradients",
                                  detail: "GPU dithering for the system video layer.", isOn: $smoothGradients)
                    }
                } else {
                    Divider().overlay(.white.opacity(0.08))
                    ToggleRow(symbol: "circle.lefthalf.filled", title: "Smooth gradients",
                              detail: "GPU dithering against banding.", isOn: $smoothGradients)
                }
            }
        }
    }

    private var audioTab: some View {
        Group {
            card("Mac Volume") {
                HStack(spacing: 10) {
                    Button { macMuted.toggle() } label: {
                        Image(systemName: macMuted || macVolume < 0.01 ? "speaker.slash.fill" : "speaker.wave.2.fill")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(macMuted ? .orange : .white)
                            .frame(width: 30, height: 30)
                            .background((macMuted ? Color.orange.opacity(0.2) : .white.opacity(0.1)), in: Circle())
                    }
                    .buttonStyle(.plain)
                    .disabled(!summary.streaming)
                    .accessibilityLabel(macMuted ? "Unmute Mac" : "Mute Mac")
                    Slider(value: $macVolume, in: 0...1)
                        .tint(macMuted ? .secondary : Brand.blue)
                        .disabled(!summary.streaming)
                    Text(macMuted ? "Mute" : "\(Int((macVolume * 100).rounded()))%")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(macMuted ? .orange : Brand.secondaryText)
                        .frame(width: 36, alignment: .trailing)
                }
            }
            card("iPad Audio") {
                ToggleRow(symbol: "speaker.wave.2.fill", title: "Mac audio on iPad",
                          detail: "Plays Mac sound through this iPad.", isOn: $speaker)
                Divider().overlay(.white.opacity(0.08))
                ToggleRow(symbol: "mic.fill", title: "iPad microphone to Mac",
                          detail: "Uses echo cancellation while active.", isOn: $microphone)
                if microphone {
                    Label("Live: choose “iPad Microphone” on the Mac", systemImage: "waveform")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.orange)
                        .padding(.leading, 34)
                }
                if let error = summary.lastError, !error.isEmpty {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 2)
                }
            }
            card {
                Label("Tip: turn on “Play on Mac speakers too” in the Mac menu bar to use both speakers together with sync & balance.",
                      systemImage: "hifispeaker.2")
                    .font(.caption)
                    .foregroundStyle(Brand.secondaryText)
            }
        }
    }

    private var inputTab: some View {
        Group {
            card("On-Screen Keyboard") {
                Button(action: showKeyboard) {
                    Label("Show Keyboard", systemImage: "keyboard.fill")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(Brand.blue.opacity(0.28), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous)
                            .strokeBorder(Brand.blue.opacity(0.6)))
                }
                .buttonStyle(.plain)
                .disabled(!summary.streaming)
                .opacity(summary.streaming ? 1 : 0.45)
                Text("Includes Esc, Tab, and arrow keys for typing without a hardware keyboard.")
                    .font(.caption).foregroundStyle(Brand.secondaryText)
            }
            card("Quick Actions") {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 8),
                                    GridItem(.flexible(), spacing: 8),
                                    GridItem(.flexible(), spacing: 8)], spacing: 8) {
                    ForEach(QuickAction.allCases) { action in
                        Button { quickAction(action) } label: {
                            VStack(spacing: 5) {
                                Image(systemName: action.symbol)
                                    .font(.wd(15, weight: .medium))
                                Text(action.title)
                                    .font(.wd(10.5, weight: .medium))
                                    .lineLimit(1)
                            }
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                            .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(.white.opacity(0.08)))
                        }
                        .buttonStyle(.plain)
                        .disabled(!summary.streaming)
                        .opacity(summary.streaming ? 1 : 0.45)
                    }
                }
                Divider().overlay(.white.opacity(0.08))
                Button { confirmSleep = true } label: {
                    Label("Sleep Mac", systemImage: "moon.zzz.fill")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(Color.indigo.opacity(0.32), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous)
                            .strokeBorder(Color.indigo.opacity(0.65)))
                }
                .buttonStyle(.plain)
                .disabled(!summary.streaming)
                .opacity(summary.streaming ? 1 : 0.45)
                .confirmationDialog("Put Mac to sleep?", isPresented: $confirmSleep) {
                    Button("Sleep Mac", role: .destructive, action: sleepMac)
                } message: {
                    Text("USB display will disconnect until the Mac is woken from a keyboard, power button, or Wake-on-LAN.")
                }
            }
            card("Apple Pencil") {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Double-tap / Squeeze")
                        .font(.subheadline.weight(.medium))
                    Picker("Apple Pencil action", selection: $pencilAction) {
                        ForEach(PencilAction.allCases, id: \.self) { action in
                            Text(action.title).tag(action)
                        }
                    }
                    .pickerStyle(.segmented)
                    Text("Direct click, drag, hover, pressure sensitivity, and palm rejection are always active.")
                        .font(.caption).foregroundStyle(Brand.secondaryText)
                }
            }
            card {
                DisclosureGroup(isExpanded: $showShortcuts) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Use Control instead of Command for shortcuts iPadOS reserves:")
                            .font(.caption).foregroundStyle(Brand.secondaryText)
                        ShortcutRow(keys: "⌃ Tab", mac: "⌘ Tab", action: "Switch apps")
                        ShortcutRow(keys: "⌃ `", mac: "⌘ `", action: "App windows")
                        ShortcutRow(keys: "⌃ Space", mac: "⌘ Space", action: "Spotlight")
                        ShortcutRow(keys: "⌃ H", mac: "⌘ H", action: "Hide app")
                        ShortcutRow(keys: "⌃ ⌥ D", mac: "⌘ ⌥ D", action: "Dock")
                        ShortcutRow(keys: "⌃ ⌥ ⎋", mac: "⌘ ⌥ ⎋", action: "Force Quit")
                        ShortcutRow(keys: "⌃ ⇧ 3/4/5", mac: "⌘ ⇧ 3/4/5", action: "Screenshot")
                    }
                    .padding(.top, 8)
                } label: {
                    Label("Keyboard shortcuts", systemImage: "keyboard").font(.subheadline.weight(.medium))
                }
                .tint(.primary)
                Divider().overlay(.white.opacity(0.08))
                DisclosureGroup(isExpanded: $showGestures) {
                    VStack(alignment: .leading, spacing: 8) {
                        GestureRow(symbol: "hand.tap", gesture: "Tap", action: "Click")
                        GestureRow(symbol: "hand.draw", gesture: "Drag", action: "Scroll")
                        GestureRow(symbol: "hand.point.up.left", gesture: "Hold, then drag", action: "Select · move")
                        GestureRow(symbol: "hand.tap", gesture: "Two-finger tap", action: "Right click")
                        GestureRow(symbol: "arrow.up.left.and.arrow.down.right", gesture: "Pinch / Rotate", action: "Zoom · rotate")
                        GestureRow(symbol: "hand.pinch", gesture: "Three-finger pinch", action: "Copy · paste")
                        GestureRow(symbol: "arrow.uturn.backward", gesture: "Three-finger swipe", action: "Undo · redo")
                    }
                    .padding(.top, 8)
                } label: {
                    Label("Touch gestures", systemImage: "hand.raised.fingers.spread").font(.subheadline.weight(.medium))
                }
                .tint(.primary)
            }
            Text("Requires “Allow Input from iPad” in the Mac menu bar.")
                .font(.caption).foregroundStyle(Brand.secondaryText)
                .padding(.horizontal, 4)
        }
    }

    private var moreTab: some View {
        let bioKind = BiometricAuthKey.biometryKind
        return Group {
            card("Mac \(bioKind.label) Auth") {
                if let fp = biometricFingerprint {
                    InfoRow(symbol: bioKind.symbol, title: "\(bioKind.label) enrolled", value: String(fp.prefix(8)))
                    Text("Approve sudo or Mac Lock Screen using \(bioKind.label). Run Install Extras on the Mac to link this key.")
                        .font(.caption).foregroundStyle(Brand.secondaryText)
                    Divider().overlay(.white.opacity(0.08))
                    HStack(spacing: 12) {
                        Button("Re-enroll Key") {
                            do {
                                let pub = try BiometricAuthKey.enroll()
                                biometricFingerprint = BiometricAuthKey.fingerprint(of: pub)
                                biometricError = nil
                                onBiometricKeyChanged(pub)
                            } catch {
                                biometricError = error.localizedDescription
                            }
                        }
                        .font(.subheadline)
                        Spacer()
                        Button("Remove", role: .destructive) {
                            BiometricAuthKey.delete()
                            biometricFingerprint = nil
                            biometricError = nil
                        }
                        .font(.subheadline)
                    }
                } else {
                    Text("Use this iPad’s \(bioKind.label) (Secure Enclave) to approve sudo and unlock your Mac without storing your Mac password.")
                        .font(.caption).foregroundStyle(Brand.secondaryText)
                    Button {
                        do {
                            let pub = try BiometricAuthKey.enroll()
                            biometricFingerprint = BiometricAuthKey.fingerprint(of: pub)
                            biometricError = nil
                            onBiometricKeyChanged(pub)
                        } catch {
                            biometricError = error.localizedDescription
                        }
                    } label: {
                        Label("Enroll \(bioKind.label) Key", systemImage: bioKind.symbol)
                            .font(.subheadline.weight(.medium))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 6)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(bioKind == .unavailable)
                }
                if let err = biometricError {
                    Text(err).font(.caption).foregroundStyle(.orange)
                }
            }
            card("Paired Macs") {
                if pairedMacs.isEmpty {
                    InfoRow(symbol: "lock.open", title: "No paired Mac", value: nil, secondary: true)
                } else {
                    ForEach(pairedMacs) { mac in
                        InfoRow(symbol: "lock.shield.fill", title: mac.name, value: String(mac.fingerprint.prefix(8)))
                    }
                    Divider().overlay(.white.opacity(0.08))
                    Button("Forget Paired Macs…", role: .destructive) { confirmForget = true }
                        .font(.subheadline)
                        .confirmationDialog("Forget all paired Macs?", isPresented: $confirmForget) {
                            Button("Forget", role: .destructive, action: forgetPaired)
                        } message: {
                            Text("The next Mac that connects must be paired again with a code.")
                        }
                }
            }
            if let device {
                card("This iPad") {
                    InfoRow(symbol: "ipad.landscape", title: "Model", value: device.model, secondary: true)
                    InfoRow(symbol: "square.resize", title: "Panel", value: device.panel, secondary: true)
                    InfoRow(symbol: "circle.grid.3x3", title: "Density", value: "\(device.pixelsPerInch) ppi", secondary: true)
                    InfoRow(symbol: "gauge.with.dots.needle.67percent", title: "Max refresh", value: "\(device.maxRefreshHz) Hz", secondary: true)
                    InfoRow(symbol: "film", title: "HEVC hardware", value: device.hevcHardware ? "Yes" : "No", secondary: true)
                }
            }
        }
    }

    private func card<Content: View>(_ title: String? = nil, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if let title {
                Text(title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Brand.secondaryText)
                    .padding(.leading, 4)
            }
            VStack(alignment: .leading, spacing: 10) { content() }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(.white.opacity(0.07)))
        }
    }
}

private struct StatusPill: View {
    let streaming: Bool
    let transport: String
    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(streaming ? Color.green : Color.secondary).frame(width: 6, height: 6)
            Text(streaming ? "Streaming over \(transport)" : "Not connected")
                .font(.caption2.weight(.medium))
        }
        .padding(.horizontal, 8).padding(.vertical, 3)
        .background((streaming ? Color.green : Color.secondary).opacity(0.16), in: Capsule())
        .foregroundStyle(streaming ? .green : .secondary)
    }
}

private struct InfoRow: View {
    let symbol: String
    let title: String
    let value: String?
    var secondary = false

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.subheadline)
                .foregroundStyle(secondary ? Brand.secondaryText : .white)
                .frame(width: 22)
            Text(title)
                .font(.subheadline)
                .foregroundStyle(secondary ? Brand.secondaryText : Color.primary)
            Spacer(minLength: 8)
            if let value {
                Text(value).font(.caption.monospacedDigit()).foregroundStyle(Brand.secondaryText)
            }
        }
    }
}

private struct ToggleRow: View {
    let symbol: String
    let title: String
    let detail: String?
    @Binding var isOn: Bool

    var body: some View {
        Toggle(isOn: $isOn) {
            HStack(spacing: 10) {
                Image(systemName: symbol)
                    .font(.subheadline)
                    .foregroundStyle(.white)
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.subheadline)
                    if let detail { Text(detail).font(.caption).foregroundStyle(Brand.secondaryText) }
                }
            }
        }
        .toggleStyle(.switch)
        .tint(Brand.blue)
    }
}

private struct GestureRow: View {
    let symbol: String
    let gesture: String
    let action: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.caption)
                .foregroundStyle(.white.opacity(0.85))
                .frame(width: 20)
            Text(gesture).font(.caption)
            Spacer(minLength: 8)
            Text(action).font(.caption.weight(.medium)).foregroundStyle(Brand.secondaryText)
        }
    }
}

private struct ShortcutRow: View {
    let keys: String
    let mac: String
    let action: String

    var body: some View {
        HStack(spacing: 8) {
            Text(keys).font(.caption.monospaced().weight(.semibold))
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 5))
            Image(systemName: "arrow.right").font(.caption2).foregroundStyle(Brand.secondaryText)
            Text(mac).font(.caption.monospaced()).foregroundStyle(Brand.secondaryText)
            Spacer(minLength: 6)
            Text(action).font(.caption.weight(.medium))
        }
    }
}

/// Compact optional live stream stats pill (FPS, latency, codec).
struct StatsHUD: View {
    let fps: Int
    let latencyMs: Double?
    let codec: String?

    var body: some View {
        HStack(spacing: 7) {
            Circle().fill(Color.green).frame(width: 6, height: 6)
            Text("\(fps) fps")
                .font(.caption.monospacedDigit().weight(.semibold))
            if let latencyMs {
                Text(String(format: "· %.1f ms", latencyMs))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.white.opacity(0.8))
            }
            if let codec {
                Text("· \(codec)")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.white.opacity(0.65))
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 12).padding(.vertical, 6)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(.white.opacity(0.12)))
        .environment(\.colorScheme, .dark)
    }
}

/// Brief indicator when the Mac changes the iPad's brightness (D-033).
struct BrightnessHUD: View {
    let value: Float

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: value < 0.5 ? "sun.min.fill" : "sun.max.fill")
                .foregroundStyle(.white)
            GeometryReader { proxy in
                Capsule().fill(.white.opacity(0.2))
                    .overlay(alignment: .leading) {
                        Capsule().fill(.white).frame(width: proxy.size.width * CGFloat(value))
                    }
            }
            .frame(width: 180, height: 6)
        }
        .padding(.horizontal, 18).padding(.vertical, 12)
        .background(.ultraThinMaterial, in: Capsule())
        .environment(\.colorScheme, .dark)
    }
}

/// The small round button that opens the controls; faint while streaming.
struct ControlsButton: View {
    /// The button with its padding, for placing it.
    static let footprint: CGFloat = 76
    let streaming: Bool
    /// Untouched for a while during streaming: nearly invisible, still tappable in place.
    var resting = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "slider.horizontal.3")
                .font(.wd(17, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 44, height: 44)
                .background(.black.opacity(streaming ? 0.25 : 0.45), in: Circle())
                .overlay(Circle().strokeBorder(.white.opacity(0.15)))
                .opacity(!streaming ? 1 : resting ? 0.12 : 0.45)
        }
        .buttonStyle(.plain)
        .padding(16)
        .accessibilityLabel("Session controls")
    }
}

/// Solid, full-width capsule button with white text; the same on every
/// platform and appearance (system prominent styles can render grey).
struct FilledButtonStyle: ButtonStyle {
    let fill: Color

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body.weight(.semibold))
            .foregroundStyle(.white)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity)
            .background(fill.opacity(configuration.isPressed ? 0.75 : 1), in: Capsule())
            .contentShape(Capsule())
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}
