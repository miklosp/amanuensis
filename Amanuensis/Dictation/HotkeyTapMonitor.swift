import AppKit
import CoreGraphics
import DictationCore

/// Observes (never consumes) global key events via a listen-only CGEvent tap,
/// emitting trigger/foreign events. Needs Input Monitoring (sandbox-OK).
/// Must be started on the main thread (the tap source is added to the main
/// run loop, so the C callback runs main-isolated).
@MainActor
final class HotkeyTapMonitor {
    enum Event: Equatable { case triggerDown, triggerUp, foreignInput }

    // Device-dependent modifier bits (IOKit NX_DEVICE*CMDKEYMASK).
    private static let leftCmdBit: UInt64 = 0x0000_0008
    private static let rightCmdBit: UInt64 = 0x0000_0010

    private var trigger: TriggerSide
    private let onEvent: (Event) -> Void
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?

    init(trigger: TriggerSide, onEvent: @escaping (Event) -> Void) {
        self.trigger = trigger
        self.onEvent = onEvent
    }

    static func hasInputMonitoringAccess() -> Bool { CGPreflightListenEventAccess() }

    @discardableResult
    static func requestInputMonitoringAccess() -> Bool { CGRequestListenEventAccess() }

    func setTrigger(_ t: TriggerSide) { trigger = t }

    func start() {
        guard tap == nil else { return }
        let mask = (UInt64(1) << CGEventType.flagsChanged.rawValue)
                 | (UInt64(1) << CGEventType.keyDown.rawValue)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: CGEventMask(mask),
            callback: { _, type, event, refcon in
                guard let refcon else { return Unmanaged.passUnretained(event) }
                let monitor = Unmanaged<HotkeyTapMonitor>.fromOpaque(refcon)
                    .takeUnretainedValue()
                MainActor.assumeIsolated { monitor.handle(type: type, event: event) }
                return Unmanaged.passUnretained(event)
            },
            userInfo: refcon
        ) else { return }
        self.tap = tap
        let source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        self.source = source
        CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    func stop() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetCurrent(), source, .commonModes) }
        tap = nil
        source = nil
    }

    private func handle(type: CGEventType, event: CGEvent) {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
        case .keyDown:
            onEvent(.foreignInput)
        case .flagsChanged:
            let keycode = event.getIntegerValueField(.keyboardEventKeycode)
            if keycode == trigger.keyCode {
                let bit = trigger == .leftCommand ? Self.leftCmdBit : Self.rightCmdBit
                onEvent((event.flags.rawValue & bit) != 0 ? .triggerDown : .triggerUp)
            } else {
                onEvent(.foreignInput)
            }
        default:
            break
        }
    }
}
