import Foundation
import os

/// Drives a Reson8 Realtime WebSocket: streams raw PCM up as binary frames and
/// decodes transcript messages down into `onPartial`/`onFinal`. `@unchecked
/// Sendable` — the audio thread calls `send(_:)` while the receive loop runs on
/// URLSession's delegate queue; both funnel through the thread-safe task.
public final class Reson8RealtimeClient: @unchecked Sendable {
    private let task: URLSessionWebSocketTask
    private let onPartial: @Sendable (String) -> Void
    private let onFinal: @Sendable (String) -> Void
    private let onError: @Sendable (Error) -> Void
    private let log = Logger(subsystem: "work.miklos.amanuensis", category: "reson8-rt")

    public init(url: URL,
                apiKey: String,
                session: URLSession = .shared,
                onPartial: @escaping @Sendable (String) -> Void,
                onFinal: @escaping @Sendable (String) -> Void,
                onError: @escaping @Sendable (Error) -> Void = { _ in }) {
        var request = URLRequest(url: url)
        request.setValue("ApiKey \(apiKey)", forHTTPHeaderField: "Authorization")
        self.task = session.webSocketTask(with: request)
        self.onPartial = onPartial
        self.onFinal = onFinal
        self.onError = onError
    }

    /// Opens the socket and arms the receive loop.
    public func start() {
        task.resume()
        receive()
    }

    /// Sends one raw-PCM chunk as a binary frame. Non-blocking; safe to call from
    /// the audio thread. Send failures are logged, not thrown.
    public func send(_ pcm: Data) {
        task.send(.data(pcm)) { [log] error in
            if let error {
                log.error("send failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Flushes buffered audio, gives trailing finals ~1 s to arrive, then closes.
    public func finish() async {
        let flush = #"{"type":"flush_request","id":"stop"}"#
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            task.send(.string(flush)) { _ in cont.resume() }
        }
        try? await Task.sleep(for: .seconds(1))
        task.cancel(with: .normalClosure, reason: nil)
    }

    private func receive() {
        task.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let error):
                // Socket closed or errored — stop re-arming. On our own `finish()`
                // this fires with a benign normal-closure error.
                self.onError(error)
            case .success(let message):
                if case .string(let text) = message {
                    switch Reson8StreamDecoder.decode(text) {
                    case .partial(let t): self.onPartial(t)
                    case .final(let t): self.onFinal(t)
                    case .flushConfirmed(let id):
                        self.log.debug("flush confirmed id=\(id ?? "nil", privacy: .public)")
                    case .ignored:
                        break
                    }
                }
                self.receive()   // re-arm for the next frame
            }
        }
    }
}
