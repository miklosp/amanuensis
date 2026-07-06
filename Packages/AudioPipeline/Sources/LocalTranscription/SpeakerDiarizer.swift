import Foundation
import FluidAudio

public protocol SpeakerDiarizing: Sendable {
    /// Diarize 16 kHz mono PCM samples into time-stamped anonymous speaker segments.
    func diarize(samples: [Float]) async throws -> [DiarizedSegment]
}

/// Owns the non-Sendable `DiarizerManager` entirely within one actor. Lazily
/// downloads + loads the Core ML models (pyannote segmentation + wespeaker) on
/// first use. `performCompleteDiarization` is synchronous/CPU-blocking; running it
/// inside this dedicated actor keeps it off the main actor.
public actor FluidAudioDiarizer: SpeakerDiarizing {
    private var manager: DiarizerManager?

    public init() {}

    private func ensureLoaded() async throws -> DiarizerManager {
        if let manager { return manager }
        let models = try await DiarizerModels.downloadIfNeeded()
        let m = DiarizerManager(config: .default)   // numClusters: -1 → automatic speaker count
        m.initialize(models: models)
        manager = m
        return m
    }

    public func diarize(samples: [Float]) async throws -> [DiarizedSegment] {
        let m = try await ensureLoaded()
        let result = try m.performCompleteDiarization(samples, sampleRate: 16_000)
        return result.segments
            .filter { !$0.speakerId.isEmpty }
            .map { DiarizedSegment(speakerId: $0.speakerId, start: Double($0.startTimeSeconds), end: Double($0.endTimeSeconds)) }
    }
}
