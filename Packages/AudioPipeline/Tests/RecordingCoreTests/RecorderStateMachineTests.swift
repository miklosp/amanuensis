import Foundation
import Testing
@testable import RecordingCore

@Suite struct RecorderStateMachineTransitions {
    // MARK: - start()

    @Test func start_fromIdle_movesToStarting_andRequestsPermissions() {
        var machine = RecorderStateMachine()
        let action = machine.start()

        #expect(action == .requestPermissionsAndStart)
        #expect(machine.phase == .starting)
        #expect(machine.lastError == nil)
    }

    @Test func start_clearsStaleLastError() {
        // Drive through a denied-perm path so lastError is populated, then
        // verify a fresh start() clears it.
        var machine = RecorderStateMachine()
        _ = machine.start()
        _ = machine.permissionsResolved(micGranted: false)
        #expect(machine.lastError != nil)
        #expect(machine.phase == .idle)

        let action = machine.start()
        #expect(action == .requestPermissionsAndStart)
        #expect(machine.phase == .starting)
        #expect(machine.lastError == nil)
    }

    // MARK: - permissionsResolved

    @Test func permissionsResolved_granted_keepsStartingPhase() {
        var machine = RecorderStateMachine()
        _ = machine.start()

        let action = machine.permissionsResolved(micGranted: true)
        #expect(action == .none)
        #expect(machine.phase == .starting)
        #expect(machine.lastError == nil)
    }

    @Test func permissionsResolved_denied_returnsToIdleWithError() {
        var machine = RecorderStateMachine()
        _ = machine.start()

        let action = machine.permissionsResolved(micGranted: false)
        #expect(action == .none)
        #expect(machine.phase == .idle)
        let error = try? #require(machine.lastError)
        #expect(error?.contains("Microphone permission denied") == true)
    }

    // MARK: - folderReady → sessionStarted (the happy starting flow)

    @Test func folderReady_emitsStartSessionAndStoresPendingFolder() {
        var machine = RecorderStateMachine()
        _ = machine.start()
        _ = machine.permissionsResolved(micGranted: true)

        let url = URL(filePath: "/tmp/rec/2026-05-25T00-00-00Z", directoryHint: .isDirectory)
        let action = machine.folderReady(name: "2026-05-25T00-00-00Z", url: url)

        #expect(action == .startSession)
        #expect(machine.phase == .starting)  // still starting until sessionStarted
    }

    @Test func sessionStarted_promotesToRecordingWithFolderInfo() {
        var machine = RecorderStateMachine()
        _ = machine.start()
        _ = machine.permissionsResolved(micGranted: true)
        let url = URL(filePath: "/tmp/rec/2026-05-25T00-00-00Z", directoryHint: .isDirectory)
        _ = machine.folderReady(name: "2026-05-25T00-00-00Z", url: url)

        let action = machine.sessionStarted()
        #expect(action == .none)
        #expect(machine.phase == .recording(folderName: "2026-05-25T00-00-00Z", folderURL: url))
    }

    @Test func sessionStarted_withoutFolderReady_isNoOp() {
        var machine = RecorderStateMachine()
        _ = machine.start()
        _ = machine.permissionsResolved(micGranted: true)
        // skip folderReady

        let action = machine.sessionStarted()
        #expect(action == .none)
        #expect(machine.phase == .starting)
    }

    // MARK: - sessionFailed

    @Test func sessionFailed_returnsToIdleWithError() {
        var machine = RecorderStateMachine()
        _ = machine.start()
        _ = machine.permissionsResolved(micGranted: true)

        let action = machine.sessionFailed("device unavailable")
        #expect(action == .none)
        #expect(machine.phase == .idle)
        #expect(machine.lastError == "device unavailable")
    }

    // MARK: - stop → sessionStopped

    @Test func stop_fromRecording_movesToStoppingAndEmitsStopSession() {
        var machine = RecorderStateMachine()
        _ = machine.start()
        _ = machine.permissionsResolved(micGranted: true)
        let url = URL(filePath: "/tmp/rec/X", directoryHint: .isDirectory)
        _ = machine.folderReady(name: "X", url: url)
        _ = machine.sessionStarted()

        let action = machine.stop()
        #expect(action == .stopSession)
        #expect(machine.phase == .stopping)
    }

