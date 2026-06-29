import CoreAudio
import Foundation
import os

// Detects whether any process OTHER than us is currently capturing the
// microphone, via the per-process Core Audio HAL API (macOS 14.4+):
// kAudioHardwarePropertyProcessObjectList → per-process
// kAudioProcessPropertyIsRunningInput, excluding our own PID. Unlike
// MicActivityMonitor (device-level IsRunningSomewhere), this stays meaningful
// while WE hold the mic — which the mic-off cue needs, since recording opens
// our own mic. We only read HAL properties, so this trips no privacy indicator.
//
// The instance polls on a timer (run only while recording) and reports changes.
// The static probe is also reused by the mic-ON cue to exclude our own usage.
// RecordingCore is nonisolated-by-default, so the class is explicitly @MainActor
// and the poll task reports on the main actor.
@MainActor
public final class OtherInputActivityMonitor {
    private var pollTask: Task<Void, Never>?
    private let pollInterval: Duration

    public init(pollInterval: Duration = .milliseconds(1500)) {
        self.pollInterval = pollInterval
    }

    // Idempotent: a second start() while already running is ignored. Reports the
    // baseline immediately, then only when the value changes.
    public func start(onChange: @escaping @Sendable @MainActor (Bool) -> Void) {
        guard pollTask == nil else { return }
        let interval = pollInterval
        pollTask = Task { @MainActor in
            var last: Bool?
            while !Task.isCancelled {
                let others = Self.othersUsingMic()
                if others != last {
                    last = others
                    onChange(others)
                }
                try? await Task.sleep(for: interval)
            }
        }
    }

    public func stop() {
        pollTask?.cancel()
        pollTask = nil
    }

    // MARK: - Stateless probe (shared with the mic-ON cue)

    // True iff some process other than `pid` is currently running audio input.
    public nonisolated static func othersUsingMic(excludingPID pid: pid_t = getpid()) -> Bool {
        for process in processObjectIDs() {
            guard processPID(process) != pid else { continue }
            if isRunningInput(process) { return true }
        }
        return false
    }

    // MARK: - nonisolated Core Audio helpers

    nonisolated private static func processObjectIDs() -> [AudioObjectID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        let sizeStatus = AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize
        )
        guard sizeStatus == noErr, dataSize > 0 else { return [] }
        let count = Int(dataSize) / MemoryLayout<AudioObjectID>.size
        var ids = [AudioObjectID](repeating: AudioObjectID(kAudioObjectUnknown), count: count)
        let dataStatus = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize, &ids
        )
        guard dataStatus == noErr else { return [] }
        return ids
    }

    nonisolated private static func processPID(_ process: AudioObjectID) -> pid_t {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyPID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var pid: pid_t = -1
        var size = UInt32(MemoryLayout<pid_t>.size)
        let status = AudioObjectGetPropertyData(process, &address, 0, nil, &size, &pid)
        guard status == noErr else { return -1 }
        return pid
    }

    nonisolated private static func isRunningInput(_ process: AudioObjectID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyIsRunningInput,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(process, &address, 0, nil, &size, &value)
        guard status == noErr else { return false }
        return value != 0
    }

    nonisolated private static let log = Logger(
        subsystem: "work.miklos.amanuensis", category: "otherinputmonitor"
    )
}
