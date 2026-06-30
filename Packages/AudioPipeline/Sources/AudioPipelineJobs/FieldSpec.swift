import Foundation

// UI form metadata. The Job stores values as [String: String]; this drives
// rendering, validation, and per-shape required/optional rules.
public struct FieldSpec: Hashable, Sendable {
    public let key: String
    public let label: String
    public let kind: Kind
    public let required: Bool
    public let help: String?

    public enum Kind: Hashable, Sendable {
        case text
        case longText
        case number
        case language               // ISO-639-1 code
        case picker([String])
        case checkbox
    }

    public init(key: String, label: String, kind: Kind, required: Bool, help: String? = nil) {
        self.key = key
        self.label = label
        self.kind = kind
        self.required = required
        self.help = help
    }
}

extension JobShape {
    public var fields: [FieldSpec] {
        switch self {
        case .chatCompletionsAudio:
            return [
                FieldSpec(key: "prompt", label: "Prompt", kind: .longText, required: true,
                          help: "Instructions for the model (system+user)"),
                FieldSpec(key: "temperature", label: "Temperature", kind: .number, required: false),
                FieldSpec(key: "reasoning_effort", label: "Reasoning effort",
                          kind: .picker(["minimal", "low", "medium", "high"]), required: false,
                          help: "Reasoning models only; lower spends fewer thinking tokens. Leave blank for non-reasoning models (e.g. gpt-4o-audio)."),
                FieldSpec(key: "audio_format", label: "Audio format hint", kind: .picker(["auto", "flac", "wav", "mp3"]),
                          required: false, help: "Sent as input_audio.format. 'auto' derives from file extension."),
            ]
        case .transcriptionMultipart:
            return [
                FieldSpec(key: "prompt", label: "Vocabulary biasing", kind: .text, required: false,
                          help: "~224 tokens, NOT instructions"),
                FieldSpec(key: "language", label: "Language", kind: .language, required: false,
                          help: "ISO-639-1; required for Cohere"),
                FieldSpec(key: "temperature", label: "Temperature", kind: .number, required: false),
                FieldSpec(key: "response_format", label: "Response format",
                          kind: .picker(["json", "text", "verbose_json", "srt", "vtt"]), required: false),
            ]
        case .elevenLabsScribe:
            return [
                FieldSpec(key: "language_code", label: "Language", kind: .language, required: false),
                FieldSpec(key: "diarize", label: "Speaker diarization", kind: .checkbox, required: false),
                FieldSpec(key: "num_speakers", label: "Number of speakers", kind: .number, required: false),
                FieldSpec(key: "timestamps_granularity", label: "Timestamps",
                          kind: .picker(["none", "word", "character"]), required: false),
                FieldSpec(key: "tag_audio_events", label: "Tag non-speech events", kind: .checkbox, required: false),
            ]
        case .geminiGenerateContent:
            return [
                FieldSpec(key: "prompt", label: "Prompt", kind: .longText, required: true),
                FieldSpec(key: "temperature", label: "Temperature", kind: .number, required: false),
                FieldSpec(key: "thinkingBudget", label: "Thinking budget", kind: .number, required: false,
                          help: "Reasoning tokens; 0 disables"),
            ]
        case .sonioxAsync:
            return [
                FieldSpec(key: "enable_speaker_diarization", label: "Speaker diarization",
                          kind: .checkbox, required: false),
                FieldSpec(key: "language_hints", label: "Language hints", kind: .text, required: false,
                          help: "Comma-separated ISO codes, e.g. en,es"),
                FieldSpec(key: "enable_language_identification", label: "Language identification",
                          kind: .checkbox, required: false),
                FieldSpec(key: "context", label: "Context / vocabulary", kind: .longText, required: false,
                          help: "Plain text, or a Soniox context JSON object (general/terms/text)"),
            ]
        case .deepgramListen:
            return [
                FieldSpec(key: "language", label: "Language", kind: .language, required: false,
                          help: "Deepgram code, e.g. en; omit to let Nova-3 auto-detect"),
                FieldSpec(key: "diarize", label: "Speaker diarization", kind: .checkbox, required: false),
                FieldSpec(key: "smart_format", label: "Smart formatting", kind: .checkbox, required: false),
                FieldSpec(key: "keyterm", label: "Keyterm biasing", kind: .text, required: false,
                          help: "Comma-separated terms (Nova-3)"),
            ]
        case .cohereTranscribe:
            return [
                FieldSpec(key: "language", label: "Language", kind: .language, required: true,
                          help: "ISO-639-1; required by Cohere"),
                FieldSpec(key: "temperature", label: "Temperature", kind: .number, required: false),
            ]
        case .reson8Prerecorded:
            return [
                FieldSpec(key: "language", label: "Language", kind: .language, required: false,
                          help: "ISO-639-1; omit to auto-detect"),
                FieldSpec(key: "diarize", label: "Speaker diarization", kind: .checkbox, required: false),
                FieldSpec(key: "max_speakers", label: "Max speakers", kind: .number, required: false,
                          help: "Upper bound for diarization"),
            ]
        case .localTranscription:
            return [
                FieldSpec(key: "language", label: "Language (optional)", kind: .text, required: false,
                          help: "e.g. en, ja, zh. Blank auto-detects on Whisper & Parakeet v3; Cohere defaults to English."),
            ]
        }
    }
}
