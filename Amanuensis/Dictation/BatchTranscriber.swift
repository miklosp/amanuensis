import Foundation
import DictationCore
import AudioPipelineJobs

/// Batch `DictationTranscriber` over an existing `AudioJobSending` handler.
/// Built per-capture with an already-resolved provider/shape/model.
struct BatchTranscriber: DictationTranscriber {
    let job: Job
    let provider: Provider
    let shape: JobShape
    let keychain: any KeychainProviding
    var handlers: [JobShape: any AudioJobSending] = JobRunner.defaultHandlers

    /// Invariant relied on by callers: `onFinal` is invoked exactly once,
    /// synchronously, before this method returns — the `await` is the
    /// happens-before barrier. Callers (`DictationCoordinator.ResultRef`,
    /// `AutoDictationController.TranscriptBox`) use unsynchronized boxes on that
    /// basis; a future streaming transcriber that calls `onFinal` off-thread must
    /// update those call sites.
    func transcribe(
        audioFile: URL,
        onPartial: @Sendable (String) -> Void,
        onFinal: @Sendable (String) -> Void
    ) async throws {
        guard let handler = handlers[shape] else {
            throw DictationError.unsupportedShape
        }
        let key = shape.requiresAPIKey
            ? try await keychain.get(account: provider.apiKeyRef.account)
            : ""
        let text = try await handler.send(
            job: job, provider: provider, audioURL: audioFile, apiKey: key)
        onFinal(text)
    }
}
