import Foundation
import FluidAudio

public protocol SpeakerDiarizing: Sendable {
    /// Diarize 16 kHz mono PCM samples into time-stamped anonymous speaker segments.
    func diarize(samples: [Float]) async throws -> [DiarizedSegment]
}

/// Caches the loaded Core ML models (pyannote segmentation + wespeaker) and runs
/// diarization off the actor. `DiarizerManager` is non-Sendable, so it can't be
/// held on the actor and handed to a detached task; instead we cache the Sendable
/// `DiarizerModels` and build + run + consume a fresh manager entirely inside a
/// `Task.detached`. `performCompleteDiarization` is synchronous and CPU-bound
/// (10–30 s on a long recording), so running it on a detached utility task keeps
/// it off both the main actor and this actor's executor, freeing the cooperative
/// pool thread for other work. Per-call manager construction is cheap — the
/// expensive Core ML compile is one-time inside `downloadIfNeeded`; `initialize`
/// only wires the already-loaded `MLModel`s into an `EmbeddingExtractor`.
public actor FluidAudioDiarizer: SpeakerDiarizing {
    private var models: DiarizerModels?

    public init() {}

    private func ensureModels() async throws -> DiarizerModels {
        if let models { return models }
        let loaded = try await DiarizerModels.downloadIfNeeded()
        models = loaded
        return loaded
    }

    public func diarize(samples: [Float]) async throws -> [DiarizedSegment] {
        let models = try await ensureModels()
        // The detached task below is unstructured and never `.cancel()`'d, so a check
        // inside it would always read not-cancelled. Check on this (cancellable) task
        // instead: a caller that already cancelled — e.g. during the resample step —
        // never starts the 10–30 s CPU-bound diarization or pins the samples buffer.
        // Mid-flight cancellation isn't possible; `performCompleteDiarization` has no
        // cooperative checkpoints.
        try Task.checkCancellation()
        return try await Task.detached(priority: .utility) {
            let manager = DiarizerManager(config: .default)   // numClusters: -1 → automatic speaker count
            manager.initialize(models: models)
            let result = try manager.performCompleteDiarization(samples, sampleRate: 16_000)
            return result.segments
                .filter { !$0.speakerId.isEmpty }
                .map { DiarizedSegment(speakerId: $0.speakerId, start: Double($0.startTimeSeconds), end: Double($0.endTimeSeconds)) }
        }.value
    }
}
