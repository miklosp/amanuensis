import AVFoundation
import Foundation
import os

// Captures the system default audio input device via AVAudioEngine, writing
// to a dedicated AudioFileWriter. The engine is created and torn down once
// per recording — no state lingers between runs.
@MainActor
final class MicRecorder {
    private let engine: AVAudioEngine
    private let writer: AudioFileWriter

    init(url: URL) throws {
        let engine = AVAudioEngine()
        // The input node's hardware format. We adopt it as-is rather than
        // forcing a sample rate; downstream pipeline nodes can resample.
        let format = engine.inputNode.inputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw MicRecorderError.invalidInputFormat
        }
        self.engine = engine
        self.writer = try AudioFileWriter(url: url, format: format, label: "mic")
    }

    func start() throws {
        let writer = self.writer
        let format = writer.processingFormat
        // The tap fires on AVAudioEngine's render thread. Without the explicit
        // @Sendable marker the closure inherits MainActor isolation (because
        // MicRecorder is @MainActor and the RecordingCore module enables the
        // NonisolatedNonsendingByDefault upcoming feature), which makes the
        // Swift runtime assert "current executor is MainActor" on every fire
        // and SIGTRAP on the audio thread. @Sendable opts out of that
        // inheritance — matches ProcessTapRecorder's IOProc block.
        engine.inputNode.installTap(
            onBus: 0,
            bufferSize: 4096,
            format: format
        ) { @Sendable [writer] buffer, _ in
            writer.enqueue(buffer)
        }
        engine.prepare()
        try engine.start()
        Self.log.info("mic recording started at \(format.sampleRate, privacy: .public)Hz \(format.channelCount, privacy: .public)ch")
    }

    func stop() -> RecordingTrackResult {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        let frames = writer.close()
        Self.log.info("mic recording stopped — \(frames, privacy: .public) frames written")
        return RecordingTrackResult(
            url: writer.url,
            format: writer.processingFormat,
            framesWritten: frames
        )
    }

    private static let log = Logger(subsystem: "work.miklos.audio-pipeline", category: "mic")
}

public enum MicRecorderError: Error, LocalizedError {
    case invalidInputFormat
    case permissionDenied

    public var errorDescription: String? {
        switch self {
        case .invalidInputFormat:
            return "The selected microphone input format isn't usable."
        case .permissionDenied:
            return "Microphone permission was denied."
        }
    }
}

public struct RecordingTrackResult: Sendable {
    public let url: URL
    public let format: AVAudioFormat
    public let framesWritten: Int64
}
