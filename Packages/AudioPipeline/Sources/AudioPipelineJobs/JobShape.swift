import Foundation

// The wire-level endpoint shape a Job dispatches to. One per code-level handler.
public enum JobShape: String, Codable, CaseIterable, Hashable, Sendable {
    case chatCompletionsAudio       // POST /v1/chat/completions, input_audio block
    case transcriptionMultipart     // POST /v1|v2/audio/transcriptions, multipart
    case elevenLabsScribe           // ElevenLabs Scribe, own field names
    case geminiGenerateContent      // Gemini File API + generateContent
    case sonioxAsync                // Soniox async: upload → create → poll → fetch transcript

    // The path the handler appends to the provider's Base URL. Shown as a hint
    // in the provider editor so users know not to include it themselves. Must
    // track the suffix each handler actually builds (see ChatCompletionsAudio /
    // ElevenLabsScribe handlers); for the not-yet-implemented shapes it states
    // the intended path.
    public var baseURLPathHint: String {
        switch self {
        case .chatCompletionsAudio:  return "/v1/chat/completions"
        case .transcriptionMultipart: return "/v1/audio/transcriptions"
        case .elevenLabsScribe:      return "/v1/speech-to-text"
        case .geminiGenerateContent: return "/models/{model}:generateContent"
        case .sonioxAsync:           return "/v1/transcriptions"
        }
    }
}
