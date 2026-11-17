import AppKit
import SwiftUI

// The menu bar panel (popover): an icon tab bar over cards, in the style of
// modern menu bar utilities. Pure views over a snapshot, so it can be
// rendered without a session (`--render-panel`).

struct PanelSnapshot {
    struct Paired: Identifiable, Equatable {
        var id: String { key }
        var name: String
        var key: String
    }

    var stateText = "Waiting for the iPad on USB"
    var stateColor: Color = .orange
    var connectedFor: String?
    var looksLike: String?
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
    var autoSwitchMicrophone = true
    var paired: [Paired] = []
    var connectionCode: String?
    var openAtLogin = false
    var loginNeedsApproval = false
    var version = "0.0"
}

struct PanelActions {
    var setBrightness: (Float) -> Void = { _ in }
    var setQuality: (QualityPreset) -> Void = { _ in }
    var setInput: (Bool) -> Void = { _ in }
    var setOpenAtLogin: (Bool) -> Void = { _ in }
    var setAutoSwitchAudio: (Bool) -> Void = { _ in }
    var setAutoSwitchMicrophone: (Bool) -> Void = { _ in }
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
        VStack(spacing: 14) {
            header
            tabBar
            VStack(alignment: .leading, spacing: 8) {
                Text(model.tab.title.uppercased())
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .padding(.leading, 4)
                content
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            footer
        }
        .padding(16)
        .frame(width: 360)
    }

    // MARK: header and tabs

