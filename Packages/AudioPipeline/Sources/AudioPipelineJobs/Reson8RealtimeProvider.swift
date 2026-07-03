import Foundation

/// Adapts `Reson8RealtimeClient` to the `RealtimeSTTProvider` seam: derives the
/// wss URL from the provider base URL and maps the client's split callbacks onto
/// a single `onEvent`.
public struct Reson8RealtimeProvider: RealtimeSTTProvider {
    public init() {}
    public func makeSession(
        baseURL: String, apiKey: String, language: String,
        onEvent: @escaping @Sendable (TranscriptEvent) -> Void,
        onError: @escaping @Sendable (Error) -> Void
    ) throws -> RealtimeSTTSession {
        let url = try Reson8RealtimeURL.make(
            baseURL: baseURL,
            options: Reson8RealtimeOptions(language: language))
        return Reson8RealtimeClient(
            url: url, apiKey: apiKey,
            onPartial: { onEvent(.partial($0)) },
            onFinal: { onEvent(.final($0)) },
            onError: onError)
    }
}