    @Test func sessionStopped_returnsToIdleSetsFolderURLEmitsConvert() {
        var machine = RecorderStateMachine()
        _ = machine.start()
        _ = machine.permissionsResolved(micGranted: true)
        let url = URL(filePath: "/tmp/rec/X", directoryHint: .isDirectory)
        _ = machine.folderReady(name: "X", url: url)
        _ = machine.sessionStarted()
        _ = machine.stop()

        let action = machine.sessionStopped(folderURL: url)
        #expect(action == .convertOutput(folderURL: url))
        #expect(machine.phase == .idle)
        #expect(machine.lastFolderURL == url)
    }

    // MARK: - conversionFinished

    @Test func conversionFinished_success_doesNotMutate() {
        var machine = RecorderStateMachine()
        // Drive through a full cycle so we're back at .idle with lastFolderURL.
        _ = machine.start()
        _ = machine.permissionsResolved(micGranted: true)
        let url = URL(filePath: "/tmp/rec/X", directoryHint: .isDirectory)
        _ = machine.folderReady(name: "X", url: url)
        _ = machine.sessionStarted()
        _ = machine.stop()
        _ = machine.sessionStopped(folderURL: url)

        let phaseBefore = machine.phase
        let lastErrorBefore = machine.lastError
        let action = machine.conversionFinished(.success(()))
        #expect(action == .none)
        #expect(machine.phase == phaseBefore)
        #expect(machine.lastError == lastErrorBefore)
    }

    @Test func conversionFinished_failure_setsLastErrorButLeavesPhase() {
        var machine = RecorderStateMachine()
        // Run through to .idle.
        _ = machine.start()
        _ = machine.permissionsResolved(micGranted: true)
        let url = URL(filePath: "/tmp/rec/X", directoryHint: .isDirectory)
        _ = machine.folderReady(name: "X", url: url)
        _ = machine.sessionStarted()
        _ = machine.stop()
        _ = machine.sessionStopped(folderURL: url)

        struct FauxError: Error, LocalizedError {
            var errorDescription: String? { "encoder choked" }
        }
        let action = machine.conversionFinished(.failure(FauxError()))
        #expect(action == .none)
        #expect(machine.phase == .idle)
        let error = try? #require(machine.lastError)
        #expect(error?.contains("encoder choked") == true)
    }

    // MARK: - Happy path end-to-end

    @Test func happyPath_sequence_yieldsExpectedActionsAndPhases() {
        var machine = RecorderStateMachine()

        #expect(machine.start() == .requestPermissionsAndStart)
        #expect(machine.phase == .starting)

        #expect(machine.permissionsResolved(micGranted: true) == .none)
        #expect(machine.phase == .starting)

        let url = URL(filePath: "/tmp/rec/2026", directoryHint: .isDirectory)
        #expect(machine.folderReady(name: "2026", url: url) == .startSession)
        #expect(machine.phase == .starting)

        #expect(machine.sessionStarted() == .none)
        #expect(machine.phase == .recording(folderName: "2026", folderURL: url))

        #expect(machine.stop() == .stopSession)
        #expect(machine.phase == .stopping)

        #expect(machine.sessionStopped(folderURL: url) == .convertOutput(folderURL: url))
        #expect(machine.phase == .idle)
        #expect(machine.lastFolderURL == url)
    }
}

// Out-of-phase events: parameterized over (phase, event, ignored fields) for
// every state-machine event. Each case drives the machine into the named
// phase, fires the event, and asserts the event was ignored (.none action,
// phase + side fields unchanged).
@Suite struct RecorderStateMachineOutOfPhaseEvents {
    enum NamedPhase: String, CaseIterable, Sendable {
        case idle, starting, recording, stopping
    }

    // Drives a fresh machine into the requested phase.
    static func machine(in phase: NamedPhase) -> RecorderStateMachine {
        var m = RecorderStateMachine()
        switch phase {
        case .idle:
            return m
        case .starting:
            _ = m.start()
            return m
        case .recording:
            _ = m.start()
            _ = m.permissionsResolved(micGranted: true)
            let url = URL(filePath: "/tmp/rec/x", directoryHint: .isDirectory)
            _ = m.folderReady(name: "x", url: url)
            _ = m.sessionStarted()
            return m
        case .stopping:
            _ = m.start()
            _ = m.permissionsResolved(micGranted: true)
            let url = URL(filePath: "/tmp/rec/x", directoryHint: .isDirectory)
            _ = m.folderReady(name: "x", url: url)
            _ = m.sessionStarted()
            _ = m.stop()
            return m
        }
    }

