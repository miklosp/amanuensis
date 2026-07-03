import Foundation

/// The Soniox Realtime WebSocket endpoint. Unlike Reson8, Soniox realtime uses a
/// dedicated host and carries auth + audio config in the first message, so there
/// is no per-provider base URL or query string to build.
public enum SonioxRealtimeURL {
    // Verified against Soniox realtime docs (Task 8, Step 1).
    public static func make() -> URL {
        URL(string: "wss://stt-rt.soniox.com/transcribe-websocket")!
    }
}
