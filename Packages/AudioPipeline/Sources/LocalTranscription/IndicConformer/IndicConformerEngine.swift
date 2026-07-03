import FluidAudio
import Foundation

/// On-device transcription engine backed by IndicConformer (RNN-T, 7 Indic languages).
///
/// Mirrors `WhisperKitEngine`'s resident-cache + guard pattern. Handles the
/// `indicConformer` runner.
public actor IndicConformerEngine: LocalTranscriptionEngine {
    public init() {}

    // MARK: - Resident model cache

    private var residentModelID: String?
    private var resident: IndicConformerModels?

    private func root() throws -> URL { try IndicConformerModelStore.root() }

    // MARK: - LocalTranscriptionEngine

    public func isDownloaded(_ model: LocalModel) async -> Bool {
        (try? root()).map { IndicConformerModelStore.isDownloaded(root: $0) } ?? false
    }

    public func installedBytes(_ model: LocalModel) async -> Int64 {
        (try? root()).map { ModelStorage.directorySize($0) } ?? 0
    }

    public func download(_ model: LocalModel, progress: @escaping @Sendable (Double) -> Void) async throws {
        try await IndicConformerModelStore.download(root: try root(), progress: progress)
    }

    public func delete(_ model: LocalModel) async throws {
        if residentModelID == model.id { resident = nil; residentModelID = nil }
        let root = try root()
        if FileManager.default.fileExists(atPath: root.path) { try FileManager.default.removeItem(at: root) }
    }

    /// Load the model bundle and keep it resident for warm reuse. Only marks the
    /// resident slot AFTER the load succeeds, so a throwing load leaves the engine
    /// with no partially-set resident (a prior resident, if any, survives).
    public func preload(_ model: LocalModel) async throws {
        let models = try await IndicConformerModels.load(root: try root())
        resident = models
        residentModelID = model.id
    }

    public func unloadResident() async {
        resident = nil
        residentModelID = nil
    }

    public func transcribe(audioURL: URL, model: LocalModel, language: String?) async throws -> String {
        // IndicConformer has no auto-detect: require an explicit supported language
        // rather than silently defaulting to Hindi for an unsupported request.
        guard let lang = IndicConformerLanguage.supported(language) else {
            throw LocalTranscriptionError.transcriptionFailed(
                "IndicConformer needs an explicit supported language (\(IndicConformerLanguage.supportedCodes)); "
                + "got \(language.map { "\"\($0)\"" } ?? "none").")
        }
        guard await isDownloaded(model) else {
            throw LocalTranscriptionError.modelNotDownloaded(model.displayName)
        }
        // Reuse the resident bundle if it's this model; otherwise load a
        // transient one and let it go — the resident slot is untouched.
        let models: IndicConformerModels
        if model.id == residentModelID, let cached = resident {
            models = cached
        } else {
            models = try await IndicConformerModels.load(root: try root())
        }

        let samples = try AudioConverter().resampleAudioFile(audioURL)

        let sr = IndicConformerConfig.sampleRate
        let chunkSize = max(1, Int(IndicConformerConfig.chunkSeconds * Double(sr)))
        let stepSize = max(1, Int((IndicConformerConfig.chunkSeconds - IndicConformerConfig.overlapSeconds) * Double(sr)))
        let decoder = IndicConformerGreedyDecoder(inference: try models.makeInference())  // fresh per-transcribe session

        var tokenChunks: [[Int]] = []
        var start = 0
        while start < samples.count {
            let end = min(start + chunkSize, samples.count)
            let chunk = Array(samples[start..<end])
            let ids = try await decoder.decodeChunk(audio: chunk, language: lang)
            if !ids.isEmpty { tokenChunks.append(ids) }
            if end == samples.count { break }
            start += stepSize
        }

        guard !tokenChunks.isEmpty else { return "" }
        let mergedIds = IndicConformerMerger.mergeTokens(tokenChunks)
        return models.vocab.decode(mergedIds, language: lang)
    }
}
