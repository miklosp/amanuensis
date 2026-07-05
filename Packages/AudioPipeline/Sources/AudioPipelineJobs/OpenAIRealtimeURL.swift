import Foundation

/// Configuration for an OpenAI Realtime transcription session. Defaults are tuned
/// for dictation: `gpt-4o-transcribe` with server-side VAD (auto-commits at natural
/// pauses, so finals arrive incrementally), raw 16 kHz mono PCM16, English pinned.
/// Set `serverVAD` false for models that require manual commit (e.g.
/// `gpt-realtime-whisper`).
public struct OpenAIRealtimeOptions: Sendable, Equatable {
    public var model: String
    public var language: String
    public var sampleRate: Int
    public var serverVAD: Bool

    public init(model: String = "gpt-4o-transcribe",
                language: String = "en",
                sampleRate: Int = 16_000,
                serverVAD: Bool = true) {
        self.model = model
        self.language = language
        self.sampleRate = sampleRate
        self.serverVAD = serverVAD
    }
}

/// Builds the OpenAI Realtime `wss://` URL from a provider base URL. Transcription
/// mode is selected with `?intent=transcription`; the rest of the config is carried
/// in the `session.update` first message (`OpenAIRealtimeConfig`).
public enum OpenAIRealtimeURL {
    public enum BuildError: Error, Equatable { case invalidBaseURL }

    public static let path = "/v1/realtime"

    public static func make(baseURL: String) throws -> URL {
        let trimmed = baseURL.hasSuffix("/") ? String(baseURL.dropLast()) : baseURL
        guard var comps = URLComponents(string: trimmed + path),
              let scheme = comps.scheme?.lowercased() else {
            throw BuildError.invalidBaseURL
        }
        comps.scheme = (scheme == "http") ? "ws" : "wss"
        comps.queryItems = [URLQueryItem(name: "intent", value: "transcription")]
        guard let url = comps.url else { throw BuildError.invalidBaseURL }
        return url
    }
}

/// Builds the `session.update` first message that configures a transcription-only
/// session (GA nested shape: `session.audio.input.{format,transcription,turn_detection}`).
public enum OpenAIRealtimeConfig {
    public static func sessionUpdate(_ options: OpenAIRealtimeOptions) -> String {
        var input: [String: Any] = [
            "format": ["type": "audio/pcm", "rate": options.sampleRate],
            "transcription": ["model": options.model, "language": options.language],
        ]
        if options.serverVAD {
            input["turn_detection"] = ["type": "server_vad"]
        }
        let message: [String: Any] = [
            "type": "session.update",
            "session": ["type": "transcription", "audio": ["input": input]],
        ]
        let data = (try? JSONSerialization.data(withJSONObject: message)) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }
}
