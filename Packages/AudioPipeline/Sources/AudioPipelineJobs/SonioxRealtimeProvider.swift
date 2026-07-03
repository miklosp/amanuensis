import Foundation

/// Adapts `SonioxRealtimeClient` to the `RealtimeSTTProvider` seam. `baseURL` is
/// unused — Soniox realtime uses its own fixed endpoint (`SonioxRealtimeURL`).
public struct SonioxRealtimeProvider: RealtimeSTTProvider {
    public init() {}
    public func makeSession(
        baseURL: String, apiKey: String, language: String,
        onEvent: @escaping @Sendable (TranscriptEvent) -> Void,
        onError: @escaping @Sendable (Error) -> Void
    ) throws -> RealtimeSTTSession {
        SonioxRealtimeClient(
            apiKey: apiKey, language: language,
            onEvent: onEvent, onError: onError)
    }
}
