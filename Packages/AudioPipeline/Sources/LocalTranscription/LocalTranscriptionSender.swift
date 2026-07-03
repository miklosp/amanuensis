import Foundation
import AudioPipelineJobs

public struct LocalTranscriptionSender: AudioJobSending {
    private let service: LocalTranscriptionService

    public init(service: LocalTranscriptionService) {
        self.service = service
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
        return try await service.transcribe(audioURL: audioURL, modelID: job.model, language: language)
    }
}
