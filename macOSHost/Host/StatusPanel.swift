import AppKit
import SwiftUI
import WDHostCore

// The menu bar panel (popover): an icon tab bar over cards, in the style of
// modern menu bar utilities. Pure views over a snapshot, so it can be
// rendered without a session (`--render-panel`).

struct PanelSnapshot {
    struct Paired: Identifiable, Equatable {
        var id: String { key }
        var name: String
        var model: String?
        var key: String
        /// "iPad Air 13-inch (M2) · Key 0d7238ca"; the key alone when the
        /// model was never read (paired before it was recorded).
        var detail: String { [model, "Key \(key)"].compactMap { $0 }.joined(separator: " · ") }
    }

    var stateText = "Waiting for the iPad on USB"
    var stateColor: Color = .orange
    var connectedFor: String?
    /// Other iPads streaming at the same time (D-041).
    var otherIPads: [String] = []
    var looksLike: String?
    var displaySpace: VirtualDisplayController.Space?
    var canChangeDisplaySpace = false
    var displaySpaceError = false
    var pixels: String?
    var encoding: String?
    var limitNote: String?
    var brightness: Float?
    var quality: QualityPreset?
    var inputEnabled = false
    var accessibility = false
    var screenRecording = false
    var speaker = false
    var microphone = false
    var autoSwitchAudio = true
    var matchRefresh = true
    var localCursor = true
    var autoSwitchMicrophone = true
    var bothSpeakers = false
    var bothSpeakersDelayMs: Double = 45
    var paired: [Paired] = []
    var connectionCode: String?
    var openAtLogin = false
    var keepDisplayAwake = true
    var keepMacAwake = false
    var loginNeedsApproval = false
    var version = "0.0"
}

struct PanelActions {
    var setDisplaySpace: (VirtualDisplayController.Space) -> Void = { _ in }
    var setBrightness: (Float) -> Void = { _ in }
    var setQuality: (QualityPreset) -> Void = { _ in }
    var setInput: (Bool) -> Void = { _ in }
    var setOpenAtLogin: (Bool) -> Void = { _ in }
    var setAutoSwitchAudio: (Bool) -> Void = { _ in }
    var setMatchRefresh: (Bool) -> Void = { _ in }
    var setKeepDisplayAwake: (Bool) -> Void = { _ in }
    var setKeepMacAwake: (Bool) -> Void = { _ in }
    var setLocalCursor: (Bool) -> Void = { _ in }
    var setAutoSwitchMicrophone: (Bool) -> Void = { _ in }
    var setBothSpeakers: (Bool) -> Void = { _ in }
    var setBothSpeakersDelayMs: (Double) -> Void = { _ in }
    var openDisplaySettings: () -> Void = {}
    var openSoundSettings: () -> Void = {}
    var openAccessibility: () -> Void = {}
    var openScreenRecording: () -> Void = {}
    var forgetPaired: () -> Void = {}
    var showLog: () -> Void = {}
    var quit: () -> Void = {}
}

@MainActor
final class PanelModel: ObservableObject {
    enum Tab: String, CaseIterable, Identifiable {
        case display, input, audio, security, general
        var id: String { rawValue }
        var symbol: String {
            switch self {
            case .display: return "display"
            case .input: return "keyboard"
            case .audio: return "speaker.wave.2"
            case .security: return "lock.shield"
            case .general: return "gearshape"
            }
        }
        var title: String {
            switch self {
            case .display: return "Display"
            case .input: return "Input"
            case .audio: return "Audio"
            case .security: return "Security"
            case .general: return "General"
            }
        }
    }

    @Published var snapshot = PanelSnapshot()
    @Published var tab: Tab = .display
    var actions = PanelActions()
}

struct StatusPanelView: View {
    @ObservedObject var model: PanelModel

    private var s: PanelSnapshot { model.snapshot }

    var body: some View {
        GlassGroup(spacing: 10) { panel }
    }

