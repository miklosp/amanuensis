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

    // MARK: - Resident model cache

    /// One loaded handle, tagged by the runner it belongs to. Exactly one of
    /// these is resident at a time; a transcribe for a different model loads a
    /// transient handle instead and never touches this slot.
    private enum FluidResident {
        case parakeet(AsrManager)
        case senseVoice(SenseVoiceManager)
        case cohere(CoherePipeline.LoadedModels)
    }

    private var residentModelID: String?
    private var resident: FluidResident?

    // MARK: - Load helpers (shared by preload + transient transcribe path)

    private func loadParakeetManager(_ model: LocalModel) async throws -> AsrManager {
        let dir = try ModelStorage.runnerDir(.fluidAudioParakeet)
        let version = parakeetVersion(model.selector)
        let models = try await AsrModels.load(from: dir, version: version)
        return AsrManager(config: .default, models: models)
    }

    private func loadSenseVoiceManager(_ model: LocalModel) throws -> SenseVoiceManager {
        guard let dir = senseVoiceModelDir() else {
            throw LocalTranscriptionError.modelNotDownloaded(model.displayName)
        }
        let svModels = try SenseVoiceModels.load(from: dir, precision: .fp16)
        return SenseVoiceManager(models: svModels)
    }

    private func loadCohereModels() async throws -> CoherePipeline.LoadedModels {
        let dir = try cohereModelDir()
        // Encoder, decoder, and vocab live in the same staged dir.
        return try await CoherePipeline.loadModels(encoderDir: dir, decoderDir: dir, vocabDir: dir)
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

    /// Load the model for `model` and keep it resident for warm reuse. Only marks
    /// the resident slot AFTER the load succeeds, so a throwing load leaves the
    /// engine with no partially-set resident (a prior resident, if any, survives).
    public func preload(_ model: LocalModel) async throws {
        switch model.runner {
        case .fluidAudioParakeet:
            let asr = try await loadParakeetManager(model)
            resident = .parakeet(asr)
            residentModelID = model.id
        case .fluidAudioSenseVoice:
            let senseVoice = try loadSenseVoiceManager(model)
            resident = .senseVoice(senseVoice)
            residentModelID = model.id
        case .fluidAudioCohere:
            let models = try await loadCohereModels()
            resident = .cohere(models)
            residentModelID = model.id
        default:
            return
        }
    }

    public func unloadResident() async {
        resident = nil
        residentModelID = nil
    }

    public func transcribe(audioURL: URL, model: LocalModel, language: String?) async throws -> String {
        guard await isDownloaded(model) else {
            throw LocalTranscriptionError.modelNotDownloaded(model.displayName)
        }
        switch model.runner {
        case .fluidAudioParakeet:
            let version = parakeetVersion(model.selector)
            // Reuse the resident manager if it's this model; otherwise load a
            // transient one and let it go — the resident slot is untouched.
            let asr: AsrManager
            if model.id == residentModelID, case .parakeet(let cached) = resident {
                asr = cached
            } else {
                asr = try await loadParakeetManager(model)
            }
            // language hint is only honoured by the v3 joint decoder
            let lang: Language? = version == .v3 ? language.flatMap { Language(rawValue: $0) } : nil
            var state = try TdtDecoderState(decoderLayers: version.decoderLayers)
            let result = try await asr.transcribe(audioURL, decoderState: &state, language: lang)
            return result.text
        case .fluidAudioSenseVoice:
            let senseVoice: SenseVoiceManager
            if model.id == residentModelID, case .senseVoice(let cached) = resident {
                senseVoice = cached
            } else {
                senseVoice = try loadSenseVoiceManager(model)
            }
            // SenseVoice language encoding uses Int32 codes; no public map from ISO
            // string exists in FluidAudio 0.15.4, so we pass the default (0 = auto-detect).
            return try await senseVoice.transcribe(audioURL: audioURL)
        case .fluidAudioCohere:
            let models: CoherePipeline.LoadedModels
            if model.id == residentModelID, case .cohere(let cached) = resident {
                models = cached
            } else {
                models = try await loadCohereModels()
            }
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
