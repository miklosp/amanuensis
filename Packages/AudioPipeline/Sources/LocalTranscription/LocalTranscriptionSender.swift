import Foundation
import AudioPipelineJobs

public struct LocalTranscriptionSender: AudioJobSending {
    private let service: LocalTranscriptionService
    private let diarize: Bool

    public init(service: LocalTranscriptionService, diarize: Bool = false) {
        self.service = service
        self.diarize = diarize
    }

    public func send(job: Job, provider: Provider, audioURL: URL, apiKey: String) async throws -> String {
        guard LocalModelCatalog.model(id: job.model) != nil else {
            throw LocalTranscriptionError.unsupportedModel(job.model)
        }
        // Normalize the persisted language here, at the non-UI dispatch boundary, so a
        // stale/blank/unsupported code (e.g. a job saved before its model existed, or a
        // dictation setting carried over from another model) resolves to the model's
        // default or auto-detect instead of hard-failing an engine's language guard.
        let language = LocalModelCatalog.resolvedLanguage(forModel: job.model, requested: job.fields["language"])
        if diarize {
            return try await service.transcribeDiarized(audioURL: audioURL, modelID: job.model, language: language)
        }
        return try await service.transcribe(audioURL: audioURL, modelID: job.model, language: language)
    }
}