    private var panel: some View {
        VStack(spacing: 8) {
            header
            tabBar
            VStack(alignment: .leading, spacing: 6) {
                Text(model.tab.title) // bold 15 pt counts as large text (3:1) on the glass
                    .font(.system(size: 15, weight: .bold))
                    .padding(.leading, 4)
                content
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            footer
        }
        .padding(10)
        .frame(width: 320)
    }

    // MARK: header and tabs

    private var header: some View {
        HStack(spacing: 10) {
            Image(nsImage: NSApp?.applicationIconImage ?? NSImage(named: NSImage.applicationIconName) ?? NSImage())
                .resizable()
                .frame(width: 30, height: 30)
            VStack(alignment: .leading, spacing: 1) {
                Text("WiredDisplay").font(.system(size: 13, weight: .semibold))
                HStack(spacing: 6) {
                    Circle().fill(s.stateColor).frame(width: 7, height: 7)
                    Text(s.stateText).font(.system(size: 12)).foregroundStyle(Color.caption).lineLimit(1)
                }
                if let connectedFor = s.connectedFor {
                    Text(connectedFor).font(.system(size: 11)).foregroundStyle(Color.caption)
                    .fixedSize(horizontal: false, vertical: true)
                }
                if !s.otherIPads.isEmpty {
                    Text("Also: " + s.otherIPads.joined(separator: ", ") + " · settings apply to all")
                        .font(.system(size: 11)).foregroundStyle(Color.caption)
                    .fixedSize(horizontal: false, vertical: true).lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .groupBox()
    }

    /// macOS 27 kit "Utility Panel Tab Bar" (Toolbars page): 44 x 30 pt
    /// buttons side by side with no track; the selected one stands on a
    /// small Liquid Glass plate (9 pt corners), glyphs keep the label colour.
    /// Switching is instant, with no animation (user request).
    private var tabBar: some View {
        HStack(spacing: 0) {
            ForEach(PanelModel.Tab.allCases) { tab in
                let selected = model.tab == tab
                Button { model.tab = tab } label: {
                    Image(systemName: tab.symbol)
                        .font(.system(size: 15))
                        .foregroundStyle(Color.primary.opacity(selected ? 1 : 0.7))
                        .frame(width: 44, height: 30)
                        .background { if selected { GlassPlate() } }
                        // Even spacing across the panel width (user request: balanced layout).
                        .frame(maxWidth: .infinity)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(tab.title)
                .accessibilityLabel(tab.title)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .frame(maxWidth: .infinity)
        .transaction { $0.animation = nil }
    }

    @ViewBuilder private var content: some View {
        switch model.tab {
        case .display: displayTab
        case .input: inputTab
        case .audio: audioTab
        case .security: securityTab
        case .general: generalTab
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            FooterButton(title: "Show Log", symbol: "doc.text.magnifyingglass", action: model.actions.showLog)
            FooterButton(title: "Quit", symbol: "power", action: model.actions.quit)
        }
    }

    // MARK: tabs

    private var displayTab: some View {
        VStack(spacing: 8) {
            Card {
                if let looksLike = s.looksLike {
                    InfoLine(symbol: "rectangle.on.rectangle", title: "Looks like \(looksLike)", detail: s.pixels)
                    NativeSegmented(
                        segments: VirtualDisplayController.Space.allCases.map { .title($0.title) },
                        selection: Binding(
                            get: { s.displaySpace.flatMap { VirtualDisplayController.Space.allCases.firstIndex(of: $0) } ?? -1 },
                            set: { index in
                                let spaces = VirtualDisplayController.Space.allCases
                                guard spaces.indices.contains(index) else { return }
                                model.actions.setDisplaySpace(spaces[index])
                            }),
                        controlSize: .regular, fontSize: 11, isEnabled: s.canChangeDisplaySpace
                    )
                    .frame(maxWidth: .infinity)
                    .accessibilityLabel("Display space")
                    if s.displaySpaceError {
                        Text("Couldn’t change display space.").font(.system(size: 11)).foregroundStyle(Color.caption)
                    }
                    if let encoding = s.encoding {
                        CardDivider()
                        InfoLine(symbol: "film", title: encoding, detail: s.limitNote)
                    }
                } else {
                    InfoLine(symbol: "display.trianglebadge.exclamationmark", title: "No iPad display",
                             detail: "Open WiredDisplay on the iPad and connect the cable")
                }
                CardDivider()
                VStack(alignment: .leading, spacing: 8) {
                    Text("Brightness").font(.system(size: 11, weight: .semibold))
                    HStack(spacing: 10) {
                        Image(systemName: "sun.min").foregroundStyle(.secondary)
                        NativeSlider(value: Binding(get: { Double(s.brightness ?? 0.5) },
                                                    set: { model.snapshot.brightness = Float($0); model.actions.setBrightness(Float($0)) }),
                                     isEnabled: s.brightness != nil)
                            .frame(height: NativeSlider.sliderHeight + 2 * NativeSlider.overflow)
                            .padding(.horizontal, -NativeSlider.overflow)
                            .frame(height: NativeSlider.sliderHeight)
                        Image(systemName: "sun.max").foregroundStyle(.secondary)
                    }
                    Text(s.brightness == nil ? "Available while an iPad is connected"
                         : "Real iPad backlight · the brightness keys work too")
                        .font(.system(size: 11)).foregroundStyle(Color.caption)
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
            Card {
                Text("Quality").font(.system(size: 11, weight: .semibold))
                NativeSegmented(segments: QualityPreset.allCases.map { .titled($0.shortTitle, symbol: $0.symbol) },
                                selection: Binding(get: { s.quality.flatMap { QualityPreset.allCases.firstIndex(of: $0) } ?? -1 },
                                                   set: { index in
                                                       guard QualityPreset.allCases.indices.contains(index) else { return }
                                                       let preset = QualityPreset.allCases[index]
                                                       model.snapshot.quality = preset
                                                       model.actions.setQuality(preset)
                                                   }),
                                controlSize: .regular, fontSize: 11)
                    .frame(maxWidth: .infinity)
                if let quality = s.quality {
                    Text("\(quality.formatTitle) · \(quality.detail)").font(.system(size: 10.5)).foregroundStyle(Color.caption)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Card {
                ToggleLine(title: "Match the iPad's refresh rate",
                           detail: s.matchRefresh ? "Up to 120 Hz on iPad Pro (ProMotion); 60 Hz on other iPads"
                               : "Always 60 Hz (less work for the Mac)",
                           isOn: Binding(get: { s.matchRefresh },
                                         set: { model.snapshot.matchRefresh = $0; model.actions.setMatchRefresh($0) }))
                CardDivider()
                ToggleLine(title: "Draw the cursor on the iPad",
                           detail: s.localCursor ? "The pointer moves with ~1 ms delay instead of waiting for the video"
                               : "The cursor is part of the video (as before)",
                           isOn: Binding(get: { s.localCursor },
                                         set: { model.snapshot.localCursor = $0; model.actions.setLocalCursor($0) }))
            }
            LinkRow(title: "Display Settings…", symbol: "arrow.up.forward.app", action: model.actions.openDisplaySettings)
        }
    }

    private var inputTab: some View {
        VStack(spacing: 8) {
            Card {
                ToggleLine(title: "Allow Input from iPad", detail: "Touch, Magic Keyboard and trackpad",
                           isOn: Binding(get: { s.inputEnabled },
                                         set: { model.snapshot.inputEnabled = $0; model.actions.setInput($0) }))
                if !s.accessibility {
                    CardDivider()
                    WarningLine(text: "Accessibility permission is needed for input.",
                                button: "Grant…", action: model.actions.openAccessibility)
                }
            }
            Card {
                Text("Shortcuts on the iPad keyboard").font(.system(size: 11, weight: .semibold))
                ShortcutLine(keys: "⌃ Tab", mac: "⌘ Tab", what: "Switch apps")
                ShortcutLine(keys: "⌃ Space", mac: "⌘ Space", what: "Spotlight")
                ShortcutLine(keys: "⌃ ⇧ 3 / 4 / 5", mac: "⌘ ⇧ 3 / 4 / 5", what: "Screenshot")
                ShortcutLine(keys: "⌃ ↑  ⌃ ← →", mac: nil, what: "Mission Control · Spaces")
                Text("Pinch and rotate work on the touch screen and the trackpad.")
                    .font(.system(size: 11)).foregroundStyle(Color.caption)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var audioTab: some View {
        VStack(spacing: 8) {
            Card {
                StatusLine(symbol: s.speaker ? "speaker.wave.2.fill" : "speaker.slash", title: "Mac sound on iPad",
                           detail: "Output device “iPad Speaker”", on: s.speaker)
                CardDivider()
                StatusLine(symbol: s.microphone ? "mic.fill" : "mic.slash", title: "iPad microphone",
                           detail: "Input device “iPad Microphone”", on: s.microphone)
                Text("Turn these on or off in the WiredDisplay app on the iPad.")
                    .font(.system(size: 11)).foregroundStyle(Color.caption)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Card {
                ToggleLine(title: "Play on Mac speakers too",
                           detail: s.microphone
                               ? "Paused while the iPad microphone is on to avoid echo"
                               : "Plays Mac sound on both the Mac and the iPad together",
                           isOn: Binding(get: { s.bothSpeakers },
                                         set: { model.snapshot.bothSpeakers = $0; model.actions.setBothSpeakers($0) }))
                if s.bothSpeakers {
                    CardDivider()
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("Sync delay").font(.system(size: 11, weight: .semibold))
                            Spacer()
                            Text("\(Int(s.bothSpeakersDelayMs.rounded())) ms")
                                .font(.system(size: 11)).foregroundStyle(Color.caption).monospacedDigit()
                        }
                        NativeSlider(
                            value: Binding(
                                get: { s.bothSpeakersDelayMs / HostController.maxBothSpeakersDelayMs },
                                set: {
                                    let ms = ($0 * HostController.maxBothSpeakersDelayMs).rounded()
                                    model.snapshot.bothSpeakersDelayMs = ms
                                    model.actions.setBothSpeakersDelayMs(ms)
                                }),
                            isEnabled: true)
                            .frame(height: NativeSlider.sliderHeight + 2 * NativeSlider.overflow)
                            .padding(.horizontal, -NativeSlider.overflow)
                            .frame(height: NativeSlider.sliderHeight)
                        Text("Adjust if you hear an echo between the Mac and the iPad.")
                            .font(.system(size: 10.5)).foregroundStyle(Color.caption)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            Card {
                ToggleLine(title: "Switch to headphones automatically",
                           detail: "AirPods, Bluetooth, USB-C earphones: sound moves to them, and back to the iPad when they disconnect",
                           isOn: Binding(get: { s.autoSwitchAudio },
                                         set: { model.snapshot.autoSwitchAudio = $0; model.actions.setAutoSwitchAudio($0) }))
                if s.autoSwitchAudio {
                    CardDivider()
                    ToggleLine(title: "Use their microphone too",
                               detail: s.autoSwitchMicrophone
                                   ? "Off keeps the iPad microphone, and AirPods keep full sound quality"
                                   : "Output only: the microphone stays on the iPad",
                               isOn: Binding(get: { s.autoSwitchMicrophone },
                                             set: { model.snapshot.autoSwitchMicrophone = $0; model.actions.setAutoSwitchMicrophone($0) }))
                }
            }
            LinkRow(title: "Sound Settings…", symbol: "arrow.up.forward.app", action: model.actions.openSoundSettings)
        }
    }

    private var securityTab: some View {
        VStack(spacing: 8) {
            if let code = s.connectionCode {
                Card {
                    Text("Connection code").font(.system(size: 11, weight: .semibold))
                    Text(code).font(.system(size: 22, weight: .semibold, design: .rounded)).monospacedDigit()
                    Text("Matches the code on the iPad: this session is encrypted end to end.")
                        .font(.system(size: 11)).foregroundStyle(Color.caption)
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
            Card {
                Text("Paired iPads").font(.system(size: 11, weight: .semibold))
                if s.paired.isEmpty {
                    Text("None yet. The next iPad that connects pairs automatically.")
                        .font(.system(size: 12)).foregroundStyle(Color.caption)
                } else {
                    ForEach(s.paired) { peer in
                        InfoLine(symbol: "ipad.landscape", title: peer.name, detail: peer.detail)
                    }
                }
                CardDivider()
                Button(role: .destructive, action: model.actions.forgetPaired) {
                    Label("Forget Paired iPads…", systemImage: "trash")
                        .font(.system(size: 12))
                }
                .buttonStyle(.bordered)
                .foregroundStyle(s.paired.isEmpty ? Color.secondary : Color.red)
                .disabled(s.paired.isEmpty)
            }
        }
    }

    private var generalTab: some View {
        VStack(spacing: 8) {
            Card {
                Text("Permissions").font(.system(size: 11, weight: .semibold))
                PermissionLine(name: "Screen Recording", purpose: "Shows the Mac screen on the iPad",
                               granted: s.screenRecording, action: model.actions.openScreenRecording)
                CardDivider()
                PermissionLine(name: "Accessibility", purpose: "Input from the iPad and the brightness keys",
                               granted: s.accessibility, action: model.actions.openAccessibility)
            }
            Card {
                ToggleLine(title: "Keep the display on",
                           detail: s.keepDisplayAwake ? "The Mac's displays stay on while the iPad is connected"
                               : "The displays may sleep; a touch, click or key on the iPad or the Mac wakes them",
                           isOn: Binding(get: { s.keepDisplayAwake },
                                         set: { model.snapshot.keepDisplayAwake = $0; model.actions.setKeepDisplayAwake($0) }))
                CardDivider()
                ToggleLine(title: "Keep the Mac awake",
                           detail: s.keepMacAwake ? "The Mac does not sleep on its own while the iPad is connected, so the iPad can always wake it. Sleep from the Apple menu still works."
                               : "The Mac follows its own sleep setting. Once asleep, only its own keyboard or mouse wakes it.",
                           isOn: Binding(get: { s.keepMacAwake },
                                         set: { model.snapshot.keepMacAwake = $0; model.actions.setKeepMacAwake($0) }))
            }
            Card {
                ToggleLine(title: "Open at Login",
                           detail: s.loginNeedsApproval ? "Approve WiredDisplay in Login Items" : "The iPad shows the Mac right after a restart",
                           isOn: Binding(get: { s.openAtLogin },
                                         set: { model.snapshot.openAtLogin = $0; model.actions.setOpenAtLogin($0) }))
                CardDivider()
                Text("WiredDisplay \(s.version)").font(.system(size: 11)).foregroundStyle(Color.caption)
            }
        }
    }
}

// MARK: building blocks

extension Color {
    /// Secondary text on the section cards: measured at least 4.5:1 in light and dark.
    static let caption = Color.primary.opacity(0.82)
}

private struct Card<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 7) { content }
            .padding(.horizontal, 11).padding(.vertical, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .groupBox()
    }
}

private struct CardDivider: View {
    var body: some View { Divider().opacity(0.6) }
}

private struct InfoLine: View {
    let symbol: String
    let title: String
    let detail: String?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: symbol).foregroundStyle(.secondary).frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 12))
                if let detail { Text(detail).font(.system(size: 10.5)).foregroundStyle(Color.caption).fixedSize(horizontal: false, vertical: true) }
            }
            Spacer(minLength: 0)
        }
    }
}

private struct StatusLine: View {
    let symbol: String
    let title: String
    let detail: String
    let on: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol).foregroundStyle(on ? Color.accentColor : .secondary).frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 12))
                Text(detail).font(.system(size: 10.5)).foregroundStyle(Color.caption)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Text(on ? "On" : "Off")
                .font(.system(size: 11, weight: .semibold))
                .padding(.horizontal, 8).padding(.vertical, 3)
                .foregroundStyle(on ? Color.green : .secondary)
                .background(Capsule().fill(on ? Color.green.opacity(0.18) : Color(nsColor: .quaternarySystemFill)))
        }
    }
}

private struct ToggleLine: View {
    let title: String
    let detail: String
    @Binding var isOn: Bool

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 12))
                Text(detail).font(.system(size: 10.5)).foregroundStyle(Color.caption)
                    .fixedSize(horizontal: false, vertical: true) // always wraps, never truncates
            }
            Spacer(minLength: 8)
            // Laid out at the switch's own size; the lens room around it is
            // drawn outside that frame (frames do not clip) (user report: the
            // negative padding truncated the text beside it).
            // SwiftUI's own switch at the regular size: the size that gets
            // the macOS 27 glass lens while pressed (self-check: an NSSwitch
            // hosted in SwiftUI toggled without ever showing the lens).
            KitSwitch(isOn: $isOn)
        }
    }
}

