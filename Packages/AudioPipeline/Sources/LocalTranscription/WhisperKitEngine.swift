import Foundation
import WhisperKit

/// On-device transcription engine backed by WhisperKit.
///
/// Handles the `whisperKit` runner. Overrides the download base to Application Support
/// so models never land in `~/Documents/huggingface` under App Sandbox.
///
/// On-disk path for a variant:
///   `ModelStorage.runnerDir(.whisperKit)/models/argmaxinc/whisperkit-coreml/<selector>/`
///
/// This matches what `WhisperKit.download(variant:downloadBase:)` writes:
///   `HubApi.localRepoLocation` → `downloadBase/models/argmaxinc/whisperkit-coreml`
///   then `WhisperKit.download` appends the resolved variantPath (= selector).
public actor WhisperKitEngine: LocalTranscriptionEngine {
    public init() {}

    // MARK: - Path helper

    /// Returns the on-disk directory WhisperKit writes for a given variant.
    /// Used by `isDownloaded`, `installedBytes`, `delete`, and `transcribe` — all
    /// four must target the SAME path to stay consistent with the download.
    private func variantDir(_ model: LocalModel) throws -> URL {
        try ModelStorage.runnerDir(.whisperKit)
            .appendingPathComponent(
                "models/argmaxinc/whisperkit-coreml/\(model.selector)",
                isDirectory: true
            )
    }

    // MARK: - LocalTranscriptionEngine

    public func isDownloaded(_ model: LocalModel) async -> Bool {
        (try? variantDir(model)).map { FileManager.default.fileExists(atPath: $0.path) } ?? false
    }

    public func installedBytes(_ model: LocalModel) async -> Int64 {
        (try? variantDir(model)).map { ModelStorage.directorySize($0) } ?? 0
    }

    public func download(_ model: LocalModel, progress: @escaping @Sendable (Double) -> Void) async throws {
        let base = try ModelStorage.runnerDir(.whisperKit)
        _ = try await WhisperKit.download(
            variant: model.selector,
            downloadBase: base,
            progressCallback: { p in progress(p.fractionCompleted) }
        )
    }

    public func delete(_ model: LocalModel) async throws {
        try FileManager.default.removeItem(at: try variantDir(model))
    }

    public func transcribe(audioURL: URL, model: LocalModel, language: String?) async throws -> String {
        guard await isDownloaded(model) else {
            throw LocalTranscriptionError.modelNotDownloaded(model.displayName)
        }
        // Pass modelFolder explicitly so WhisperKit loads the pre-downloaded model
        // without attempting a network download. With download: false and no modelFolder
        // the WhisperKit init leaves self.modelFolder nil and skips loadModels entirely
        // (init line: `if config.load ?? (config.modelFolder != nil)`).
        let folder = try variantDir(model).path
        let pipe = try await WhisperKit(WhisperKitConfig(
            modelFolder: folder,
            download: false
        ))
        // A blank language must actually auto-detect. WhisperKit's DecodingOptions
        // defaults detectLanguage to false and prefills English when language is nil
        // (TextDecoder prefill uses Constants.defaultLanguageCode == "en"), so pass
        // detectLanguage when no language is given — otherwise blank silently forces English.
        let opts = DecodingOptions(language: language, detectLanguage: language == nil, chunkingStrategy: .vad)
        let results = try await pipe.transcribe(audioPath: audioURL.path, decodeOptions: opts)
        return results.map(\.text).joined(separator: " ")
    }
}
