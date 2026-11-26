import AppKit
import SwiftUI

// The panel's interactive controls are AppKit's own (user request): on
// macOS 26 they carry the system Liquid Glass behaviour themselves (the
// slider thumb turns into a glass lens while held, the segmented control's
// selection slides as glass between segments), which a SwiftUI restyle does
// not reproduce. Each wrapper is a thin NSViewRepresentable with target-action
// into a binding.

/// NSSegmentedControl (select one) bound to an index. Segments are SF
/// Symbols or titles; they fill the available width equally.
struct NativeSegmented: NSViewRepresentable {
    enum Segment {
        case symbol(String, help: String)
        case title(String)
        case titled(String, symbol: String)
    }

    let segments: [Segment]
    @Binding var selection: Int
    var controlSize: NSControl.ControlSize = .large
    var fontSize: CGFloat? = nil
    var isEnabled = true

    func makeNSView(context: Context) -> NSSegmentedControl {
        let control = NSSegmentedControl()
        control.segmentCount = segments.count
        control.trackingMode = .selectOne
        control.segmentDistribution = .fillEqually
        control.controlSize = controlSize
        if let fontSize { control.font = .systemFont(ofSize: fontSize) }
        // Kit "Segmented Control" (selectable): the selected segment is filled
        // with the accent blue, not the neutral grey AppKit uses in popovers.
        control.selectedSegmentBezelColor = .controlAccentColor
        for (index, segment) in segments.enumerated() {
            switch segment {
            case .symbol(let name, let help):
                control.setImage(NSImage(systemSymbolName: name, accessibilityDescription: help), forSegment: index)
                control.setToolTip(help, forSegment: index)
                control.setImageScaling(.scaleProportionallyDown, forSegment: index)
            case .title(let title):
                control.setLabel(title, forSegment: index)
            case .titled(let title, let symbol):
                let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
                    .withSymbolConfiguration(.init(pointSize: 10, weight: .medium))
                control.setImage(image, forSegment: index)
                control.setLabel(title, forSegment: index)
                control.setImageScaling(.scaleNone, forSegment: index)
            }
        }
        control.target = context.coordinator
        control.action = #selector(Coordinator.changed(_:))
        control.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return control
    }

    func updateNSView(_ control: NSSegmentedControl, context: Context) {
        context.coordinator.binding = $selection
        control.isEnabled = isEnabled
        if control.selectedSegment != selection { control.selectedSegment = selection }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSSegmentedControl, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? nsView.intrinsicContentSize.width, height: nsView.intrinsicContentSize.height)
    }

    func makeCoordinator() -> Coordinator { Coordinator(binding: $selection) }

    @MainActor final class Coordinator: NSObject {
        var binding: Binding<Int>
        init(binding: Binding<Int>) { self.binding = binding }
        @objc func changed(_ sender: NSSegmentedControl) { binding.wrappedValue = sender.selectedSegment }
    }
}

/// NSSlider (continuous) bound to a Double in 0...1. Like the switch, its
/// knob becomes a larger glass lens while dragged (kit "Sliders": 25 x 20 pt
/// when clicked), so it also sits in an unclipped container with `overflow`
/// points of room, taken back in SwiftUI with negative padding.
struct NativeSlider: NSViewRepresentable {
    @Binding var value: Double
    var isEnabled = true
    static let overflow: CGFloat = 10
    @MainActor static let sliderHeight = NSSlider().intrinsicContentSize.height

    final class Container: NSView {
        let control = NSSlider(value: 0.5, minValue: 0, maxValue: 1, target: nil, action: nil)
        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            layer?.masksToBounds = false
            clipsToBounds = false
            control.isContinuous = true
            control.translatesAutoresizingMaskIntoConstraints = false
            addSubview(control)
            let inset = NativeSlider.overflow
            NSLayoutConstraint.activate([
                control.leadingAnchor.constraint(equalTo: leadingAnchor, constant: inset),
                control.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -inset),
                control.centerYAnchor.constraint(equalTo: centerYAnchor),
            ])
        }
        required init?(coder: NSCoder) { fatalError("not used") }
        override func hitTest(_ point: NSPoint) -> NSView? {
            let hit = super.hitTest(point)
            return hit === self ? nil : hit
        }
        override func viewDidMoveToSuperview() {
            super.viewDidMoveToSuperview()
            superview?.clipsToBounds = false
            superview?.layer?.masksToBounds = false
        }
    }

    func makeNSView(context: Context) -> Container {
        let container = Container()
        container.control.target = context.coordinator
        container.control.action = #selector(Coordinator.changed(_:))
        container.control.doubleValue = value
        return container
    }

    func updateNSView(_ container: Container, context: Context) {
        context.coordinator.binding = $value
        container.control.isEnabled = isEnabled
        if abs(container.control.doubleValue - value) > 0.0001 { container.control.doubleValue = value }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: Container, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 170, height: nsView.control.intrinsicContentSize.height + 2 * Self.overflow)
    }

    func makeCoordinator() -> Coordinator { Coordinator(binding: $value) }

    @MainActor final class Coordinator: NSObject {
        var binding: Binding<Double>
        init(binding: Binding<Double>) { self.binding = binding }
        @objc func changed(_ sender: NSSlider) { binding.wrappedValue = sender.doubleValue }
    }
}
