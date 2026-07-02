import Foundation

public enum LocalRunner: String, Codable, Sendable, Hashable {
    case fluidAudioParakeet      // AsrManager, version selector
    case fluidAudioSenseVoice    // SenseVoiceManager
    case fluidAudioCohere        // CoherePipeline
    case whisperKit              // WhisperKit
}

public struct LocalModel: Identifiable, Hashable, Sendable {
    public let id: String
    public let displayName: String
    public let summary: String
    public let languages: String
    public let approxBytes: Int64
    public let runner: LocalRunner
    public let selector: String   // version case name or WhisperKit variant id
    public let recommended: Bool
}

public enum LocalModelCatalog {
    private static let MB: Int64 = 1_000_000
    public static let all: [LocalModel] = [
        LocalModel(id: "parakeet-tdt-ctc-110m", displayName: "Parakeet TDT-CTC 110M",
                   summary: "Tiny and fastest. Best default for English.",
                   languages: "English", approxBytes: 217 * MB,
                   runner: .fluidAudioParakeet, selector: "tdtCtc110m", recommended: true),
        LocalModel(id: "parakeet-tdt-v3", displayName: "Parakeet TDT v3",
                   summary: "Multilingual, auto-detects language.",
                   languages: "25 European languages", approxBytes: 460 * MB,
                   runner: .fluidAudioParakeet, selector: "v3", recommended: false),
        LocalModel(id: "cohere-transcribe", displayName: "Cohere Transcribe",
                   summary: "High accuracy. Heavier; transcribes long audio in 35s chunks.",
                   languages: "14 languages (incl. Japanese, Chinese, Korean)", approxBytes: 2_090 * MB,
                   runner: .fluidAudioCohere, selector: "cohere", recommended: false),
        LocalModel(id: "whisper-large-v3-turbo", displayName: "Whisper large-v3-turbo",
                   summary: "Broad language coverage, near-large-v3 accuracy.",
                   languages: "99 languages", approxBytes: 627 * MB,
                   runner: .whisperKit, selector: "openai_whisper-large-v3-v20240930_626MB", recommended: false),
        LocalModel(id: "parakeet-tdt-ja", displayName: "Parakeet TDT Japanese",
                   summary: "Dedicated Japanese model.",
                   languages: "Japanese", approxBytes: 590 * MB,
                   runner: .fluidAudioParakeet, selector: "tdtJa", recommended: false),
        LocalModel(id: "sensevoice-small", displayName: "SenseVoice Small",
                   summary: "Fast multilingual; strong on Chinese.",
                   languages: "50+ (Chinese, Japanese, Korean, English…)", approxBytes: 450 * MB,
                   runner: .fluidAudioSenseVoice, selector: "fp16", recommended: false),
    ]
    public static func model(id: String) -> LocalModel? { all.first { $0.id == id } }

    /// The id a local-model picker should fall back to when `current` isn't among
    /// `downloaded` (empty setting, or the saved model was deleted): the first
    /// downloaded id, or nil when `current` is already valid or nothing is downloaded.
    public static func defaultedSelection(current: String, downloaded: [String]) -> String? {
        guard !downloaded.contains(current), let first = downloaded.first else { return nil }
        return first
    }
}
