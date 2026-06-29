import Foundation
import Testing
@testable import AudioPipelineJobs

private func writeAudio(_ bytes: [UInt8]) throws -> URL {
    let url = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("cohere-\(UUID().uuidString).flac")
    try Data(bytes).write(to: url)
    return url
}

@Suite struct CohereTranscribeShape {
    @Test func shape_hasV2TranscriptionsPathHint() {
        #expect(JobShape.cohereTranscribe.baseURLPathHint == "/v2/audio/transcriptions")
    }

    @Test func fields_languageRequired_temperatureOptional_noPrompt() {
        let byKey = Dictionary(uniqueKeysWithValues:
            JobShape.cohereTranscribe.fields.map { ($0.key, $0) })
        #expect(byKey["language"]?.required == true)
        #expect(byKey["temperature"]?.required == false)
        #expect(byKey["prompt"] == nil)
    }
}

@Suite struct CohereTranscribeRequest {
    private func makeProvider() -> Provider {
        Provider(name: "c", presetID: "cohere", baseURL: "https://api.cohere.com",
                 apiKeyRef: KeychainRef(account: "cohere-key"))
    }

    @Test func buildRequest_targetsV2Path_andBearerAuth() throws {
        let job = Job(name: "t", providerID: UUID(), model: "cohere-transcribe-03-2026",
                      fields: ["language": "en"], outputExt: "txt")
        let req = try TranscriptionMultipartHandler.buildRequest(
            job: job, provider: makeProvider(), audioURL: try writeAudio([0x01]),
            apiKey: "k", path: DefaultCohereSender.transcriptionsPath)
        #expect(req.url?.absoluteString == "https://api.cohere.com/v2/audio/transcriptions")
        #expect(req.value(forHTTPHeaderField: "Authorization") == "Bearer k")
    }

    @Test func buildRequest_defaultsToV1_whenPathOmitted() throws {
        // Regression: existing multipart callers (OpenAI/Groq/Mistral) unaffected.
        let provider = Provider(name: "o", presetID: "openai-whisper",
                                baseURL: "https://api.openai.com",
                                apiKeyRef: KeychainRef(account: "k"))
        let job = Job(name: "t", providerID: UUID(), model: "whisper-1",
                      fields: [:], outputExt: "txt")
        let req = try TranscriptionMultipartHandler.buildRequest(
            job: job, provider: provider, audioURL: try writeAudio([0x01]), apiKey: "k")
        #expect(req.url?.absoluteString == "https://api.openai.com/v1/audio/transcriptions")
    }
}

@Suite struct CohereTranscribeDispatch {
    @Test func jobRunner_registersCohereHandler() {
        #expect(JobRunner.defaultHandlers[.cohereTranscribe] != nil)
    }
}
