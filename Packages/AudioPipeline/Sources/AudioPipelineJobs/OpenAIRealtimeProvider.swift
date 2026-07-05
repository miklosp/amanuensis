import Foundation

/// Adapts `OpenAIRealtimeClient` to the `RealtimeSTTProvider` seam: derives the wss
/// URL from the provider base URL and threads the dictation language into the
/// `session.update` config. The client folds `delta`/`completed` events onto
/// `onEvent` itself.
public struct OpenAIRealtimeProvider: RealtimeSTTProvider {
    public init() {}
    public func makeSession(
        baseURL: String, apiKey: String, language: String,
        onEvent: @escaping @Sendable (TranscriptEvent) -> Void,
        onError: @escaping @Sendable (Error) -> Void
    ) throws -> RealtimeSTTSession {
        let url = try OpenAIRealtimeURL.make(baseURL: baseURL)
        return OpenAIRealtimeClient(
            url: url, apiKey: apiKey,
            options: OpenAIRealtimeOptions(language: language),
            onEvent: onEvent, onError: onError)
    }
}
