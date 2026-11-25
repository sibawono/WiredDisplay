import SwiftUI

// Presentation for the iPad app. Pure SwiftUI on plain values (no UIKit, no
// session objects), so every state can be rendered and reviewed on its own.

enum Brand {
    static let blue = Color(red: 0.12, green: 0.48, blue: 1.0)
    static let deep = Color(red: 0.04, green: 0.13, blue: 0.40)
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

struct ControlsContent: View {
    let summary: SessionSummary
    @Binding var speaker: Bool
    @Binding var microphone: Bool
    @Binding var smoothGradients: Bool
    var metalRenderer: Binding<Bool>? = nil
    let pairedMacs: [PairedMacRow]
    let forgetPaired: () -> Void
    let reconnect: () -> Void
    var device: DeviceInfo? = nil
    @State private var confirmForget = false
    @State private var showGestures = false
    @State private var showShortcuts = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                section("Display") {
                    if let size = summary.logicalSize {
                        InfoRow(symbol: "rectangle.on.rectangle", title: "Looks like \(size)", value: nil)
                    }
                    if let detail = summary.detail {
                        InfoRow(symbol: "dial.medium", title: detail, value: nil, secondary: true)
                    }
                    if summary.streaming {
                        InfoRow(symbol: "film.stack", title: "Frames",
                                value: "\(summary.framesShown.formatted()) shown · \(summary.framesDropped.formatted()) dropped",
                                secondary: true)
                    }
                    ToggleRow(symbol: "circle.lefthalf.filled", title: "Smooth gradients",
                              detail: "GPU dithering against banding.", isOn: $smoothGradients)
                    if let metalRenderer {
                        ToggleRow(symbol: "bolt.horizontal", title: "Metal renderer",
                                  detail: "Draws each frame as soon as it is decoded (lower latency). Off: the system video layer.", isOn: metalRenderer)
                    }
                }
                section("Audio") {
                    ToggleRow(symbol: "speaker.wave.2.fill", title: "Mac audio on this iPad", detail: nil, isOn: $speaker)
                    ToggleRow(symbol: "mic.fill", title: "iPad microphone to Mac", detail: nil, isOn: $microphone)
                    if microphone {
                        Label("Live: choose “iPad Microphone” on the Mac", systemImage: "waveform")
                            .font(.footnote.weight(.medium))
                            .foregroundStyle(.orange)
                            .padding(.leading, 38)
                    }
                }
                section("Touch") {
                    DisclosureGroup(isExpanded: $showGestures) {
                        VStack(alignment: .leading, spacing: 10) {
                            GestureRow(symbol: "hand.tap", gesture: "Tap", action: "Click")
                            GestureRow(symbol: "hand.draw", gesture: "Drag", action: "Scroll")
                            GestureRow(symbol: "hand.point.up.left", gesture: "Hold, then drag", action: "Select · move")
                            GestureRow(symbol: "hand.tap", gesture: "Two-finger tap", action: "Right click")
                            GestureRow(symbol: "arrow.up.left.and.arrow.down.right", gesture: "Pinch", action: "Zoom")
                            GestureRow(symbol: "arrow.clockwise", gesture: "Two-finger rotate", action: "Rotate")
                            GestureRow(symbol: "hand.pinch", gesture: "Three-finger pinch / spread", action: "Copy · paste")
                            GestureRow(symbol: "arrow.uturn.backward", gesture: "Three-finger swipe", action: "Undo · redo")
                        }
                        .padding(.top, 10)
                    } label: {
                        Label("Gestures", systemImage: "hand.raised.fingers.spread")
                            .font(.body)
                    }
                    .tint(.primary)
                    Text("Touch, keyboard and trackpad need “Allow input” in the Mac’s WiredDisplay menu.")
                        .font(.footnote).foregroundStyle(Brand.secondaryText)
                }
                section("Keyboard & trackpad") {
                    DisclosureGroup(isExpanded: $showShortcuts) {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("iPadOS keeps these for itself, so use Control instead of Command:")
                                .font(.footnote).foregroundStyle(Brand.secondaryText)
                            ShortcutRow(keys: "⌃ Tab", mac: "⌘ Tab", action: "Switch apps")
                            ShortcutRow(keys: "⌃ ⇧ Tab", mac: "⌘ ⇧ Tab", action: "Switch back")
                            ShortcutRow(keys: "⌃ `", mac: "⌘ `", action: "App windows")
                            ShortcutRow(keys: "⌃ Space", mac: "⌘ Space", action: "Spotlight")
                            ShortcutRow(keys: "⌃ ⇧ 3 · 4 · 5", mac: "⌘ ⇧ 3 · 4 · 5", action: "Screenshot")
                            Text("Hold ⌃ and press Tab again to move through apps, like ⌘ Tab on a Mac. All other shortcuts (⌘ C, ⌘ V, ⌘ W …) go to the Mac as they are.")
                                .font(.footnote).foregroundStyle(Brand.secondaryText)
                            Divider().padding(.vertical, 2)
                            GestureRow(symbol: "rectangle.and.hand.point.up.left", gesture: "Two-finger scroll", action: "Scroll")
                            GestureRow(symbol: "cursorarrow.click.2", gesture: "Two-finger click", action: "Right click")
                            GestureRow(symbol: "arrow.up.left.and.arrow.down.right", gesture: "Pinch", action: "Zoom")
                            GestureRow(symbol: "arrow.clockwise", gesture: "Rotate", action: "Rotate")
                            Text("Three- and four-finger swipes stay with iPadOS. Use ⌃ ↑ for Mission Control and ⌃ ← / → for Spaces.")
                                .font(.footnote).foregroundStyle(Brand.secondaryText)
                        }
                        .padding(.top, 10)
                    } label: {
                        Label("Shortcuts", systemImage: "keyboard")
                            .font(.body)
                    }
                    .tint(.primary)
                }
                if let device {
                    section("This iPad") {
                        InfoRow(symbol: "ipad.landscape", title: "Model", value: device.model)
                        InfoRow(symbol: "square.resize", title: "Panel", value: device.panel)
                        InfoRow(symbol: "circle.grid.3x3", title: "Density", value: "\(device.pixelsPerInch) ppi")
                        InfoRow(symbol: "gauge.with.dots.needle.67percent", title: "Refresh", value: "up to \(device.maxRefreshHz) Hz")
                        InfoRow(symbol: "film", title: "HEVC hardware decode", value: device.hevcHardware ? "Yes" : "No (H.264)")
                    }
                }
                section("Security") {
                    if pairedMacs.isEmpty {
                        InfoRow(symbol: "lock.open", title: "No paired Mac", value: nil, secondary: true)
                    } else {
                        ForEach(pairedMacs) { mac in
                            InfoRow(symbol: "lock.shield.fill", title: mac.name, value: String(mac.fingerprint.prefix(8)))
                        }
                        Button("Forget Paired Macs…", role: .destructive) { confirmForget = true }
                            .font(.body)
                            .confirmationDialog("Forget all paired Macs?", isPresented: $confirmForget) {
                                Button("Forget", role: .destructive, action: forgetPaired)
                            } message: {
                                Text("The next Mac that connects must be paired again with a code.")
                            }
                    }
                }
                Button(action: reconnect) {
                    Label("Reconnect", systemImage: "arrow.clockwise")
                        .fontWeight(.semibold)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(FilledButtonStyle(fill: Brand.action))
            }
            .padding(20)
        }
        .frame(width: 400)
        .frame(maxHeight: 700)
    }

    private var header: some View {
        HStack(spacing: 14) {
            IconTile(size: 48)
            VStack(alignment: .leading, spacing: 4) {
                Text(summary.macName.isEmpty ? "WiredDisplay" : summary.macName)
                    .font(.title3.weight(.semibold))
                    .lineLimit(1)
                StatusPill(streaming: summary.streaming)
            }
            Spacer(minLength: 0)
        }
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Brand.secondaryText)
                .padding(.leading, 4)
            VStack(alignment: .leading, spacing: 12) { content() }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
    }
}

