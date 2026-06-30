import Foundation
import FluidAudio

/// On-device transcription engine backed by FluidAudio.
///
/// Handles the `fluidAudioParakeet` and `fluidAudioSenseVoice` runner families.
/// The `fluidAudioCohere` path is added by Task 10; non-handled runners fall through
/// cleanly in the interim.
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

    // MARK: - SenseVoice path helpers

    /// Returns the directory where FluidAudio stores SenseVoice Small models.
    ///
    /// `SenseVoiceModels.download` has no `to:` parameter — it always writes to
    /// `Application Support/FluidAudio/Models/sensevoice-small-coreml`. This helper
    /// mirrors that private logic so we can check existence, measure size, and delete
    /// without triggering a download.
    private func senseVoiceModelDir() -> URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("FluidAudio/Models", isDirectory: true)
            .appendingPathComponent(Repo.senseVoiceSmall.folderName, isDirectory: true)
    }

    // MARK: - Cohere path helpers

    /// Returns the directory the staged Cohere Transcribe repo lives in.
    ///
    /// Cohere has no auto-download. `DownloadUtils.downloadRepo(.cohereTranscribeCoreml,
    /// to:)` writes files to `<to>/<Repo.folderName>`, where `folderName` is
    /// `"cohere-transcribe/q8"`. Encoder, decoder, and vocab all share this single
    /// directory, so `loadModels` receives it for all three. Keeping this helper as
    /// the one source of truth keeps download/isDownloaded/installedBytes/delete in
    /// agreement about where the files actually land.
    private func cohereModelDir() throws -> URL {
        try ModelStorage.runnerDir(.fluidAudioCohere)
            .appendingPathComponent(Repo.cohereTranscribeCoreml.folderName, isDirectory: true)
    }

    /// Maps the engine's ISO language string to Cohere's explicit language enum.
    ///
    /// Cohere requires the language up front (it conditions generation on it).
    /// Defaults to English when the caller passes nil or a code Cohere doesn't
    /// support (its 14 supported languages use ISO raw values: en, fr, de, …).
    private func cohereLanguage(_ language: String?) -> CohereAsrConfig.Language {
        language.flatMap { CohereAsrConfig.Language(rawValue: $0) } ?? .english
    }

    // MARK: - LocalTranscriptionEngine

    public func isDownloaded(_ model: LocalModel) async -> Bool {
        switch model.runner {
        case .fluidAudioParakeet:
            guard let dir = try? ModelStorage.runnerDir(.fluidAudioParakeet) else { return false }
            return AsrModels.modelsExist(
                at: dir,
                version: parakeetVersion(model.selector),
                encoderPrecision: .int8
            )
        case .fluidAudioSenseVoice:
            guard let dir = senseVoiceModelDir() else { return false }
            return SenseVoiceModels.modelsExist(at: dir, precision: .fp16)
        case .fluidAudioCohere:
            guard let dir = try? cohereModelDir() else { return false }
            let fm = FileManager.default
            // The three files CoherePipeline.loadModels needs (default .v2 decoder).
            let required = [
                ModelNames.CohereTranscribe.encoderCompiledFile,
                ModelNames.CohereTranscribe.decoderCacheExternalV2CompiledFile,
                ModelNames.CohereTranscribe.vocab,
            ]
            return required.allSatisfy {
                fm.fileExists(atPath: dir.appendingPathComponent($0).path)
            }
        default:
            return false
        }
    }

    public func installedBytes(_ model: LocalModel) async -> Int64 {
        switch model.runner {
        case .fluidAudioParakeet:
            guard let dir = try? ModelStorage.runnerDir(.fluidAudioParakeet) else { return 0 }
            let version = parakeetVersion(model.selector)
            let modelDir = dir.deletingLastPathComponent()
                .appendingPathComponent(parakeetRepo(version).folderName)
            return ModelStorage.directorySize(modelDir)
        case .fluidAudioSenseVoice:
            guard let dir = senseVoiceModelDir() else { return 0 }
            return ModelStorage.directorySize(dir)
        case .fluidAudioCohere:
            guard let dir = try? cohereModelDir() else { return 0 }
            return ModelStorage.directorySize(dir)
        default:
            return 0
        }
    }

    public func download(
        _ model: LocalModel, progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        switch model.runner {
        case .fluidAudioParakeet:
            let dir = try ModelStorage.runnerDir(.fluidAudioParakeet)
            try await AsrModels.download(
                to: dir,
                version: parakeetVersion(model.selector),
                encoderPrecision: .int8,
                progressHandler: { p in progress(p.fractionCompleted) }
            )
        case .fluidAudioSenseVoice:
            // SenseVoiceModels.download has no `to:` parameter — it downloads to
            // Application Support/FluidAudio/Models/sensevoice-small-coreml.
            _ = try await SenseVoiceModels.download(
                precision: .fp16,
                progressHandler: { p in progress(p.fractionCompleted) }
            )
        case .fluidAudioCohere:
            // No auto-download: stage the repo explicitly. downloadRepo writes to
            // `<dir>/cohere-transcribe/q8` (see cohereModelDir). Its progress is the
            // download half of loadModels and maxes at 0.5, so rescale to a full
            // 0...1 to match the other engines' progress contract.
            let dir = try ModelStorage.runnerDir(.fluidAudioCohere)
            try await DownloadUtils.downloadRepo(
                .cohereTranscribeCoreml,
                to: dir,
                progressHandler: { p in progress(min(1.0, p.fractionCompleted * 2.0)) }
            )
        default:
            return
        }
    }

    public func delete(_ model: LocalModel) async throws {
        switch model.runner {
        case .fluidAudioParakeet:
            let dir = try ModelStorage.runnerDir(.fluidAudioParakeet)
            let parentDir = dir.deletingLastPathComponent()
            let version = parakeetVersion(model.selector)
            DownloadUtils.clearModelCache(forRepo: parakeetRepo(version), directory: parentDir)
        case .fluidAudioSenseVoice:
            guard let modelsRoot = senseVoiceModelDir()?.deletingLastPathComponent() else { return }
            DownloadUtils.clearModelCache(forRepo: .senseVoiceSmall, directory: modelsRoot)
        case .fluidAudioCohere:
            // clearModelCache removes `<directory>/<Repo.folderName>`, i.e. the same
            // `cohere-transcribe/q8` subtree downloadRepo populated.
            let dir = try ModelStorage.runnerDir(.fluidAudioCohere)
            DownloadUtils.clearModelCache(forRepo: .cohereTranscribeCoreml, directory: dir)
        default:
            return
        }
    }

    public func transcribe(audioURL: URL, model: LocalModel, language: String?) async throws -> String {
        guard await isDownloaded(model) else {
            throw LocalTranscriptionError.modelNotDownloaded(model.displayName)
        }
        switch model.runner {
        case .fluidAudioParakeet:
            let dir = try ModelStorage.runnerDir(.fluidAudioParakeet)
            let version = parakeetVersion(model.selector)
            let models = try await AsrModels.load(from: dir, version: version)
            let asr = AsrManager(config: .default, models: models)
            // language hint is only honoured by the v3 joint decoder
            let lang: Language? = version == .v3 ? language.flatMap { Language(rawValue: $0) } : nil
            var state = try TdtDecoderState(decoderLayers: version.decoderLayers)
            let result = try await asr.transcribe(audioURL, decoderState: &state, language: lang)
            return result.text
        case .fluidAudioSenseVoice:
            guard let dir = senseVoiceModelDir() else {
                throw LocalTranscriptionError.modelNotDownloaded(model.displayName)
            }
            let svModels = try SenseVoiceModels.load(from: dir, precision: .fp16)
            let senseVoice = SenseVoiceManager(models: svModels)
            // SenseVoice language encoding uses Int32 codes; no public map from ISO
            // string exists in FluidAudio 0.15.4, so we pass the default (0 = auto-detect).
            return try await senseVoice.transcribe(audioURL: audioURL)
        case .fluidAudioCohere:
            let dir = try cohereModelDir()
            // Encoder, decoder, and vocab live in the same staged dir.
            let models = try await CoherePipeline.loadModels(
                encoderDir: dir, decoderDir: dir, vocabDir: dir)
            // Cohere wants [Float] @ 16 kHz mono, not a URL.
            let samples = try AudioConverter().resampleAudioFile(audioURL)
            // transcribeLong slides the 35 s encoder window so audio over the
            // single-call cap is chunked rather than silently truncated.
            let pipeline = CoherePipeline()
            let result = try await pipeline.transcribeLong(
                audio: samples, models: models, language: cohereLanguage(language))
            return result.text
        default:
            throw LocalTranscriptionError.modelNotDownloaded(model.displayName)
        }
    }
}
