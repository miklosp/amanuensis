import Foundation

/// Streaming-ready seam. Batch implementations ignore `onPartial` and call
/// `onFinal` exactly once. A future websocket/MLX engine emits interim text
/// via `onPartial`.
public protocol DictationTranscriber: Sendable {
    func transcribe(
        audioFile: URL,
        onPartial: @Sendable (String) -> Void,
        onFinal: @Sendable (String) -> Void
    ) async throws
}
