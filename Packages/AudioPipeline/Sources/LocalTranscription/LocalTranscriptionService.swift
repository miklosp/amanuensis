import Foundation

public actor LocalTranscriptionService {
    private let fluidAudio: any LocalTranscriptionEngine
    private let whisperKit: any LocalTranscriptionEngine
    private let indicConformer: any LocalTranscriptionEngine

    public init(fluidAudio: any LocalTranscriptionEngine, whisperKit: any LocalTranscriptionEngine,
                indicConformer: any LocalTranscriptionEngine) {
        self.fluidAudio = fluidAudio
        self.whisperKit = whisperKit
        self.indicConformer = indicConformer
    }

    private func resolve(_ modelID: String) throws -> (LocalModel, any LocalTranscriptionEngine) {
        guard let m = LocalModelCatalog.model(id: modelID) else { throw LocalTranscriptionError.unsupportedModel(modelID) }
        switch m.runner {
        case .whisperKit: return (m, whisperKit)
        case .indicConformer: return (m, indicConformer)
        case .fluidAudioParakeet, .fluidAudioSenseVoice, .fluidAudioCohere: return (m, fluidAudio)
        }
    }

    private var residentID: String?
    private var loadingID: String?       // model whose preload is in flight (may be evicted by a reentrant delete)

    public func residentModelID() -> String? { residentID }

    public func preload(modelID: String) async throws {
        if residentID == modelID { return }
        if let old = residentID, let (_, e) = try? resolve(old) { await e.unloadResident() }
        residentID = nil                 // old engine (if any) is now unloaded; nothing resident until the new load succeeds
        let (m, e) = try resolve(modelID)
        loadingID = modelID
        do {
            try await e.preload(m)
        } catch {
            if loadingID == modelID { loadingID = nil }
            throw error
        }
        // The actor can run `delete(modelID:)` during the await above; if it deleted
        // this model it cleared loadingID. Don't publish a just-deleted model as
        // resident — drop what we loaded and bail.
        guard loadingID == modelID else { await e.unloadResident(); return }
        loadingID = nil
        residentID = modelID
    }

    public func unloadResident() async {
        if let old = residentID, let (_, e) = try? resolve(old) { await e.unloadResident() }
        residentID = nil
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
    public func delete(modelID: String) async throws {
        let (m, e) = try resolve(modelID)
        // Clear both flags synchronously (no await between) so an in-flight preload
        // for this model can't publish it as resident after its load resumes.
        if residentID == modelID || loadingID == modelID {
            residentID = nil
            loadingID = nil
            await e.unloadResident()
        }
        try await e.delete(m)
    }
}
