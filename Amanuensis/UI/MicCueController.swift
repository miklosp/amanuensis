import AppKit
import SwiftUI

// Owns a single non-activating floating NSPanel that hosts MicCueView, pinned
// top-right under the menu bar. Auto-dismisses after `autoDismissAfter`
// seconds. Both auto-dismiss and the ✕ button invoke the caller's onDismiss;
// the Start button invokes onStart. The panel never activates the app (it's a
// menu-bar accessory), so it won't steal focus from the meeting.
@MainActor
final class MicCueController {
    private var panel: NSPanel?
    private var dismissTask: Task<Void, Never>?
    private let autoDismissAfter: TimeInterval

    init(autoDismissAfter: TimeInterval = 8) {
        self.autoDismissAfter = autoDismissAfter
    }

    func show(onStart: @escaping () -> Void, onDismiss: @escaping () -> Void) {
        hide()   // enforce a single instance

        let view = MicCueView(
            onStart: { [weak self] in self?.hide(); onStart() },
            onDismiss: { [weak self] in self?.hide(); onDismiss() }
        )
        let hosting = NSHostingView(rootView: view)
        hosting.frame.size = hosting.fittingSize

        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: hosting.fittingSize),
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = false
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.contentView = hosting
        position(panel)
        panel.orderFrontRegardless()
        self.panel = panel

        dismissTask = Task { @MainActor [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: .seconds(self.autoDismissAfter))
            guard !Task.isCancelled, self.panel != nil else { return }
            self.hide()
            onDismiss()
        }
    }

    func hide() {
        dismissTask?.cancel()
        dismissTask = nil
        panel?.orderOut(nil)
        panel = nil
    }

    private func position(_ panel: NSPanel) {
        guard let screen = NSScreen.main else { return }
        let visible = screen.visibleFrame
        let size = panel.frame.size
        let inset: CGFloat = 12
        panel.setFrameOrigin(NSPoint(
            x: visible.maxX - size.width - inset,
            y: visible.maxY - size.height - inset
        ))
    }
}
