// OpenAIRealtimeClient.swift
import Foundation
import os

/// Drives an OpenAI Realtime transcription WebSocket. The protocol outlier of the
/// bunch: header auth (`Authorization: Bearer …`), a `session.update` JSON config
/// first message, and audio sent as **base64 PCM inside a JSON event**
/// (`input_audio_buffer.append`) rather than raw binary frames. Results stream as
/// `delta`/`completed` events, folded into `TranscriptEvent`s by
/// `OpenAITranscriptFolder`. `@unchecked Sendable`: `send(_:)` (audio queue) and the
/// receive loop (URLSession delegate queue) both funnel through the thread-safe task;
/// `folder` is only ever touched inside the receive loop.
public final class OpenAIRealtimeClient: RealtimeSTTSession, @unchecked Sendable {
    private let task: URLSessionWebSocketTask
    private let configMessage: String
    private let onEvent: @Sendable (TranscriptEvent) -> Void
    private let onError: @Sendable (Error) -> Void
    private var folder = OpenAITranscriptFolder()
    private let log = Logger(subsystem: "work.miklos.amanuensis", category: "openai-rt")

    public init(url: URL,
                apiKey: String,
                options: OpenAIRealtimeOptions,
                session: URLSession = .shared,
                onEvent: @escaping @Sendable (TranscriptEvent) -> Void,
                onError: @escaping @Sendable (Error) -> Void = { _ in }) {
        var request = URLRequest(url: url)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        self.task = session.webSocketTask(with: request)
        self.configMessage = OpenAIRealtimeConfig.sessionUpdate(options)
        self.onEvent = onEvent
        self.onError = onError
    }

    public func start() {
        task.resume()
        task.send(.string(configMessage)) { [log] error in
            if let error { log.error("config send failed: \(error.localizedDescription, privacy: .public)") }
        }
        receive()
    }

    public func send(_ pcm: Data) {
        // OpenAI takes base64 PCM inside a JSON event, not a raw binary frame. The
        // base64 alphabet is JSON-safe, so string interpolation needs no escaping.
        let message = #"{"type":"input_audio_buffer.append","audio":""# + pcm.base64EncodedString() + #""}"#
        task.send(.string(message)) { [log] error in
            if let error { log.error("send failed: \(error.localizedDescription, privacy: .public)") }
        }
    }

    public func finish() async {
        // Force-commit any audio the server VAD hasn't yet closed, then give the
        // trailing `.completed` ~1 s to arrive before cancelling.
        let commit = #"{"type":"input_audio_buffer.commit"}"#
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            task.send(.string(commit)) { _ in cont.resume() }
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
                    let event = OpenAIRealtimeDecoder.decode(text)
                    for transcript in self.folder.fold(event) { self.onEvent(transcript) }
                }
                self.receive()
            }
        }
    }
}
