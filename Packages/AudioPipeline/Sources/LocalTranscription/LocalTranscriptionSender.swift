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
        let language = job.fields["language"].flatMap { $0.isEmpty ? nil : $0 }
        return try await service.transcribe(audioURL: audioURL, modelID: job.model, language: language)
    }
}
