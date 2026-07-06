import Foundation
import FluidAudio

/// Speech-onset / endpoint events for auto-dictation. Engine-agnostic wrapper so
/// the app never imports FluidAudio directly.
public enum VoiceActivityEvent: Sendable, Equatable { case none, speechStart, speechEnd }

/// Wraps FluidAudio's streaming Silero VAD. Feed it fixed 4096-sample (256 ms)
/// 16 kHz mono Float frames; it emits speechStart when speech begins and
/// speechEnd after `endpointSilence` of trailing silence (Silero hysteresis).
public actor StreamingVoiceDetector {
    /// Frames must be exactly this many samples (256 ms @ 16 kHz).
    public static let frameSize = VadManager.chunkSize   // 4096

    private let modelDirectory: URL
    private let segConfig: VadSegmentationConfig
    private let vadConfig: VadConfig

    private var manager: VadManager?
    private var state: VadStreamState = .initial()

    public init(modelDirectory: URL, endpointSilence: TimeInterval = 0.6, threshold: Float = 0.85) {
        self.modelDirectory = modelDirectory
        self.vadConfig = VadConfig(defaultThreshold: threshold)
        // maxSpeechDuration is unused by the streaming path (the segmenter owns
        // max-cut); minSpeechDuration is likewise not enforced streaming, so the
        // controller applies its own min-length discard.
        self.segConfig = VadSegmentationConfig(
            minSilenceDuration: endpointSilence,
            speechPadding: 0.1)
    }

    /// Load (downloading if needed) the Silero VAD model. Idempotent.
    public func prepare() async throws {
        guard manager == nil else { return }
        manager = try await VadManager(config: vadConfig, modelDirectory: modelDirectory)
    }

    /// Start a fresh utterance stream (call on each toggle-on).
    public func reset() { state = .initial() }

    /// Process one 4096-sample frame; returns the boundary event, if any.
    public func detect(_ frame: [Float]) async throws -> VoiceActivityEvent {
        guard let manager else { throw VadError.notInitialized }
        let result = try await manager.processStreamingChunk(
            frame, state: state, config: segConfig)
        state = result.state
        switch result.event?.kind {
        case .some(.speechStart): return .speechStart
        case .some(.speechEnd):   return .speechEnd
        case .none:               return .none
        }
    }
}