    private var header: some View {
        HStack(spacing: 12) {
            Image(nsImage: NSApp?.applicationIconImage ?? NSImage(named: NSImage.applicationIconName) ?? NSImage())
                .resizable()
                .frame(width: 40, height: 40)
            VStack(alignment: .leading, spacing: 3) {
                Text("WiredDisplay").font(.system(size: 14, weight: .semibold))
                HStack(spacing: 6) {
                    Circle().fill(s.stateColor).frame(width: 7, height: 7)
                    Text(s.stateText).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                }
                if let connectedFor = s.connectedFor {
                    Text(connectedFor).font(.system(size: 11)).foregroundStyle(.tertiary)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 4)
    }

    private var tabBar: some View {
        HStack(spacing: 4) {
            ForEach(PanelModel.Tab.allCases) { tab in
                Button { model.tab = tab } label: {
                    Image(systemName: tab.symbol)
                        .font(.system(size: 16))
                        .frame(maxWidth: .infinity, minHeight: 36)
                        .foregroundStyle(model.tab == tab ? Color.accentColor : .secondary)
                        .background(model.tab == tab ? Color.accentColor.opacity(0.15) : .clear,
                                    in: RoundedRectangle(cornerRadius: 9))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(tab.title)
            }
        }
        .padding(5)
        .background(RoundedRectangle(cornerRadius: 13).fill(.quaternary.opacity(0.5)))
        .overlay(RoundedRectangle(cornerRadius: 13).strokeBorder(.separator.opacity(0.6)))
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
        HStack(spacing: 10) {
            FooterButton(title: "Show Log", symbol: "doc.text.magnifyingglass", action: model.actions.showLog)
            FooterButton(title: "Quit", symbol: "power", action: model.actions.quit)
        }
    }

    // MARK: tabs

    private var displayTab: some View {
        VStack(spacing: 10) {
            Card {
                if let looksLike = s.looksLike {
                    InfoLine(symbol: "rectangle.on.rectangle", title: "Looks like \(looksLike)", detail: s.pixels)
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
                    Text("Brightness").font(.system(size: 12, weight: .medium))
                    HStack(spacing: 10) {
                        Image(systemName: "sun.min").foregroundStyle(.secondary)
                        Slider(value: Binding(get: { Double(s.brightness ?? 0.5) },
                                              set: { model.snapshot.brightness = Float($0); model.actions.setBrightness(Float($0)) }),
                               in: 0...1)
                            .controlSize(.small)
                            .disabled(s.brightness == nil)
                        Image(systemName: "sun.max").foregroundStyle(.secondary)
                    }
                    Text(s.brightness == nil ? "Available while an iPad is connected"
                         : "The iPad's real backlight · also the Mac's brightness keys")
                        .font(.system(size: 11)).foregroundStyle(.tertiary)
                }
            }
            Card {
                Text("Quality").font(.system(size: 12, weight: .medium))
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
                    ForEach(QualityPreset.allCases, id: \.self) { preset in
                        Chip(title: preset.shortTitle, subtitle: preset.formatTitle, selected: preset == s.quality) {
                            model.snapshot.quality = preset
                            model.actions.setQuality(preset)
                        }
                    }
                }
                if let quality = s.quality {
                    Text(quality.detail).font(.system(size: 11)).foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            LinkRow(title: "Display Settings…", symbol: "arrow.up.forward.app", action: model.actions.openDisplaySettings)
        }
    }

    private var inputTab: some View {
        VStack(spacing: 10) {
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
                Text("Shortcuts on the iPad keyboard").font(.system(size: 12, weight: .medium))
                ShortcutLine(keys: "⌃ Tab", mac: "⌘ Tab", what: "Switch apps")
                ShortcutLine(keys: "⌃ Space", mac: "⌘ Space", what: "Spotlight")
                ShortcutLine(keys: "⌃ ⇧ 3 / 4 / 5", mac: "⌘ ⇧ 3 / 4 / 5", what: "Screenshot")
                ShortcutLine(keys: "⌃ ↑  ⌃ ← →", mac: nil, what: "Mission Control · Spaces")
                Text("Pinch and rotate work on the touch screen and the trackpad.")
                    .font(.system(size: 11)).foregroundStyle(.tertiary)
            }
        }
    }

    private var audioTab: some View {
        VStack(spacing: 10) {
            Card {
                StatusLine(symbol: s.speaker ? "speaker.wave.2.fill" : "speaker.slash", title: "Mac sound on iPad",
                           detail: "Output device “iPad Speaker”", on: s.speaker)
                CardDivider()
                StatusLine(symbol: s.microphone ? "mic.fill" : "mic.slash", title: "iPad microphone",
                           detail: "Input device “iPad Microphone”", on: s.microphone)
                Text("Turn these on or off in the WiredDisplay app on the iPad.")
                    .font(.system(size: 11)).foregroundStyle(.tertiary)
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
        VStack(spacing: 10) {
            if let code = s.connectionCode {
                Card {
                    Text("Connection code").font(.system(size: 12, weight: .medium))
                    Text(code).font(.system(size: 26, weight: .semibold, design: .rounded)).monospacedDigit()
                    Text("Matches the code on the iPad: this session is encrypted end to end.")
                        .font(.system(size: 11)).foregroundStyle(.tertiary)
                }
            }
            Card {
                Text("Paired iPads").font(.system(size: 12, weight: .medium))
                if s.paired.isEmpty {
                    Text("None yet. The next iPad that connects pairs automatically.")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                } else {
                    ForEach(s.paired) { peer in
                        InfoLine(symbol: "ipad.landscape", title: peer.name, detail: "Key \(peer.key)")
                    }
                }
                CardDivider()
                Button(role: .destructive, action: model.actions.forgetPaired) {
                    Label("Forget Paired iPads…", systemImage: "trash")
                        .font(.system(size: 12))
                }
                .buttonStyle(.plain)
                .foregroundStyle(s.paired.isEmpty ? Color.secondary : Color.red)
                .disabled(s.paired.isEmpty)
            }
        }
    }

    private var generalTab: some View {
        VStack(spacing: 10) {
            Card {
                Text("Permissions").font(.system(size: 12, weight: .medium))
                PermissionLine(name: "Screen Recording", purpose: "Shows the Mac screen on the iPad",
                               granted: s.screenRecording, action: model.actions.openScreenRecording)
                CardDivider()
                PermissionLine(name: "Accessibility", purpose: "Input from the iPad and the brightness keys",
                               granted: s.accessibility, action: model.actions.openAccessibility)
            }
            Card {
                ToggleLine(title: "Open at Login",
                           detail: s.loginNeedsApproval ? "Approve WiredDisplay in Login Items" : "The iPad shows the Mac right after a restart",
                           isOn: Binding(get: { s.openAtLogin },
                                         set: { model.snapshot.openAtLogin = $0; model.actions.setOpenAtLogin($0) }))
            }
            Text("WiredDisplay \(s.version)")
                .font(.system(size: 11)).foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity)
        }
    }
}

// MARK: building blocks

private struct Card<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) { content }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 12).fill(.background.opacity(0.55)))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.separator.opacity(0.6)))
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
                Text(title).font(.system(size: 13))
                if let detail { Text(detail).font(.system(size: 11)).foregroundStyle(.secondary) }
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
                Text(title).font(.system(size: 13))
                Text(detail).font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Text(on ? "On" : "Off")
                .font(.system(size: 11, weight: .semibold))
                .padding(.horizontal, 8).padding(.vertical, 3)
                .foregroundStyle(on ? Color.green : .secondary)
                .background(Capsule().fill(on ? Color.green.opacity(0.15) : Color.secondary.opacity(0.12)))
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
                Text(title).font(.system(size: 13))
                Text(detail).font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Toggle("", isOn: $isOn).toggleStyle(.switch).controlSize(.small).labelsHidden()
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
                Text(name).font(.system(size: 13))
                Text(purpose).font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            if !granted {
                Button("Grant…", action: action).controlSize(.small)
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
            Text(text).font(.system(size: 12)).foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Button(button, action: action).controlSize(.small)
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
                .padding(.horizontal, 7).padding(.vertical, 3)
                .background(RoundedRectangle(cornerRadius: 5).fill(.quaternary))
            if let mac {
                Image(systemName: "arrow.right").font(.system(size: 9)).foregroundStyle(.tertiary)
                Text(mac).font(.system(size: 11, design: .rounded)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Text(what).font(.system(size: 12)).foregroundStyle(.secondary)
        }
    }
}

