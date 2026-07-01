import Foundation

/// Query configuration for the Reson8 Realtime WebSocket. Defaults are tuned for
/// dictation: raw 16 kHz mono Int16 PCM, interim results on, English pinned.
public struct Reson8RealtimeOptions: Sendable, Equatable {
    public var encoding: String
    public var sampleRate: Int
    public var channels: Int
    public var includeInterim: Bool
    public var language: String

    public init(encoding: String = "pcm_s16le",
                sampleRate: Int = 16_000,
                channels: Int = 1,
                includeInterim: Bool = true,
                language: String = "en") {
        self.encoding = encoding
        self.sampleRate = sampleRate
        self.channels = channels
        self.includeInterim = includeInterim
        self.language = language
    }
}

/// Builds the Reson8 Realtime `wss://` URL from a provider base URL + options.
public enum Reson8RealtimeURL {
    public enum BuildError: Error, Equatable { case invalidBaseURL }

    public static let path = "/v1/speech-to-text/realtime"

    /// Swaps the base URL's scheme to `wss` (or `ws` for loopback `http`),
    /// appends the realtime path, and attaches the config as query items in a
    /// stable order. Throws if the base URL has no scheme.
    public static func make(baseURL: String,
                            options: Reson8RealtimeOptions = .init()) throws -> URL {
        let trimmed = baseURL.hasSuffix("/") ? String(baseURL.dropLast()) : baseURL
        guard var comps = URLComponents(string: trimmed + path),
              let scheme = comps.scheme?.lowercased() else {
            throw BuildError.invalidBaseURL
        }
        comps.scheme = (scheme == "http") ? "ws" : "wss"
        comps.queryItems = [
            URLQueryItem(name: "encoding", value: options.encoding),
            URLQueryItem(name: "sample_rate", value: String(options.sampleRate)),
            URLQueryItem(name: "channels", value: String(options.channels)),
            URLQueryItem(name: "include_interim", value: options.includeInterim ? "true" : "false"),
            URLQueryItem(name: "language", value: options.language),
        ]
        guard let url = comps.url else { throw BuildError.invalidBaseURL }
        return url
    }
}
