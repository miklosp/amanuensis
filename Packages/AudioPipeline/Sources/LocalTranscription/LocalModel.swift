import Foundation

public enum LocalRunner: String, Codable, Sendable, Hashable {
    case fluidAudioParakeet      // AsrManager, version selector
    case fluidAudioSenseVoice    // SenseVoiceManager
    case fluidAudioCohere        // CoherePipeline
    case whisperKit              // WhisperKit
    case indicConformer          // IndicConformer (catalog row + service wiring: Task 10)
}

public struct LocalModel: Identifiable, Hashable, Sendable {
    public let id: String
    public let displayName: String
    public let summary: String
    public let languages: String
    public let supportedLanguages: [String]
    public let approxBytes: Int64
    public let runner: LocalRunner
    public let selector: String   // version case name or WhisperKit variant id
    public let recommended: Bool
    /// The language a picker/setting should default to for this model, when set.
    /// Only dedicated- or primary-language models declare one (IndicConformer →
    /// Hindi, the Japanese model → ja, SenseVoice → zh); broad auto-detecting
    /// models leave it nil so no language is forced on them.
    public var defaultLanguage: String? = nil
}

public enum LocalModelCatalog {
    private static let MB: Int64 = 1_000_000
    public static let all: [LocalModel] = [
        LocalModel(id: "parakeet-tdt-ctc-110m", displayName: "Parakeet TDT-CTC 110M",
                   summary: "Tiny and fastest. Best default for English.",
                   languages: "English", supportedLanguages: ["en"],
                   approxBytes: 217 * MB,
                   runner: .fluidAudioParakeet, selector: "tdtCtc110m", recommended: true),
        LocalModel(id: "parakeet-tdt-v3", displayName: "Parakeet TDT v3",
                   summary: "Multilingual, auto-detects language.",
                   languages: "25 European languages",
                   supportedLanguages: [
                       "bg", "hr", "cs", "da", "nl", "en", "et", "fi", "fr", "de",
                       "el", "hu", "it", "lv", "lt", "mt", "pl", "pt", "ro", "sk",
                       "sl", "es", "sv", "ru", "uk",
                   ],
                   approxBytes: 460 * MB,
                   runner: .fluidAudioParakeet, selector: "v3", recommended: false),
        LocalModel(id: "cohere-transcribe", displayName: "Cohere Transcribe",
                   summary: "High accuracy. Heavier; transcribes long audio in 35s chunks.",
                   languages: "14 languages (incl. Japanese, Chinese, Korean)",
                   supportedLanguages: [
                       "en", "fr", "de", "es", "it", "pt", "nl", "pl", "el", "ar",
                       "ja", "zh", "vi", "ko",
                   ],
                   approxBytes: 2_090 * MB,
                   runner: .fluidAudioCohere, selector: "cohere", recommended: false),
        LocalModel(id: "whisper-large-v3-turbo", displayName: "Whisper large-v3-turbo",
                   summary: "Broad language coverage, near-large-v3 accuracy.",
                   languages: "99 languages",
                   supportedLanguages: [
                       "en", "zh", "de", "es", "ru", "ko", "fr", "ja", "pt", "tr",
                       "pl", "ca", "nl", "ar", "sv", "it", "id", "hi", "fi", "vi",
                       "he", "uk", "el", "ms", "cs", "ro", "da", "hu", "ta", "no",
                       "th", "ur", "hr", "bg", "lt", "la", "mi", "ml", "cy", "sk",
                       "te", "fa", "lv", "bn", "sr", "az", "sl", "kn", "et", "mk",
                       "br", "eu", "is", "hy", "ne", "mn", "bs", "kk", "sq", "sw",
                       "gl", "mr", "pa", "si", "km", "sn", "yo", "so", "af", "oc",
                       "ka", "be", "tg", "sd", "gu", "am", "yi", "lo", "uz", "fo",
                       "ht", "ps", "tk", "nn", "mt", "sa", "lb", "my", "bo", "tl",
                       "mg", "as", "tt", "haw", "ln", "ha", "ba", "jw", "su",
                   ],
                   approxBytes: 627 * MB,
                   runner: .whisperKit, selector: "openai_whisper-large-v3-v20240930_626MB", recommended: false),
        LocalModel(id: "parakeet-tdt-ja", displayName: "Parakeet TDT Japanese",
                   summary: "Dedicated Japanese model.",
                   languages: "Japanese", supportedLanguages: ["ja"],
                   approxBytes: 590 * MB,
                   runner: .fluidAudioParakeet, selector: "tdtJa", recommended: false,
                   defaultLanguage: "ja"),
        LocalModel(id: "sensevoice-small", displayName: "SenseVoice Small",
                   summary: "Fast multilingual; strong on Chinese.",
                   languages: "50+ (Chinese, Japanese, Korean, English…)",
                   supportedLanguages: ["zh", "yue", "en", "ja", "ko"],
                   approxBytes: 450 * MB,
                   runner: .fluidAudioSenseVoice, selector: "fp16", recommended: false,
                   defaultLanguage: "zh"),
        LocalModel(id: "indic-conformer-600m", displayName: "IndicConformer 600M",
                   summary: "Best Hindi accuracy. On-device RNN-T; 7 Indic languages.",
                   languages: "Hindi, Bengali, Marathi, Telugu, Tamil, Malayalam, Kannada",
                   supportedLanguages: ["hi", "bn", "mr", "te", "ta", "ml", "kn"],
                   approxBytes: 700 * MB,
                   runner: .indicConformer, selector: "multilingual", recommended: false,
                   defaultLanguage: "hi"),
    ]
    public static func model(id: String) -> LocalModel? { all.first { $0.id == id } }

    /// The id a local-model picker should fall back to when `current` isn't among
    /// `downloaded` (empty setting, or the saved model was deleted): the first
    /// downloaded id, or nil when `current` is already valid or nothing is downloaded.
    public static func defaultedSelection(current: String, downloaded: [String]) -> String? {
        guard !downloaded.contains(current), let first = downloaded.first else { return nil }
        return first
    }

    /// The language a local-model selection should snap to when `current` isn't one
    /// the model supports: the model's declared `defaultLanguage`, or nil to keep
    /// `current`. Only dedicated-language models declare a default (IndicConformer →
    /// Hindi, the Japanese model → ja, SenseVoice → zh); broad auto-detecting models
    /// and unknown/cloud ids return nil so no language is forced on them.
    public static func defaultLanguage(forModel modelID: String, current: String) -> String? {
        guard let m = model(id: modelID),
              let preferred = m.defaultLanguage,
              !m.supportedLanguages.contains(current) else { return nil }
        return preferred
    }
}
