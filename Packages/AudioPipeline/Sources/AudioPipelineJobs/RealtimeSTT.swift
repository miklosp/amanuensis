import Foundation

/// One transcript update from a realtime STT session. `partial` is a revising
/// interim for the current segment; `final` is a completed segment's text,
/// emitted once (it is appended by `CommitController.finalize`, not cumulative).
public enum TranscriptEvent: Sendable, Equatable {
    case partial(String)
    case final(String)
}

/// A live streaming-transcription session: fed PCM as it is captured, emitting
/// `TranscriptEvent`s off-thread until `finish()`.
public protocol RealtimeSTTSession: Sendable {
    /// Opens the transport and sends any provider handshake/config.
    func start()
    /// Sends one raw-PCM chunk (16 kHz mono Int16). Called on the audio queue;
    /// conformers MUST keep this non-blocking.
    func send(_ pcm: Data)
    /// Flushes buffered audio, lets trailing finals arrive, then closes.
    func finish() async
}

/// Builds a `RealtimeSTTSession` for one capture. Conformers own their own URL,
/// auth, and wire format.
public protocol RealtimeSTTProvider: Sendable {
    func makeSession(
        baseURL: String,
        apiKey: String,
        language: String,
        onEvent: @escaping @Sendable (TranscriptEvent) -> Void,
        onError: @escaping @Sendable (Error) -> Void
    ) throws -> RealtimeSTTSession
}
