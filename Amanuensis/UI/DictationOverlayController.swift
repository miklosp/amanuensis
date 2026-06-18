import AppKit
import SwiftUI
import DictationCore

/// Optional bottom-center HUD. Non-activating panel; mirrors MicCueController.
@MainActor
final class DictationOverlayController {
    private var panel: NSPanel?
    private var phase: DictationStateMachine.Phase = .idle
    private var level: Float = 0
    private var flashTask: Task<Void, Never>?

    /// Show/hide based on phase + the user's overlay preference.
    func update(phase: DictationStateMachine.Phase, enabled: Bool) {
        self.phase = phase
        guard enabled, phase != .idle else { hide(); return }
        render()
    }

    /// Brief transient message (clipboard fallback / errors / empty).
    func flash(_ message: String) {
        showText(message)
        flashTask?.cancel()
        flashTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard let self, !Task.isCancelled else { return }
            if self.phase == .idle { self.hide() }
        }
    }

    private func render() {
        present(AnyView(DictationOverlayView(phase: phase, level: level)))
    }

    private func showText(_ message: String) {
        present(AnyView(
            Text(message)
                .font(.callout)
                .padding(.horizontal, 14).padding(.vertical, 8)
                .background(.ultraThinMaterial, in: Capsule())))
    }

    private func present(_ root: AnyView) {
        let hosting = NSHostingView(rootView: root)
        hosting.layout()
        if panel == nil {
            let p = NSPanel(
                contentRect: NSRect(origin: .zero, size: hosting.fittingSize),
                styleMask: [.nonactivatingPanel, .borderless],
                backing: .buffered, defer: false)
            p.isFloatingPanel = true
            p.level = .statusBar
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            p.hidesOnDeactivate = false
            p.backgroundColor = .clear
            p.isOpaque = false
            p.hasShadow = true
            panel = p
        }
        guard let panel else { return }
        panel.contentView = hosting
        panel.setContentSize(hosting.fittingSize)
        position(panel)
        panel.orderFrontRegardless()
    }

    private func hide() {
        panel?.orderOut(nil)
    }

    private func position(_ panel: NSPanel) {
        guard let screen = NSScreen.main else { return }
        let visible = screen.visibleFrame
        let size = panel.frame.size
        panel.setFrameOrigin(NSPoint(
            x: visible.midX - size.width / 2,
            y: visible.minY + 80))
    }
}
