import Foundation

/// Query configuration for the Deepgram Realtime `listen` WebSocket. Defaults are
/// tuned for dictation: nova-3, raw 16 kHz mono `linear16` PCM, interim results on,
/// smart formatting on, a 300 ms endpoint (commit cadence), English pinned.
public struct DeepgramRealtimeOptions: Sendable, Equatable {
    public var model: String
    public var encoding: String
    public var sampleRate: Int
    public var channels: Int
    public var interimResults: Bool
    public var smartFormat: Bool
    public var endpointingMs: Int
    public var language: String

    public init(model: String = "nova-3",
                encoding: String = "linear16",
                sampleRate: Int = 16_000,
                channels: Int = 1,
                interimResults: Bool = true,
                smartFormat: Bool = true,
                endpointingMs: Int = 300,
                language: String = "en") {
        self.model = model
        self.encoding = encoding
        self.sampleRate = sampleRate
        self.channels = channels
        self.interimResults = interimResults
        self.smartFormat = smartFormat
        self.endpointingMs = endpointingMs
        self.language = language
    }
}

/// Builds the Deepgram Realtime `wss://` URL from a provider base URL + options.
public enum DeepgramRealtimeURL {
    public enum BuildError: Error, Equatable { case invalidBaseURL }

    public static let path = "/v1/listen"

    /// Swaps the base URL's scheme to `wss` (or `ws` for loopback `http`),
    /// appends the listen path, and attaches the config as query items in a stable
    /// order. Throws if the base URL has no scheme.
    public static func make(baseURL: String,
                            options: DeepgramRealtimeOptions = .init()) throws -> URL {
        let trimmed = baseURL.hasSuffix("/") ? String(baseURL.dropLast()) : baseURL
        guard var comps = URLComponents(string: trimmed + path),
              let scheme = comps.scheme?.lowercased() else {
            throw BuildError.invalidBaseURL
        }
        comps.scheme = (scheme == "http") ? "ws" : "wss"
        comps.queryItems = [
            URLQueryItem(name: "model", value: options.model),
            URLQueryItem(name: "encoding", value: options.encoding),
            URLQueryItem(name: "sample_rate", value: String(options.sampleRate)),
            URLQueryItem(name: "channels", value: String(options.channels)),
            URLQueryItem(name: "interim_results", value: options.interimResults ? "true" : "false"),
            URLQueryItem(name: "smart_format", value: options.smartFormat ? "true" : "false"),
            URLQueryItem(name: "endpointing", value: String(options.endpointingMs)),
            URLQueryItem(name: "language", value: options.language),
        ]
        guard let url = comps.url else { throw BuildError.invalidBaseURL }
        return url
    }
}
