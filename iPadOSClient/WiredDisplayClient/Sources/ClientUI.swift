import SwiftUI

// Presentation for the iPad app. Pure SwiftUI on plain values (no UIKit, no
// session objects), so every state can be rendered and reviewed on its own.

enum Brand {
    static let blue = Color(red: 0.12, green: 0.48, blue: 1.0)
    /// Secondary text on the app's dark surfaces; the system style measured 3.6:1 there.
    static let secondaryText = Color.white.opacity(0.7)
    /// Filled buttons with white text: Brand.blue gave 3.2:1 under white text.
    static let action = Color(red: 0.04, green: 0.33, blue: 0.80)
    static let tile = LinearGradient(colors: [Color(red: 0.35, green: 0.72, blue: 1.0), blue, Color(red: 0.04, green: 0.32, blue: 0.88)],
                                     startPoint: .top, endPoint: .bottom)
}

/// Dark backdrop behind every non-streaming screen.
struct Backdrop: View {
    var body: some View {
        LinearGradient(colors: [Color(red: 0.03, green: 0.05, blue: 0.12), .black], startPoint: .top, endPoint: .bottom)
            .ignoresSafeArea()
    }
}

/// A tile with a symbol, or (no symbol) the app icon itself, so the splash
/// screen shows exactly the home screen icon.
struct IconTile: View {
    var symbol: String?
    var size: CGFloat = 96

    var body: some View {
        Group {
            if let symbol {
                RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
                    .fill(Brand.tile)
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
        .shadow(color: Brand.blue.opacity(0.45), radius: 24, y: 10)
    }
}

// MARK: - Connection status

struct StatusInfo: Equatable {
    enum Stage: Equatable { case starting, waitingForMac, connecting, failed(String) }
    var stage: Stage
    var macName: String
    var lastError: String?
}

struct StatusScreen: View {
    let info: StatusInfo
    /// When waiting began, for the re-plug hint (BUG-037: after the Mac
    /// restarts, the iPad stays off its USB bus until the cable is re-plugged).
    @State private var waitingSince = Date()
    static let replugHintDelay: TimeInterval = 20

    var body: some View {
        VStack(spacing: 28) {
            IconTile()
            VStack(spacing: 10) {
                Text("WiredDisplay")
                    .font(.system(size: 40, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                statusLine
            }
            steps
            TimelineView(.periodic(from: .now, by: 1)) { context in
                if info.stage == .waitingForMac,
                   context.date.timeIntervalSince(waitingSince) >= Self.replugHintDelay {
                    ReplugHint()
                        .transition(.opacity.combined(with: .move(edge: .bottom)))
                }
            }
            if let note {
                Label(note, systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote)
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .background(.orange.opacity(0.12), in: Capsule())
                    .frame(maxWidth: 520)
            }
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(.smooth, value: info)
        .onChange(of: info.stage, initial: true) { _, stage in
            if stage == .waitingForMac { waitingSince = Date() }
        }
    }

    private var statusLine: some View {
        HStack(spacing: 10) {
            switch info.stage {
            case .failed:
                Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
            case .connecting, .starting:
                ProgressView().controlSize(.small).tint(.white)
            case .waitingForMac:
                WaitingDot()
            }
            Text(headline)
                .font(.title3.weight(.medium))
                .foregroundStyle(.white.opacity(0.8))
        }
    }

    private var headline: String {
        switch info.stage {
        case .starting: return "Starting…"
        case .waitingForMac: return "Waiting for your Mac"
        case .connecting: return info.macName.isEmpty ? "Connecting…" : "Connecting to \(info.macName)…"
        case .failed: return "Can’t start"
        }
    }

    /// The error worth showing: a failure reason, or why the last session ended.
    private var note: String? {
        if case .failed(let reason) = info.stage { return reason }
        guard info.stage == .waitingForMac, let error = info.lastError, !error.isEmpty else { return nil }
        return "Last session: \(error)"
    }

    private var steps: some View {
        let connecting = info.stage == .connecting
        return VStack(alignment: .leading, spacing: 0) {
            StepRow(number: 1, symbol: "cable.connector", title: "Connect the USB‑C cable",
                    detail: "Wired only. Wi‑Fi is never used.", done: connecting)
            Divider().overlay(.white.opacity(0.08)).padding(.leading, 64)
            StepRow(number: 2, symbol: "menubar.rectangle", title: "Start WiredDisplay on the Mac",
                    detail: "It lives in the menu bar and opens at login.", done: connecting)
            Divider().overlay(.white.opacity(0.08)).padding(.leading, 64)
            StepRow(number: 3, symbol: "lock.shield", title: "Pair once",
                    detail: "Confirm the code the first time this iPad meets a Mac.", done: false)
        }
        .padding(.vertical, 6)
        .frame(maxWidth: 520)
        .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(.white.opacity(0.08)))
    }
}

/// Shown after a while without a Mac: the usual cure after a Mac restart.
private struct ReplugHint: View {
    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: "arrow.triangle.2.circlepath")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 36, height: 36)
                .background(Brand.blue.opacity(0.85), in: Circle())
            VStack(alignment: .leading, spacing: 3) {
                Text("Mac restarted? Unplug the cable and plug it back in.")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.white)
                Text("After a restart the Mac doesn’t see an iPad that stayed connected until the USB‑C cable is reconnected.")
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.6))
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .frame(maxWidth: 520)
        .background(Brand.blue.opacity(0.14), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Brand.blue.opacity(0.4)))
    }
}

