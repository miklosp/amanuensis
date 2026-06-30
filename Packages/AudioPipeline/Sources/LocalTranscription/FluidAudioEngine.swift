import Foundation
import FluidAudio

/// On-device transcription engine backed by FluidAudio.
///
/// Handles the `fluidAudioParakeet` runner family (Parakeet TDT 110m / v3 / ja).
/// The `fluidAudioSenseVoice` and `fluidAudioCohere` paths are added by Tasks 8 and 10
/// respectively; non-parakeet runners fall through cleanly in the interim.
public actor FluidAudioEngine: LocalTranscriptionEngine {
    public init() {}

    // MARK: - Parakeet version mapping

    private func parakeetVersion(_ selector: String) -> AsrModelVersion {
        switch selector {
        case "v3":          return .v3
        case "v2":          return .v2
        case "tdtCtc110m":  return .tdtCtc110m
        case "tdtJa":       return .tdtJa
        default:            return .v3
        }
    }

    /// Maps an AsrModelVersion to its corresponding public Repo enum case.
    /// Necessary because `AsrModelVersion.repo` is internal in FluidAudio 0.15.4.
    private func parakeetRepo(_ version: AsrModelVersion) -> Repo {
        switch version {
        case .v3:           return .parakeetV3
        case .v2:           return .parakeetV2
        case .tdtCtc110m:   return .parakeetTdtCtc110m
        case .tdtJa:        return .parakeetJa
        }
    }

    // MARK: - LocalTranscriptionEngine

    public func isDownloaded(_ model: LocalModel) async -> Bool {
        guard model.runner == .fluidAudioParakeet,
              let dir = try? ModelStorage.runnerDir(.fluidAudioParakeet)
        else { return false }
        return AsrModels.modelsExist(
            at: dir,
            version: parakeetVersion(model.selector),
            encoderPrecision: .int8
        )
    }

    public func installedBytes(_ model: LocalModel) async -> Int64 {
        guard model.runner == .fluidAudioParakeet,
              let dir = try? ModelStorage.runnerDir(.fluidAudioParakeet)
        else { return 0 }
        let version = parakeetVersion(model.selector)
        let modelDir = dir.deletingLastPathComponent()
            .appendingPathComponent(parakeetRepo(version).folderName)
        return ModelStorage.directorySize(modelDir)
    }

    public func download(
        _ model: LocalModel, progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        guard model.runner == .fluidAudioParakeet else { return }
        let dir = try ModelStorage.runnerDir(.fluidAudioParakeet)
        try await AsrModels.download(
            to: dir,
            version: parakeetVersion(model.selector),
            encoderPrecision: .int8,
            progressHandler: { p in progress(p.fractionCompleted) }
        )
    }

    public func delete(_ model: LocalModel) async throws {
        guard model.runner == .fluidAudioParakeet else { return }
        let dir = try ModelStorage.runnerDir(.fluidAudioParakeet)
        let parentDir = dir.deletingLastPathComponent()
        let version = parakeetVersion(model.selector)
        DownloadUtils.clearModelCache(forRepo: parakeetRepo(version), directory: parentDir)
    }

    public func transcribe(audioURL: URL, model: LocalModel, language: String?) async throws -> String {
        guard await isDownloaded(model) else {
            throw LocalTranscriptionError.modelNotDownloaded(model.displayName)
        }
        let dir = try ModelStorage.runnerDir(.fluidAudioParakeet)
        let version = parakeetVersion(model.selector)
        let models = try await AsrModels.load(from: dir, version: version)
        let asr = AsrManager(config: .default, models: models)
        // language hint is only honoured by the v3 joint decoder
        let lang: Language? = version == .v3 ? language.flatMap { Language(rawValue: $0) } : nil
        var state = try TdtDecoderState(decoderLayers: version.decoderLayers)
        let result = try await asr.transcribe(audioURL, decoderState: &state, language: lang)
        return result.text
    }
}
