import AppKit

@MainActor
final class MainWindowLifecycleDelegate: NSObject, NSWindowDelegate {
    private weak var previousDelegate: NSWindowDelegate?

    func install(on window: NSWindow) {
        // Re-install whenever we're not already the delegate on this window.
        // Window(id:) is a singleton scene in SwiftUI, so on reopen the same
        // delegate instance is reused — we cannot rely on a one-shot flag.
        guard window.delegate !== self else { return }
        previousDelegate = window.delegate
        window.delegate = self

        NSApp.setActivationPolicy(.regular)
        // Policy flip alone doesn't always materialise the dock icon; an
        // explicit activate prompts AppKit to update.
        NSApp.activate()
    }

    // MARK: - NSWindowDelegate forwarding

    func windowWillClose(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        // Restore the previous delegate so on the next open (same singleton
        // scene, same delegate instance) `window.delegate !== self` is true
        // and `install(on:)` runs again to bump policy back to .regular.
        if let window = notification.object as? NSWindow, window.delegate === self {
            window.delegate = previousDelegate
        }
        previousDelegate?.windowWillClose?(notification)
        previousDelegate = nil
    }

    override func responds(to aSelector: Selector!) -> Bool {
        if super.responds(to: aSelector) { return true }
        return previousDelegate?.responds(to: aSelector) ?? false
    }

    override func forwardingTarget(for aSelector: Selector!) -> Any? {
        if previousDelegate?.responds(to: aSelector) == true {
            return previousDelegate
        }
        return super.forwardingTarget(for: aSelector)
    }
}
