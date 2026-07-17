import Foundation

public enum LocalRunner: String, Codable, Sendable, Hashable {
    case fluidAudioParakeet      // AsrManager, version selector
    case fluidAudioSenseVoice    // SenseVoiceManager
    case fluidAudioCohere        // CoherePipeline
    case whisperKit              // WhisperKit
    case indicConformer          // IndicConformer (catalog row + service wiring: Task 10)
    case appleSpeech             // Apple SpeechAnalyzer (macOS 26+); engine is optional on the service
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
    public let defaultLanguage: String?

    public init(id: String, displayName: String, summary: String, languages: String,
                supportedLanguages: [String], approxBytes: Int64, runner: LocalRunner,
                selector: String, recommended: Bool, defaultLanguage: String? = nil) {
        self.id = id
        self.displayName = displayName
        self.summary = summary
        self.languages = languages
        self.supportedLanguages = supportedLanguages
        self.approxBytes = approxBytes
        self.runner = runner
        self.selector = selector
        self.recommended = recommended
        self.defaultLanguage = defaultLanguage
    }
}

public extension LocalModel {
    /// False for a model whose engine needs a newer OS than the running system,
    /// so UI lists can hide it. Non-OS-gated models are always available.
    var isAvailableOnThisOS: Bool {
        switch runner {
        case .appleSpeech:
            if #available(macOS 26, *) { return true } else { return false }
        default:
            return true
        }
    }
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
        LocalModel(id: "apple-speech", displayName: "Apple Speech (System)",
                   summary: "Built into macOS 26. No download; Apple-managed languages. Fast, private, on-device.",
                   languages: "~30 languages (system-managed)",
                   supportedLanguages: [
                       "en", "es", "fr", "de", "it", "pt", "zh", "yue", "ja", "ko",
                       "ar", "hi", "ru", "nl", "sv", "da", "nb", "fi", "pl", "tr",
                       "uk", "id", "th", "vi",
                   ],
                   approxBytes: 0,
                   runner: .appleSpeech, selector: "", recommended: false,
                   defaultLanguage: nil),
    ]
    public static func model(id: String) -> LocalModel? { all.first { $0.id == id } }

    /// Catalog rows whose engine can actually run on this OS — for UI listing.
    public static var available: [LocalModel] { all.filter(\.isAvailableOnThisOS) }

    /// The id a local-model picker should fall back to when `current` isn't among
    /// `downloaded` (empty setting, or the saved model was deleted): the first
    /// downloaded id, or nil when `current` is already valid or nothing is downloaded.
    public static func defaultedSelection(current: String, downloaded: [String]) -> String? {
        guard !downloaded.contains(current), let first = downloaded.first else { return nil }
        return first
    }

    /// The language to actually pass to an engine for `modelID`, given the persisted
    /// `requested` value (which may be nil, blank, or a stale code left over from a
    /// different model). A supported explicit choice is kept as-is; anything the model
    /// can't handle resolves to the model's declared `defaultLanguage` (Hindi for
    /// IndicConformer, ja for the Japanese model, …), or nil — auto-detect — for broad
    /// models that declare none. Applying this at the dispatch boundary normalizes
    /// persisted app state so a stale code never reaches an engine's language guard.
    public static func resolvedLanguage(forModel modelID: String, requested: String?) -> String? {
        guard let m = model(id: modelID) else { return requested }
        let current = requested?.trimmingCharacters(in: .whitespaces) ?? ""
        if m.supportedLanguages.contains(current) { return current }
        return m.defaultLanguage
    }

    /// The value a language Picker should bind to for `modelID`, given the user's
    /// `current` selection. Same rule as `resolvedLanguage`, but auto-detect is the
    /// empty string "" (a valid Picker tag) rather than nil, so the Picker never holds
    /// an out-of-range selection after switching to a model with a disjoint language set.
    public static func pickerLanguage(forModel modelID: String, current: String) -> String {
        resolvedLanguage(forModel: modelID, requested: current) ?? ""
    }
}
