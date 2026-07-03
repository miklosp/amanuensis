// SonioxRealtimeClient.swift
import Foundation
import os

/// Drives a Soniox Realtime WebSocket. Unlike Reson8 (header auth, whole-string
/// transcripts), Soniox authenticates in a JSON config *first message* and streams
/// tokens, folded into `TranscriptEvent`s by `SonioxTranscriptFolder`.
/// `@unchecked Sendable`: `send(_:)` (audio queue) and the receive loop
/// (URLSession delegate queue) both funnel through the thread-safe task; `folder`
/// is only ever touched inside the receive loop.
public final class SonioxRealtimeClient: RealtimeSTTSession, @unchecked Sendable {
    private let task: URLSessionWebSocketTask
    private let configMessage: String
    private let onEvent: @Sendable (TranscriptEvent) -> Void
    private let onError: @Sendable (Error) -> Void
    private var folder = SonioxTranscriptFolder()
    private let log = Logger(subsystem: "work.miklos.amanuensis", category: "soniox-rt")

    public init(url: URL = SonioxRealtimeURL.make(),
                apiKey: String,
                model: String = "stt-rt-v5",
                language: String,
                session: URLSession = .shared,
                onEvent: @escaping @Sendable (TranscriptEvent) -> Void,
                onError: @escaping @Sendable (Error) -> Void = { _ in }) {
        self.task = session.webSocketTask(with: url)
        self.onEvent = onEvent
        self.onError = onError
        // Verified field names (Task 10, Step 1).
        let config: [String: Any] = [
            "api_key": apiKey,
            "model": model,
            "audio_format": "pcm_s16le",
            "sample_rate": 16_000,
            "num_channels": 1,
            "language_hints": [language],
        ]
        let data = (try? JSONSerialization.data(withJSONObject: config)) ?? Data()
        self.configMessage = String(decoding: data, as: UTF8.self)
    }

    public func start() {
        task.resume()
        task.send(.string(configMessage)) { [log] error in
            if let error { log.error("config send failed: \(error.localizedDescription, privacy: .public)") }
        }
        receive()
    }

    public func send(_ pcm: Data) {
        task.send(.data(pcm)) { [log] error in
            if let error { log.error("send failed: \(error.localizedDescription, privacy: .public)") }
        }
    }

    public func finish() async {
        // Soniox ends the stream on an empty audio frame; then wait for trailing
        // finals before closing.
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            task.send(.data(Data())) { _ in cont.resume() }
        }
        try? await Task.sleep(for: .seconds(1))
        task.cancel(with: .normalClosure, reason: nil)
    }

    private func receive() {
        task.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let error):
                self.onError(error)
            case .success(let message):
                if case .string(let text) = message {
                    let frame = SonioxRealtimeDecoder.decode(text)
                    for event in self.folder.fold(frame) { self.onEvent(event) }
                }
                self.receive()
            }
        }
    }
}
