import Foundation
import Testing
@testable import AudioPipelineJobs

@Suite struct JobShapeBehavior {
    @Test func rawValues_areStable() {
        #expect(JobShape.chatCompletionsAudio.rawValue == "chatCompletionsAudio")
        #expect(JobShape.transcriptionMultipart.rawValue == "transcriptionMultipart")
        #expect(JobShape.elevenLabsScribe.rawValue == "elevenLabsScribe")
        #expect(JobShape.geminiGenerateContent.rawValue == "geminiGenerateContent")
    }

    @Test func codable_roundTrip() throws {
        for shape in JobShape.allCases {
            let data = try JSONEncoder().encode(shape)
            let decoded = try JSONDecoder().decode(JobShape.self, from: data)
            #expect(decoded == shape)
        }
    }
}

@Suite struct JobShapeFields {
    @Test func chatCompletionsAudio_hasPromptAndTemperature() {
        let keys = JobShape.chatCompletionsAudio.fields.map(\.key)
        #expect(keys.contains("prompt"))
        #expect(keys.contains("temperature"))
    }

    @Test func chatCompletionsAudio_hasReasoningEffort() {
        let keys = JobShape.chatCompletionsAudio.fields.map(\.key)
        #expect(keys.contains("reasoning_effort"))
    }

    @Test func transcriptionMultipart_hasLanguageAndResponseFormat() {
        let keys = JobShape.transcriptionMultipart.fields.map(\.key)
        #expect(keys.contains("language"))
        #expect(keys.contains("response_format"))
    }

    @Test func elevenLabsScribe_usesItsOwnFieldNames() {
        let keys = JobShape.elevenLabsScribe.fields.map(\.key)
        #expect(keys.contains("language_code"))
        #expect(keys.contains("diarize"))
    }

    @Test func gemini_hasThinkingBudget() {
        let keys = JobShape.geminiGenerateContent.fields.map(\.key)
        #expect(keys.contains("thinkingBudget"))
    }

    @Test(arguments: JobShape.allCases)
    func allShapes_haveAtLeastOneField(shape: JobShape) {
        #expect(!shape.fields.isEmpty)
    }
}

@Suite struct JobShapeBaseURLHint {
    @Test func chatCompletionsAudio_appendsChatCompletions() {
        #expect(JobShape.chatCompletionsAudio.baseURLPathHint == "/v1/chat/completions")
    }

    @Test func transcriptionMultipart_appendsAudioTranscriptions() {
        #expect(JobShape.transcriptionMultipart.baseURLPathHint == "/v1/audio/transcriptions")
    }

    @Test func elevenLabsScribe_appendsSpeechToText() {
        #expect(JobShape.elevenLabsScribe.baseURLPathHint == "/v1/speech-to-text")
    }

    @Test func gemini_appendsModelAndGenerateContent() {
        #expect(JobShape.geminiGenerateContent.baseURLPathHint == "/models/{model}:generateContent")
    }
}

@Suite struct JobShapeRequiresModel {
    @Test func onlyReson8_doesNotRequireModel() {
        for shape in JobShape.allCases {
            #expect(shape.requiresModel == (shape != .reson8Prerecorded),
                    "unexpected requiresModel for \(shape)")
        }
    }
}