private struct StatusPill: View {
    let streaming: Bool
    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(streaming ? Color.green : Color.secondary).frame(width: 7, height: 7)
            Text(streaming ? "Streaming over USB‑C" : "Not connected")
                .font(.caption.weight(.medium))
        }
        .padding(.horizontal, 9).padding(.vertical, 4)
        .background((streaming ? Color.green : Color.secondary).opacity(0.14), in: Capsule())
        .foregroundStyle(streaming ? .green : .secondary)
    }
}

private struct InfoRow: View {
    let symbol: String
    let title: String
    let value: String?
    var secondary = false

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .foregroundStyle(.white)
                .frame(width: 26)
            Text(title)
                .font(secondary ? .subheadline : .body)
                .foregroundStyle(secondary ? Brand.secondaryText : Color.primary)
            Spacer(minLength: 8)
            if let value {
                Text(value).font(.subheadline.monospacedDigit()).foregroundStyle(Brand.secondaryText)
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
            HStack(spacing: 12) {
                Image(systemName: symbol)
                    .foregroundStyle(.white)
                    .frame(width: 26)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                    if let detail { Text(detail).font(.footnote).foregroundStyle(Brand.secondaryText) }
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
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .foregroundStyle(.white)
                .frame(width: 26)
            Text(gesture).font(.subheadline)
            Spacer(minLength: 8)
            Text(action).font(.subheadline.weight(.medium))
        }
    }
}

private struct ShortcutRow: View {
    let keys: String
    let mac: String
    let action: String

    var body: some View {
        HStack(spacing: 10) {
            Text(keys).font(.subheadline.monospaced().weight(.semibold))
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
            Image(systemName: "arrow.right").font(.caption).foregroundStyle(Brand.secondaryText)
            Text(mac).font(.subheadline.monospaced()).foregroundStyle(Brand.secondaryText)
            Spacer(minLength: 8)
            Text(action).font(.subheadline.weight(.medium))
        }
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
