// DeepgramRealtimeDecoderTests.swift
import Foundation
import Testing
@testable import AudioPipelineJobs

@Suite struct DeepgramRealtimeDecoding {
    @Test func decodesFinalResultsFrame() {
        let f = DeepgramRealtimeDecoder.decode(#"{"type":"Results","is_final":true,"speech_final":true,"channel":{"alternatives":[{"transcript":"the patient","confidence":0.99}]}}"#)
        #expect(f == DeepgramFrame(transcript: "the patient", isFinal: true, speechFinal: true))
    }
    @Test func decodesInterimResultsFrame() {
        let f = DeepgramRealtimeDecoder.decode(#"{"type":"Results","is_final":false,"speech_final":false,"channel":{"alternatives":[{"transcript":"the pat"}]}}"#)
        #expect(f == DeepgramFrame(transcript: "the pat", isFinal: false, speechFinal: false))
    }
    @Test func missingFlagsDefaultToFalse() {
        let f = DeepgramRealtimeDecoder.decode(#"{"type":"Results","channel":{"alternatives":[{"transcript":"hi"}]}}"#)
        #expect(f == DeepgramFrame(transcript: "hi", isFinal: false, speechFinal: false))
    }
    @Test func emptyAlternativesDecodesToEmptyTranscript() {
        let f = DeepgramRealtimeDecoder.decode(#"{"type":"Results","is_final":true,"speech_final":true,"channel":{"alternatives":[]}}"#)
        #expect(f == DeepgramFrame(transcript: "", isFinal: true, speechFinal: true))
    }
    @Test func nonResultsTypeIsIgnored() {
        #expect(DeepgramRealtimeDecoder.decode(#"{"type":"Metadata","request_id":"abc"}"#) == nil)
        #expect(DeepgramRealtimeDecoder.decode(#"{"type":"UtteranceEnd","last_word_end":1.2}"#) == nil)
    }
    @Test func malformedJSONIsIgnored() {
        #expect(DeepgramRealtimeDecoder.decode("not json at all") == nil)
    }

    // Folder: disjoint is_final chunks accumulate (space-joined); interims are the
    // revising tail; a speech_final frame emits the utterance once and resets.
    @Test func folderAccumulatesFinalsAndEmitsOneFinalOnSpeechFinal() {
        var folder = DeepgramTranscriptFolder()
        #expect(folder.fold(.init(transcript: "the pat", isFinal: false, speechFinal: false)) == [.partial("the pat")])
        #expect(folder.fold(.init(transcript: "the patient", isFinal: true, speechFinal: false)) == [.partial("the patient")])
        #expect(folder.fold(.init(transcript: "presented", isFinal: false, speechFinal: false)) == [.partial("the patient presented")])
        #expect(folder.fold(.init(transcript: "presented today", isFinal: true, speechFinal: true)) == [.final("the patient presented today")])
        // Next segment starts clean.
        #expect(folder.fold(.init(transcript: "next", isFinal: false, speechFinal: false)) == [.partial("next")])
    }
    @Test func folderEmptyInterimEmitsNothing() {
        var folder = DeepgramTranscriptFolder()
        #expect(folder.fold(.init(transcript: "", isFinal: false, speechFinal: false)) == [])
    }
    @Test func folderSpeechFinalOnTrailingSilenceCommitsAccumulated() {
        var folder = DeepgramTranscriptFolder()
        _ = folder.fold(.init(transcript: "the patient", isFinal: true, speechFinal: false))
        #expect(folder.fold(.init(transcript: "", isFinal: true, speechFinal: true)) == [.final("the patient")])
    }
}
