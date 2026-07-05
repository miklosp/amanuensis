// DeepgramRealtimeClient.swift
import Foundation
import os

/// Drives a Deepgram Realtime `listen` WebSocket. Like Reson8 it authenticates in a
/// header (`Authorization: Token …`) and streams raw PCM up as binary frames; like
/// Soniox it streams revisable results that are folded into `TranscriptEvent`s by
/// `DeepgramTranscriptFolder`. `@unchecked Sendable`: `send(_:)` (audio queue) and
/// the receive loop (URLSession delegate queue) both funnel through the thread-safe
/// task; `folder` is only ever touched inside the receive loop.
public final class DeepgramRealtimeClient: RealtimeSTTSession, @unchecked Sendable {
    private let task: URLSessionWebSocketTask
    private let onEvent: @Sendable (TranscriptEvent) -> Void
    private let onError: @Sendable (Error) -> Void
    private var folder = DeepgramTranscriptFolder()
    private let log = Logger(subsystem: "work.miklos.amanuensis", category: "deepgram-rt")

    public init(url: URL,
                apiKey: String,
                session: URLSession = .shared,
                onEvent: @escaping @Sendable (TranscriptEvent) -> Void,
                onError: @escaping @Sendable (Error) -> Void = { _ in }) {
        var request = URLRequest(url: url)
        request.setValue("Token \(apiKey)", forHTTPHeaderField: "Authorization")
        self.task = session.webSocketTask(with: request)
        self.onEvent = onEvent
        self.onError = onError
    }

    public func start() {
        task.resume()
        receive()
    }

    public func send(_ pcm: Data) {
        task.send(.data(pcm)) { [log] error in
            if let error { log.error("send failed: \(error.localizedDescription, privacy: .public)") }
        }
    }

    public func finish() async {
        // CloseStream tells Deepgram to flush remaining audio, emit the last final,
        // then close. Give trailing finals ~1 s to arrive before cancelling.
        let close = #"{"type":"CloseStream"}"#
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            task.send(.string(close)) { _ in cont.resume() }
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
                if case .string(let text) = message,
                   let frame = DeepgramRealtimeDecoder.decode(text) {
                    for event in self.folder.fold(frame) { self.onEvent(event) }
                }
                self.receive()
            }
        }
    }
}
