import Foundation

public actor LocalTranscriptionService {
    private let fluidAudio: any LocalTranscriptionEngine
    private let whisperKit: any LocalTranscriptionEngine

    public init(fluidAudio: any LocalTranscriptionEngine, whisperKit: any LocalTranscriptionEngine) {
        self.fluidAudio = fluidAudio
        self.whisperKit = whisperKit
    }

    private func resolve(_ modelID: String) throws -> (LocalModel, any LocalTranscriptionEngine) {
        guard let m = LocalModelCatalog.model(id: modelID) else { throw LocalTranscriptionError.unsupportedModel(modelID) }
        switch m.runner {
        case .whisperKit: return (m, whisperKit)
        case .fluidAudioParakeet, .fluidAudioSenseVoice, .fluidAudioCohere: return (m, fluidAudio)
        }
    }

    public func transcribe(audioURL: URL, modelID: String, language: String?) async throws -> String {
        let (m, e) = try resolve(modelID)
        return try await e.transcribe(audioURL: audioURL, model: m, language: language)
    }
    public func isDownloaded(modelID: String) async throws -> Bool { let (m, e) = try resolve(modelID); return await e.isDownloaded(m) }
    public func installedBytes(modelID: String) async throws -> Int64 { let (m, e) = try resolve(modelID); return await e.installedBytes(m) }
    public func download(modelID: String, progress: @escaping @Sendable (Double) -> Void) async throws {
        let (m, e) = try resolve(modelID); try await e.download(m, progress: progress)
    }
    public func delete(modelID: String) async throws { let (m, e) = try resolve(modelID); try await e.delete(m) }
}
