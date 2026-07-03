// SonioxRealtimeDecoderTests.swift
import Foundation
import Testing
@testable import AudioPipelineJobs

@Suite struct SonioxRealtimeDecoding {
    @Test func decodesFinalAndNonFinalTokens() {
        let f = SonioxRealtimeDecoder.decode(#"{"tokens":[{"text":"the ","is_final":true},{"text":"pat","is_final":false}]}"#)
        #expect(f.tokens == [SonioxToken(text: "the ", isFinal: true),
                             SonioxToken(text: "pat", isFinal: false)])
        #expect(f.finished == false)
    }
    @Test func missingIsFinalDefaultsToNonFinal() {
        let f = SonioxRealtimeDecoder.decode(#"{"tokens":[{"text":"hi"}]}"#)
        #expect(f.tokens == [SonioxToken(text: "hi", isFinal: false)])
    }
    @Test func malformedFrameIsEmpty() {
        let f = SonioxRealtimeDecoder.decode("not json")
        #expect(f.tokens.isEmpty)
        #expect(f.finished == false)
    }

    // Folder: final tokens accumulate; non-final is the revising tail; a
    // `finished` frame emits the completed segment once and resets.
    @Test func folderEmitsRevisingPartialsThenOneFinal() {
        var folder = SonioxTranscriptFolder()
        let e1 = folder.fold(.init(tokens: [.init(text: "the ", isFinal: true),
                                            .init(text: "pat", isFinal: false)], finished: false))
        #expect(e1 == [.partial("the pat")])
        let e2 = folder.fold(.init(tokens: [.init(text: "patient", isFinal: true)], finished: false))
        #expect(e2 == [.partial("the patient")])
        let e3 = folder.fold(.init(tokens: [], finished: true))
        #expect(e3 == [.final("the patient")])
        // Next segment starts clean.
        let e4 = folder.fold(.init(tokens: [.init(text: "next", isFinal: false)], finished: false))
        #expect(e4 == [.partial("next")])
    }
}