private struct PermissionLine: View {
    let name: String
    let purpose: String
    let granted: Bool
    let action: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: granted ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(granted ? Color.green : .orange).frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(name).font(.system(size: 12))
                Text(purpose).font(.system(size: 10.5)).foregroundStyle(Color.caption)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            if !granted {
                Button("Grant…", action: action).controlSize(.small).buttonStyle(.bordered)
            }
        }
    }
}

private struct WarningLine: View {
    let text: String
    let button: String
    let action: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange).frame(width: 18)
            Text(text).font(.system(size: 12)).foregroundStyle(Color.caption)
            Spacer(minLength: 8)
            Button(button, action: action).controlSize(.small).buttonStyle(.bordered)
        }
    }
}

private struct ShortcutLine: View {
    let keys: String
    let mac: String?
    let what: String

    var body: some View {
        HStack(spacing: 8) {
            Text(keys)
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color(nsColor: .tertiarySystemFill)))
            if let mac {
                Image(systemName: "arrow.right").font(.system(size: 9)).foregroundStyle(Color.caption)
                Text(mac).font(.system(size: 11, design: .rounded)).foregroundStyle(Color.caption)
            }
            Spacer(minLength: 8)
            Text(what).font(.system(size: 12)).foregroundStyle(Color.caption)
        }
    }
}

