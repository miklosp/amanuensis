// OpenAIRealtimeDecoderTests.swift
import Foundation
import Testing
@testable import AudioPipelineJobs

@Suite struct OpenAIRealtimeDecoding {
    @Test func decodesDeltaEvent() {
        let e = OpenAIRealtimeDecoder.decode(#"{"type":"conversation.item.input_audio_transcription.delta","delta":"the pat"}"#)
        #expect(e == .delta("the pat"))
    }
    @Test func decodesCompletedEvent() {
        let e = OpenAIRealtimeDecoder.decode(#"{"type":"conversation.item.input_audio_transcription.completed","transcript":"the patient presented"}"#)
        #expect(e == .completed("the patient presented"))
    }
    @Test func otherEventTypesAreIgnored() {
        #expect(OpenAIRealtimeDecoder.decode(#"{"type":"session.updated"}"#) == .ignored)
        #expect(OpenAIRealtimeDecoder.decode(#"{"type":"input_audio_buffer.speech_started"}"#) == .ignored)
        #expect(OpenAIRealtimeDecoder.decode(#"{"type":"error","error":{"message":"bad"}}"#) == .ignored)
    }
    @Test func deltaWithoutTextIsIgnored() {
        #expect(OpenAIRealtimeDecoder.decode(#"{"type":"conversation.item.input_audio_transcription.delta"}"#) == .ignored)
    }
    @Test func completedWithoutTranscriptIsIgnored() {
        #expect(OpenAIRealtimeDecoder.decode(#"{"type":"conversation.item.input_audio_transcription.completed"}"#) == .ignored)
    }
    @Test func malformedJSONIsIgnored() {
        #expect(OpenAIRealtimeDecoder.decode("not json at all") == .ignored)
    }

    // Folder: deltas are incremental text that accumulates into the current
    // hypothesis; a `completed` event emits its authoritative transcript once as
    // `.final` and resets the delta buffer.
    @Test func folderAccumulatesDeltasThenCommitsOnCompleted() {
        var folder = OpenAITranscriptFolder()
        #expect(folder.fold(.delta("the ")) == [.partial("the")])
        #expect(folder.fold(.delta("patient")) == [.partial("the patient")])
        #expect(folder.fold(.completed("the patient presented")) == [.final("the patient presented")])
        // Next segment starts clean.
        #expect(folder.fold(.delta("next")) == [.partial("next")])
    }
    @Test func folderIgnoredEmitsNothing() {
        var folder = OpenAITranscriptFolder()
        #expect(folder.fold(.ignored) == [])
    }
    @Test func folderEmptyDeltaEmitsNothing() {
        var folder = OpenAITranscriptFolder()
        #expect(folder.fold(.delta("")) == [])
    }
}
