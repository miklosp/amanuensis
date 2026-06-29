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
        Self.log.info("off-cue monitor started; input now: \(Self.inputAppsDescription(), privacy: .public)")
        pollTask = Task { @MainActor in
            var last: Bool?
            while !Task.isCancelled {
                let others = Self.othersUsingMic()
                if others != last {
                    last = others
                    Self.log.info("off-cue: another app on mic → \(others, privacy: .public) [\(Self.inputAppsDescription(), privacy: .public)]")
                    onChange(others)
                }
                try? await Task.sleep(for: interval)
            }
        }
    }

    public func stop() {
        if pollTask != nil { Self.log.info("off-cue monitor stopped") }
        pollTask?.cancel()
        pollTask = nil
    }

    // MARK: - Stateless probe (shared with the mic-ON cue)

    // Always-on system speech/assistant daemons that hold a microphone input
    // continuously (Siri / dictation), independent of any meeting. They must be
    // excluded, or "another app is using the mic" would be permanently true and
    // neither cue could ever see an edge. com.apple.CoreSpeech is the confirmed
    // offender (it stays "running input" even with no app recording).
    private nonisolated static let alwaysOnInputDaemons: Set<String> = [
        "com.apple.CoreSpeech",
    ]

    // True iff some process other than `pid` — and other than an always-on
    // system speech daemon — is currently running audio input. The bundle id is
    // only read for processes actually holding input, so the denylist check is
    // cheap.
    public nonisolated static func othersUsingMic(excludingPID pid: pid_t = getpid()) -> Bool {
        for process in processObjectIDs() {
            guard processPID(process) != pid else { continue }
            guard isRunningInput(process) else { continue }
            if alwaysOnInputDaemons.contains(processBundleID(process)) { continue }
            return true
        }
        return false
    }

    // MARK: - Diagnostics

    // Reachability of the per-process audio API under the current sandbox.
    // `status == noErr` means kAudioHardwarePropertyProcessObjectList is
    // readable, so the mic cues' per-process detection works; a non-zero status
    // means App Sandbox is blocking it and both cues would be inert. `count` is
    // the number of audio process objects reported (informational).
    public struct ProcessListReachability: Sendable {
        public let status: OSStatus
        public let count: Int
        public var isReachable: Bool { status == noErr }
    }

    // Reads only the process-list size, so it needs no audio device or
    // permission — it just establishes whether the HAL property is reachable.
    public nonisolated static func probeProcessListReachability() -> ProcessListReachability {
        var address = processListAddress
        var dataSize: UInt32 = 0
        let status = AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize
        )
        let count = status == noErr ? Int(dataSize) / MemoryLayout<AudioObjectID>.size : 0
        return ProcessListReachability(status: status, count: count)
    }

    // Compact list of processes OTHER than us currently running audio input, as
    // "pid:bundleID" ("(daemon)" marks a denylisted always-on one). Logged when
    // the monitor starts and when its verdict flips, so an unexpected always-on
    // input holder (like CoreSpeech) stays diagnosable from the log.
    nonisolated private static func inputAppsDescription() -> String {
        let me = getpid()
        let apps = processObjectIDs().compactMap { obj -> String? in
            let pid = processPID(obj)
            guard pid != me, isRunningInput(obj) else { return nil }
            let bundle = processBundleID(obj)
            let mark = alwaysOnInputDaemons.contains(bundle) ? " (daemon)" : ""
            return "\(pid):\(bundle)\(mark)"
        }
        return apps.isEmpty ? "none" : apps.joined(separator: ", ")
    }

    // MARK: - nonisolated Core Audio helpers

    nonisolated private static var processListAddress: AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
    }

    nonisolated private static func processObjectIDs() -> [AudioObjectID] {
        var address = processListAddress
        var dataSize: UInt32 = 0
        let sizeStatus = AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize
        )
        guard sizeStatus == noErr else {
            Self.log.error("process-object-list size query failed: \(sizeStatus, privacy: .public)")
            return []
        }
        guard dataSize > 0 else { return [] }
        let count = Int(dataSize) / MemoryLayout<AudioObjectID>.size
        var ids = [AudioObjectID](repeating: AudioObjectID(kAudioObjectUnknown), count: count)
        let dataStatus = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize, &ids
        )
        guard dataStatus == noErr else {
            Self.log.error("process-object-list query failed: \(dataStatus, privacy: .public)")
            return []
        }
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

    // The process's bundle id (empty string if unreadable). Used by the
    // always-on-daemon denylist and the diagnostic log. Uses Unmanaged +
    // takeRetainedValue to balance the Copy-rule CFString the HAL returns.
    nonisolated private static func processBundleID(_ process: AudioObjectID) -> String {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyBundleID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = withUnsafeMutablePointer(to: &value) {
            AudioObjectGetPropertyData(process, &address, 0, nil, &size, $0)
        }
        guard status == noErr, let cf = value?.takeRetainedValue() else { return "" }
        return cf as String
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