/// macOS 27 kit "Buttons" (push, content area): AppKit's own bordered
/// button, stretched to the width it is given.
private struct LinkRow: View {
    let title: String
    let symbol: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack {
                Text(title)
                Spacer()
                Image(systemName: symbol)
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .controlSize(.large)
    }
}

private struct FooterButton: View {
    let title: String
    let symbol: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: symbol).frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .controlSize(.large)
    }
}

extension QualityPreset {
    var symbol: String {
        switch self {
        case .balanced: return "circle.lefthalf.filled"
        case .pro: return "bolt.fill" // lowest latency
        case .ultra: return "square.grid.3x3.fill" // every pixel keeps its own colour sample
        case .highColor: return "paintpalette.fill"
        }
    }
    var shortTitle: String { title }
    var formatTitle: String {
        switch self {
        case .balanced: return "Hybrid · 10-bit"
        case .pro: return "4:2:0 · 10-bit"
        case .ultra: return "4:4:4 · 10-bit"
        case .highColor: return "4:4:4 · 8-bit"
        }
    }
}

// MARK: macOS 27 kit surfaces

/// macOS 27 kit "Toggles - Switches" (medium): 54 x 24 track, a 32 x 20
/// white knob; while pressed the knob becomes a 50 x 31 Liquid Glass lens
/// that overflows the track and follows the finger. The system switch did not
/// show this lens in the popover (user report), so it is drawn here.
private struct KitSwitch: View {
    @Binding var isOn: Bool
    @State private var pressed = false
    @State private var dragX: CGFloat? // knob centre while dragging
    @Environment(\.isEnabled) private var enabled

