#if DEBUG
import AppKit

/// Minimal always-on-top panel showing committed text + a dimmed volatile tail.
@MainActor
final class SpikeOverlayPanel {
    private let panel: NSPanel
    private let label: NSTextField

    init() {
        label = NSTextField(labelWithString: "")
        label.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        label.lineBreakMode = .byTruncatingHead
        label.maximumNumberOfLines = 1
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 44),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: true)
        panel.level = .floating
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.backgroundColor = NSColor.black.withAlphaComponent(0.75)
        let container = NSView(frame: panel.contentRect(forFrameRect: panel.frame))
        label.frame = container.bounds.insetBy(dx: 12, dy: 12)
        label.autoresizingMask = [.width, .height]
        container.addSubview(label)
        panel.contentView = container
        if let screen = NSScreen.main {
            let f = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(x: f.midX - 320, y: f.minY + 80))
        }
    }

    func show() { panel.orderFrontRegardless() }
    func hide() { panel.orderOut(nil) }

    func render(committed: String, volatile: String) {
        let s = NSMutableAttributedString(
            string: committed,
            attributes: [.foregroundColor: NSColor.white])
        s.append(NSAttributedString(
            string: volatile,
            attributes: [.foregroundColor: NSColor.systemYellow.withAlphaComponent(0.7)]))
        label.attributedStringValue = s
    }
}
#endif
