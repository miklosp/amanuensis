import AppKit

@MainActor
final class MainWindowLifecycleDelegate: NSObject, NSWindowDelegate {
    private weak var previousDelegate: NSWindowDelegate?
    private var installed = false

    func install(on window: NSWindow) {
        guard !installed else { return }
        installed = true
        previousDelegate = window.delegate
        window.delegate = self

        // Window is already on screen by the time we install — bump policy now
        // so the dock icon appears on first open.
        NSApp.setActivationPolicy(.regular)
    }

    // MARK: - NSWindowDelegate forwarding

    func windowWillClose(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        previousDelegate?.windowWillClose?(notification)
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