    private let track = CGSize(width: 54, height: 24)
    private let knob = CGSize(width: 32, height: 20)
    private let lens = CGSize(width: 50, height: 31)

    var body: some View {
        let restX = isOn ? track.width - 2 - knob.width / 2 : 2 + knob.width / 2
        let x = min(max(dragX ?? restX, knob.width / 2), track.width - knob.width / 2)
        ZStack(alignment: .leading) {
            Capsule()
                .fill(isOn ? Color(nsColor: .controlAccentColor) : Color.primary.opacity(0.1))
                .frame(width: track.width, height: track.height)
            knobView
                .frame(width: pressed ? lens.width : knob.width, height: pressed ? lens.height : knob.height)
                .position(x: x, y: track.height / 2)
        }
        .frame(width: track.width, height: track.height)
        .opacity(enabled ? 1 : 0.5)
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 0)
            .onChanged { value in
                withAnimation(.spring(response: 0.25, dampingFraction: 0.7)) { pressed = true }
                if abs(value.translation.width) > 2 { dragX = restX + value.translation.width }
            }
            .onEnded { value in
                let moved = abs(value.translation.width) > 2
                let newValue = moved ? (restX + value.translation.width) > track.width / 2 : !isOn
                withAnimation(.spring(response: 0.3, dampingFraction: 0.75)) {
                    pressed = false
                    dragX = nil
                    if newValue != isOn { isOn = newValue }
                }
            })
        .accessibilityElement()
        .accessibilityAddTraits(.isToggle)
        .accessibilityValue(isOn ? "On" : "Off")
        .accessibilityAction { isOn.toggle() }
    }

    @ViewBuilder private var knobView: some View {
        if pressed, #available(macOS 26.0, *) {
            Color.clear.glassEffect(.clear.interactive(), in: Capsule())
        } else {
            Capsule().fill(Color.white).shadow(color: .black.opacity(0.12), radius: 2, y: 1)
        }
    }
}

/// Kit "Liquid Glass - Small": the selected utility-panel tab's plate.
private struct GlassPlate: View {
    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 9, style: .continuous)
        if #available(macOS 26.0, *) {
            Color.clear.glassEffect(.regular, in: shape)
        } else {
            shape.fill(Color(nsColor: .quaternarySystemFill))
                .overlay(shape.strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5))
        }
    }
}

/// Keeps the panel's children grouped (layout only; the controls inside
/// bring their own Liquid Glass).
private struct GlassGroup<Content: View>: View {
    let spacing: CGFloat
    @ViewBuilder var content: Content
    var body: some View { content }
}

private extension View {
    /// A section: a frosted, lighter layer on the clear glass panel (user
    /// request, like the system display menu's top section), 12 pt corners.
    func groupBox() -> some View { modifier(SectionBackground()) }
}

private struct SectionBackground: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        content.background {
            // Mostly opaque window colour: readable over any wallpaper.
            shape.fill(Color(nsColor: .windowBackgroundColor).opacity(0.75))
                .overlay(shape.strokeBorder(Color.white.opacity(colorScheme == .dark ? 0.12 : 0.6), lineWidth: 0.5))
        }
    }
}
