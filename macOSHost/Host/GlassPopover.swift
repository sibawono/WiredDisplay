import AppKit

/// The menu bar panel as a clear Liquid Glass panel, like the system's own
/// menu bar menus (user request; NSPopover draws a much more opaque material).
/// It keeps the small part of NSPopover's API the status menu uses: show
/// under the status item, close on a click elsewhere or Escape, follow the
/// content's preferred size (keeping the top edge under the menu bar).
@MainActor
final class GlassPopover {
    var contentViewController: NSViewController?
    var contentSize: NSSize = .zero
    var onShow: (() -> Void)?
    var onClose: (() -> Void)?

    private var panel: KeyPanel?
    private var monitors: [Any] = []
    private var sizeObservation: NSKeyValueObservation?
    static let cornerRadius: CGFloat = 18

    var isShown: Bool { panel?.isVisible == true }
    var window: NSWindow? { panel }

    private final class KeyPanel: NSPanel {
        override var canBecomeKey: Bool { true }
        override func cancelOperation(_ sender: Any?) { onEscape?() }
        var onEscape: (() -> Void)?
    }

    func show(below view: NSView) {
        guard let controller = contentViewController, let anchorWindow = view.window else { return }
        performClose()
        let size = contentSize == .zero ? controller.view.fittingSize : contentSize
        let anchor = anchorWindow.convertToScreen(view.convert(view.bounds, to: nil))
        let visible = (anchorWindow.screen ?? NSScreen.main)?.visibleFrame ?? anchor
        let x = min(max(anchor.midX - size.width / 2, visible.minX + 8), visible.maxX - size.width - 8)
        let frame = NSRect(x: x, y: anchor.minY - 6 - size.height, width: size.width, height: size.height)

        let panel = KeyPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel],
                             backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .popUpMenu
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.isReleasedWhenClosed = false
        panel.onEscape = { [weak self] in self?.performClose() }

        controller.view.frame = NSRect(origin: .zero, size: size)
        controller.view.autoresizingMask = [.width, .height]
        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView(frame: NSRect(origin: .zero, size: size))
            glass.style = .regular // .clear left the text unreadable over busy wallpapers (user report)
            glass.cornerRadius = Self.cornerRadius
            glass.contentView = controller.view
            panel.contentView = glass
        } else {
            let effect = NSVisualEffectView(frame: NSRect(origin: .zero, size: size))
            effect.material = .popover
            effect.state = .active
            effect.wantsLayer = true
            effect.layer?.cornerRadius = Self.cornerRadius
            effect.layer?.masksToBounds = true
            effect.addSubview(controller.view)
            panel.contentView = effect
        }
        self.panel = panel
        panel.makeKeyAndOrderFront(nil)

        // Follow the content's height (tabs differ) with the top edge fixed.
        sizeObservation = controller.observe(\.preferredContentSize, options: [.new]) { [weak self] controller, _ in
            MainActor.assumeIsolated {
                guard let self, let panel = self.panel else { return }
                let wanted = controller.preferredContentSize
                guard wanted.height > 0, abs(wanted.height - panel.frame.height) > 0.5 else { return }
                var frame = panel.frame
                frame.origin.y = frame.maxY - wanted.height
                frame.size.height = wanted.height
                panel.setFrame(frame, display: true)
            }
        }
        // A click in another app (or on the desktop) closes it, like a menu.
        if let monitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.performClose() }
        }) { monitors.append(monitor) }
        onShow?()
    }

    func performClose() {
        guard let panel else { return }
        self.panel = nil
        sizeObservation = nil
        monitors.forEach(NSEvent.removeMonitor)
        monitors.removeAll()
        panel.orderOut(nil)
        onClose?()
    }
}
