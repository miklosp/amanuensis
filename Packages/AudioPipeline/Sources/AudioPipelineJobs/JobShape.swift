import Foundation

// The wire-level endpoint shape a Job dispatches to. One per code-level handler.
public enum JobShape: String, Codable, CaseIterable, Hashable, Sendable {
    case chatCompletionsAudio       // POST /v1/chat/completions, input_audio block
    case transcriptionMultipart     // POST /v1|v2/audio/transcriptions, multipart
    case elevenLabsScribe           // ElevenLabs Scribe, own field names
    case geminiGenerateContent      // Gemini File API + generateContent
}
