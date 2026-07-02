import AppKit
import SwiftUI
import DictationCore

/// Optional bottom-center HUD. Non-activating panel; mirrors FloatingCueController.
///
/// Holds one persistent hosting view bound to `model` for the panel's lifetime,
/// so phase changes cross-fade in SwiftUI (a per-change hosting rebuild can't
/// animate). The panel tracks the pill's animated size via the view's
/// `onResize` callback, and fades in/out on show/hide.
@MainActor
final class DictationOverlayController {
    private var panel: NSPanel?
    private let model = DictationOverlayModel()
    private var phase: DictationStateMachine.Phase = .idle
    private var enabled = false
    private var shown = false
    private var flashing = false
    private var modelLoading = false
    private var flashTask: Task<Void, Never>?

    /// Show/hide based on phase + the user's overlay preference.
    func update(phase: DictationStateMachine.Phase, enabled: Bool) {
        self.phase = phase
        self.enabled = enabled
        // A transient flash owns the panel until it expires; don't clobber it.
        guard !flashing else { return }
        renderPhase()
    }

    /// Overlay a "Loading model…" state on the active session while the
    /// on-device model warms up (see DictationCoordinator). Reverts to the
    /// phase display when cleared.
    func setModelLoading(_ loading: Bool) {
        modelLoading = loading
        guard !flashing else { return }
        renderPhase()
    }

    /// Brief transient message (clipboard fallback / errors / empty), shown
    /// regardless of the ambient-overlay preference; reverts to the phase
    /// display after 2s.
    func flash(_ message: String) {
        flashTask?.cancel()
        flashing = true
        show(.flash(message))
        flashTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard let self, !Task.isCancelled else { return }
            self.flashing = false
            self.renderPhase()
        }
    }

    private func renderPhase() {
        // Only override with "Loading model…" while a session is active (phase
        // maps to a visible state); an idle phase still hides the overlay.
        guard enabled, let state = Self.state(for: phase) else { hide(); return }
        show(modelLoading ? .loadingModel : state)
    }

    private static func state(for phase: DictationStateMachine.Phase) -> DictationOverlayState? {
        switch phase {
        case .idle: return nil
        case .listening: return .listening
        case .transcribing: return .transcribing
        case .inserting: return .inserted
        }
    }

    private func show(_ state: DictationOverlayState) {
        let panel = ensurePanel()
        model.state = state
        guard !shown else { return }
        shown = true
        position(panel)   // best-effort initial placement; fit(to:) refines it
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.22
            panel.animator().alphaValue = 1
        }
    }

    private func hide() {
        guard shown, let panel else { return }
        shown = false
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            panel.animator().alphaValue = 0
        }
        // Order out once the fade finishes — unless a new show re-claimed the
        // panel mid-fade (shown flips back to true), in which case leave it up.
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(220))
            guard let self, !self.shown, let panel = self.panel else { return }
            panel.orderOut(nil)
        }
    }

    /// Resize + reposition the panel to track the pill's (animated) size.
    private func fit(to size: CGSize) {
        guard let panel, size.width > 0, size.height > 0 else { return }
        panel.setContentSize(size)
        position(panel)
    }

    private func ensurePanel() -> NSPanel {
        if let panel { return panel }
        let hosting = NSHostingView(
            rootView: DictationOverlayView(model: model, onResize: { [weak self] in self?.fit(to: $0) }))
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
        p.alphaValue = 0
        p.contentView = hosting
        panel = p
        return p
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
