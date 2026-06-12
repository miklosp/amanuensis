import Foundation
import Testing
@testable import AudioPipelineJobs

@Suite struct SonioxAsyncShape {
    @Test func baseURLPathHint_isTranscriptionsPath() {
        #expect(JobShape.sonioxAsync.baseURLPathHint == "/v1/transcriptions")
    }

    @Test func fields_exposeTheFourChosenKnobs() {
        let keys = JobShape.sonioxAsync.fields.map(\.key)
        #expect(keys == [
            "enable_speaker_diarization",
            "language_hints",
            "enable_language_identification",
            "context",
        ])
    }

    @Test func diarizationField_isCheckbox_andContextIsLongText() {
        let fields = JobShape.sonioxAsync.fields
        let diarize = try? #require(fields.first { $0.key == "enable_speaker_diarization" })
        #expect(diarize?.kind == .checkbox)
        let context = try? #require(fields.first { $0.key == "context" })
        #expect(context?.kind == .longText)
    }
}
