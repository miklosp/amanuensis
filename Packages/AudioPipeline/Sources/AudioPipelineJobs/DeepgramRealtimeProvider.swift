import Foundation

/// Adapts `DeepgramRealtimeClient` to the `RealtimeSTTProvider` seam: derives the
/// wss URL from the provider base URL and threads the dictation language into the
/// query config. The client folds results onto `onEvent` itself.
public struct DeepgramRealtimeProvider: RealtimeSTTProvider {
    public init() {}
    public func makeSession(
        baseURL: String, apiKey: String, language: String,
        onEvent: @escaping @Sendable (TranscriptEvent) -> Void,
        onError: @escaping @Sendable (Error) -> Void
    ) throws -> RealtimeSTTSession {
        let url = try DeepgramRealtimeURL.make(
            baseURL: baseURL,
            options: DeepgramRealtimeOptions(language: language))
        return DeepgramRealtimeClient(
            url: url, apiKey: apiKey,
            onEvent: onEvent, onError: onError)
    }
}
