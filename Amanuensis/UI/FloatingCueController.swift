import AppKit
import SwiftUI

// Owns a single non-activating floating NSPanel pinned top-right under the menu
// bar, hosting an injected SwiftUI cue view. Auto-dismisses after
// `autoDismissAfter` seconds, invoking onAutoDismiss. The panel never activates
// the app (it's a menu-bar accessory), so it won't steal focus from a meeting.
// Shared by the mic-on and mic-off cues — they never overlap in time (idle vs
// recording), so one shared instance also guarantees at most one cue is visible.
@MainActor
final class FloatingCueController {
    private var panel: NSPanel?
    private var dismissTask: Task<Void, Never>?
    private let autoDismissAfter: TimeInterval

    init(autoDismissAfter: TimeInterval = 8) {
        self.autoDismissAfter = autoDismissAfter
    }

    // Shows `content`. The caller wires the content's buttons to call hide()
    // plus their own handlers. onAutoDismiss runs when the auto-dismiss timer
    // fires (mirror the ✕ path so the driving policy stays in sync). Enforces a
    // single instance.
    func show<Content: View>(
        onAutoDismiss: @escaping () -> Void,
        @ViewBuilder content: () -> Content
    ) {
        hide()   // enforce a single instance

        let hosting = NSHostingView(rootView: content())
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
        panel.alphaValue = 0
        panel.contentView = hosting
        position(panel)
        panel.orderFrontRegardless()
        self.panel = panel
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            panel.animator().alphaValue = 1
        }

        dismissTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await Task.sleep(for: .seconds(self.autoDismissAfter))
            } catch {
                return   // cancelled by hide()
            }
            guard self.panel != nil else { return }
            self.hide()
            onAutoDismiss()
        }
    }

    func hide() {
        dismissTask?.cancel()
        dismissTask = nil
        guard let panel else { return }
        self.panel = nil   // release immediately; single-instance stays enforced
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            panel.animator().alphaValue = 0
        } completionHandler: {
            panel.orderOut(nil)
        }
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