private struct StepRow: View {
    let number: Int
    let symbol: String
    let title: String
    let detail: String
    let done: Bool

    var body: some View {
        HStack(spacing: 16) {
            ZStack {
                Circle().fill(done ? Color.green.opacity(0.85) : Brand.blue.opacity(0.85))
                Image(systemName: done ? "checkmark" : symbol)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .frame(width: 36, height: 36)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.body.weight(.semibold)).foregroundStyle(.white)
                Text(detail).font(.subheadline).foregroundStyle(.white.opacity(0.55))
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Step \(number): \(title). \(detail)\(done ? ". Done" : "")")
    }
}

private struct WaitingDot: View {
    var body: some View {
        Circle().fill(Brand.blue)
            .frame(width: 10, height: 10)
            .accessibilityHidden(true)
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
    var logicalSize: String?   // "1788 × 1340"
    var detail: String?        // "3180 × 2384 px · 60 Hz · HEVC"
    var framesShown: Int
    var framesDropped: Int
    var liveFPS: Int = 0
    var liveLatencyMs: Double? = nil
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
    let reconnect: () -> Void
    var close: () -> Void = {}
    var device: DeviceInfo? = nil

    @State private var tab: Tab = .display
    @State private var confirmForget = false
    @State private var confirmSleep = false
    @State private var showGestures = false
    @State private var showShortcuts = false

    private static let qualityTitles = ["Balanced", "Pro", "Ultra", "High"]
    private static let qualityDetails = [
        "4:2:0 while moving, 4:4:4 when still · 10-bit",
        "Lowest latency 4:2:0 · 10-bit",
        "Sharpest 4:4:4 colour · 10-bit",
        "Full 4:4:4 colour · 8-bit",
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
                StatusPill(streaming: summary.streaming)
            }
            Spacer(minLength: 0)
            Button(action: close) {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .bold))
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
                            .font(.system(size: 14, weight: selected ? .semibold : .regular))
                        Text(item.title)
                            .font(.system(size: 10.5, weight: selected ? .semibold : .medium))
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
                                    .font(.system(size: 15, weight: .medium))
                                Text(action.title)
                                    .font(.system(size: 10.5, weight: .medium))
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
        Group {
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
    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(streaming ? Color.green : Color.secondary).frame(width: 6, height: 6)
            Text(streaming ? "Streaming over USB‑C" : "Not connected")
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
                .font(.system(size: 17, weight: .semibold))
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