private struct Chip: View {
    let title: String
    let subtitle: String
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 2) {
                Text(title).font(.system(size: 12, weight: .semibold))
                Text(subtitle).font(.system(size: 10)).foregroundStyle(selected ? Color.accentColor : .secondary)
            }
            .frame(maxWidth: .infinity, minHeight: 40)
            .foregroundStyle(selected ? Color.accentColor : .primary)
            .background(RoundedRectangle(cornerRadius: 9)
                .fill(selected ? Color.accentColor.opacity(0.15) : Color.secondary.opacity(0.1)))
            .overlay(RoundedRectangle(cornerRadius: 9)
                .strokeBorder(selected ? Color.accentColor.opacity(0.6) : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private struct LinkRow: View {
    let title: String
    let symbol: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack {
                Text(title).font(.system(size: 12))
                Spacer()
                Image(systemName: symbol).font(.system(size: 11))
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 10).strokeBorder(.separator.opacity(0.6)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private struct FooterButton: View {
    let title: String
    let symbol: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .font(.system(size: 13))
                .frame(maxWidth: .infinity, minHeight: 34)
                .foregroundStyle(.secondary)
                .background(RoundedRectangle(cornerRadius: 10).strokeBorder(.separator.opacity(0.8)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

extension QualityPreset {
    var shortTitle: String { title.components(separatedBy: " — ").first ?? title }
    var formatTitle: String {
        switch self {
        case .balanced: return "Hybrid · 10-bit"
        case .pro: return "4:2:0 · 10-bit"
        case .ultra: return "4:4:4 · 10-bit"
        case .highColor: return "4:4:4 · 8-bit"
        }
    }
}