    @Test(arguments: [NamedPhase.starting, .recording, .stopping])
    func start_outOfPhase_isIgnored(phase: NamedPhase) {
        var m = Self.machine(in: phase)
        let phaseBefore = m.phase
        let action = m.start()
        #expect(action == .none)
        #expect(m.phase == phaseBefore)
    }

    @Test(arguments: [NamedPhase.idle, .recording, .stopping])
    func permissionsResolved_outOfPhase_isIgnored(phase: NamedPhase) {
        var m = Self.machine(in: phase)
        let phaseBefore = m.phase
        let action = m.permissionsResolved(micGranted: true)
        #expect(action == .none)
        #expect(m.phase == phaseBefore)
    }

    @Test(arguments: [NamedPhase.idle, .recording, .stopping])
    func folderReady_outOfPhase_isIgnored(phase: NamedPhase) {
        var m = Self.machine(in: phase)
        let phaseBefore = m.phase
        let url = URL(filePath: "/tmp/oops", directoryHint: .isDirectory)
        let action = m.folderReady(name: "oops", url: url)
        #expect(action == .none)
        #expect(m.phase == phaseBefore)
    }

    @Test(arguments: [NamedPhase.idle, .recording, .stopping])
    func sessionStarted_outOfPhase_isIgnored(phase: NamedPhase) {
        var m = Self.machine(in: phase)
        let phaseBefore = m.phase
        let action = m.sessionStarted()
        #expect(action == .none)
        #expect(m.phase == phaseBefore)
    }

    @Test(arguments: [NamedPhase.idle, .recording, .stopping])
    func sessionFailed_outOfPhase_isIgnored(phase: NamedPhase) {
        var m = Self.machine(in: phase)
        let phaseBefore = m.phase
        let errorBefore = m.lastError
        let action = m.sessionFailed("ignored")
        #expect(action == .none)
        #expect(m.phase == phaseBefore)
        #expect(m.lastError == errorBefore)
    }

    @Test(arguments: [NamedPhase.idle, .starting, .stopping])
    func stop_outOfPhase_isIgnored(phase: NamedPhase) {
        var m = Self.machine(in: phase)
        let phaseBefore = m.phase
        let action = m.stop()
        #expect(action == .none)
        #expect(m.phase == phaseBefore)
    }

    @Test(arguments: [NamedPhase.idle, .starting, .recording])
    func sessionStopped_outOfPhase_isIgnored(phase: NamedPhase) {
        var m = Self.machine(in: phase)
        let phaseBefore = m.phase
        let folderURLBefore = m.lastFolderURL
        let url = URL(filePath: "/tmp/oops", directoryHint: .isDirectory)
        let action = m.sessionStopped(folderURL: url)
        #expect(action == .none)
        #expect(m.phase == phaseBefore)
        #expect(m.lastFolderURL == folderURLBefore)
    }
}

@Suite struct RecorderStateMachineQueries {
    @Test func isRecording_onlyTrueInRecordingPhase() {
        for phase in [RecorderStateMachineOutOfPhaseEvents.NamedPhase.idle, .starting, .recording, .stopping] {
            let m = RecorderStateMachineOutOfPhaseEvents.machine(in: phase)
            #expect(m.isRecording == (phase == .recording))
        }
    }

    @Test func isBusy_trueInStartingAndStopping() {
        for phase in [RecorderStateMachineOutOfPhaseEvents.NamedPhase.idle, .starting, .recording, .stopping] {
            let m = RecorderStateMachineOutOfPhaseEvents.machine(in: phase)
            let expected = (phase == .starting || phase == .stopping)
            #expect(m.isBusy == expected)
        }
    }

    @Test func statusText_perPhase() {
        let idle = RecorderStateMachineOutOfPhaseEvents.machine(in: .idle)
        #expect(idle.statusText == "Idle")

        let starting = RecorderStateMachineOutOfPhaseEvents.machine(in: .starting)
        #expect(starting.statusText == "Starting…")

        let recording = RecorderStateMachineOutOfPhaseEvents.machine(in: .recording)
        #expect(recording.statusText == "Recording: x")

        let stopping = RecorderStateMachineOutOfPhaseEvents.machine(in: .stopping)
        #expect(stopping.statusText == "Stopping…")
    }
}
