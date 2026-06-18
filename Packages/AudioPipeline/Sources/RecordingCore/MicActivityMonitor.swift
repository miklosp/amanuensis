import CoreAudio
import Foundation
import os

// Watches whether the system's default input device is "running somewhere"
// (in use by any process) via kAudioDevicePropertyDeviceIsRunningSomewhere.
// We never open the mic ourselves — only read a HAL property — so this does
// not trip the mic privacy indicator. Used to detect a likely meeting (another
// app holding the mic) and offer to record.
//
// Scope limitation: only the *default* input device is tracked; a meeting on a
// non-default mic is not detected. RecordingCore is nonisolated-by-default, so
// this class is explicitly @MainActor and the CA listener blocks hop back to
// the main actor.
@MainActor
public final class MicActivityMonitor {
    private let queue = DispatchQueue(
        label: "work.miklos.amanuensis.micmonitor", qos: .utility
    )
    private var onChange: (@Sendable @MainActor (Bool) -> Void)?
    private var deviceID = AudioObjectID(kAudioObjectUnknown)
    private var deviceListenerBlock: AudioObjectPropertyListenerBlock?
    private var defaultDeviceListenerBlock: AudioObjectPropertyListenerBlock?

    public init() {}

    // Idempotent: a second start() while already running is ignored.
    public func start(onChange: @escaping @Sendable @MainActor (Bool) -> Void) {
        guard self.onChange == nil else { return }
        self.onChange = onChange
        installDefaultDeviceListener()
        attachToCurrentDefaultInput()
    }

    public func stop() {
        removeDeviceListener()
        removeDefaultDeviceListener()
        onChange = nil
        deviceID = AudioObjectID(kAudioObjectUnknown)
    }

    // MARK: - default-input-device change listener

    private func installDefaultDeviceListener() {
        var address = Self.defaultInputAddress
        let block: AudioObjectPropertyListenerBlock = { @Sendable [weak self] _, _ in
            Task { @MainActor in
                guard let self else { return }
                self.removeDeviceListener()
                self.attachToCurrentDefaultInput()
            }
        }
        defaultDeviceListenerBlock = block
        let status = AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &address, queue, block
        )
        if status != noErr {
            Self.log.error("add default-input listener failed: \(status, privacy: .public)")
        }
    }

    private func removeDefaultDeviceListener() {
        guard let block = defaultDeviceListenerBlock else { return }
        var address = Self.defaultInputAddress
        AudioObjectRemovePropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &address, queue, block
        )
        defaultDeviceListenerBlock = nil
    }

    // MARK: - per-device IsRunningSomewhere listener

    private func attachToCurrentDefaultInput() {
        // Bail if monitoring has been stopped — a default-device-change callback
        // can be delivered late (after stop()); without this it would re-register
        // a per-device listener that nothing would ever remove.
        guard onChange != nil else { return }
        guard let device = Self.defaultInputDeviceID() else {
            Self.log.error("no default input device")
            return
        }
        deviceID = device

        var address = Self.runningAddress
        let block: AudioObjectPropertyListenerBlock = { @Sendable [weak self] _, _ in
            let running = Self.isRunningSomewhere(device)
            Task { @MainActor in self?.onChange?(running) }
        }
        let status = AudioObjectAddPropertyListenerBlock(device, &address, queue, block)
        guard status == noErr else {
            Self.log.error("add IsRunningSomewhere listener failed: \(status, privacy: .public)")
            deviceID = AudioObjectID(kAudioObjectUnknown)
            return
        }
        deviceListenerBlock = block

        // Report the current state (the baseline on first attach, or the new
        // device's state after a default-device change).
        let running = Self.isRunningSomewhere(device)
        let callback = onChange
        Task { @MainActor in callback?(running) }
    }

    private func removeDeviceListener() {
        guard deviceID != kAudioObjectUnknown, let block = deviceListenerBlock else { return }
        var address = Self.runningAddress
        AudioObjectRemovePropertyListenerBlock(deviceID, &address, queue, block)
        deviceListenerBlock = nil
    }

    // MARK: - nonisolated Core Audio helpers

    nonisolated private static var defaultInputAddress: AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
    }

    nonisolated private static var runningAddress: AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
    }

    nonisolated private static func defaultInputDeviceID() -> AudioObjectID? {
        var deviceID = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var address = defaultInputAddress
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID
        )
        guard status == noErr, deviceID != kAudioObjectUnknown else { return nil }
        return deviceID
    }

    nonisolated private static func isRunningSomewhere(_ device: AudioObjectID) -> Bool {
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        var address = runningAddress
        let status = AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value)
        guard status == noErr else { return false }
        return value != 0
    }

    nonisolated private static let log = Logger(
        subsystem: "work.miklos.amanuensis", category: "micmonitor"
    )
}
