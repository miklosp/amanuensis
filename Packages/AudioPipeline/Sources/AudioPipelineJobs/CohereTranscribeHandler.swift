import Foundation

// Cohere audio transcription (the "cohereTranscribe" shape). Wire-identical to
// the OpenAI multipart shape except the endpoint path is /v2 and `language` is
// required, so this reuses TranscriptionMultipartHandler entirely, passing
// Cohere's path. Required-language is enforced at the Job-editor Save gate via
// the FieldSpec, matching how the multipart handler validates (it doesn't).
//
//   POST {baseURL}/v2/audio/transcriptions
//   Authorization: Bearer <key>
//   multipart: model, language (required), temperature?, file
//   response: {"text": "..."}
public struct DefaultCohereSender: AudioJobSending {
    public static let transcriptionsPath = "/v2/audio/transcriptions"

    public init() {}

    public func send(job: Job, provider: Provider, audioURL: URL, apiKey: String) async throws -> String {
        try await TranscriptionMultipartHandler.send(
            job: job, provider: provider, audioURL: audioURL, apiKey: apiKey,
            path: Self.transcriptionsPath)
    }
}
