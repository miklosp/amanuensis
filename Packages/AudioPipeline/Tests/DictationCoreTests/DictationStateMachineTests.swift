import Testing
@testable import DictationCore

@Test func toggleLoopThroughInsert() {
    var m = DictationStateMachine()
    #expect(m.startOrToggle() == .beginCapture)
    #expect(m.phase == .listening)
    #expect(m.startOrToggle() == .endCaptureAndTranscribe)
    #expect(m.phase == .transcribing)
    #expect(m.transcriptReady("hello world") == .insert("hello world"))
    #expect(m.phase == .inserting)
    #expect(m.inserted() == .none)
    #expect(m.phase == .idle)
}

@Test func pttUsesReleaseToStop() {
    var m = DictationStateMachine()
    #expect(m.startOrToggle() == .beginCapture)     // pttStart routes here
    #expect(m.release() == .endCaptureAndTranscribe)
    #expect(m.phase == .transcribing)
}

@Test func triggerDuringTranscribeIsIgnored() {
    var m = DictationStateMachine()
    _ = m.startOrToggle()
    _ = m.startOrToggle()                            // now .transcribing
    #expect(m.startOrToggle() == .none)
    #expect(m.phase == .transcribing)
}

@Test func emptyTranscriptReturnsToIdle() {
    var m = DictationStateMachine()
    _ = m.startOrToggle(); _ = m.startOrToggle()
    #expect(m.transcriptReady("   \n ") == .showEmpty)
    #expect(m.phase == .idle)
}

@Test func failureFromTranscribingShowsErrorAndResets() {
    var m = DictationStateMachine()
    _ = m.startOrToggle(); _ = m.startOrToggle()
    #expect(m.failed("boom") == .showError("boom"))
    #expect(m.phase == .idle)
}

@Test func releaseWhenIdleIsNoop() {
    var m = DictationStateMachine()
    #expect(m.release() == .none)
    #expect(m.phase == .idle)
}

@Test func failureFromListeningResetsToIdle() {
    var m = DictationStateMachine()
    #expect(m.startOrToggle() == .beginCapture)   // -> .listening
    #expect(m.failed("no provider") == .showError("no provider"))
    #expect(m.phase == .idle)
}

@Test func failedFromIdleIsNoop() {
    var m = DictationStateMachine()
    #expect(m.failed("x") == .none)
    #expect(m.phase == .idle)
}
