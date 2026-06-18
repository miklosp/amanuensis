@preconcurrency import AVFoundation

public enum DictationRecorderError: Error, Sendable {
    case noInput
    case formatUnavailable
}

/// Mic-only capture straight to a 16 kHz mono WAV. No post-stop transcode.
public final class DictationRecorder {
    private let engine = AVAudioEngine()
    private let writer: DictationWAVWriter

    public init(url: URL, onLevel: (@Sendable (Float) -> Void)? = nil) throws {
        let input = engine.inputNode.inputFormat(forBus: 0)
        guard input.sampleRate > 0, input.channelCount > 0 else {
            throw DictationRecorderError.noInput
        }
        self.writer = try DictationWAVWriter(
            url: url, inputFormat: input, onLevel: onLevel)
    }

    public func start() throws {
        let input = engine.inputNode.inputFormat(forBus: 0)
        engine.inputNode.installTap(
            onBus: 0, bufferSize: 4_096, format: input
        ) { @Sendable [writer] buffer, _ in
            writer.enqueue(buffer)
        }
        engine.prepare()
        try engine.start()
    }

    /// Stops capture, flushes the writer, returns frames written.
    public func stop() async -> Int64 {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        return await writer.close()
    }
}
