import AVFoundation
import Foundation
import os

// Captures the system default audio input device via AVAudioEngine, writing
// to a dedicated AudioFileWriter. The engine is created and torn down once
// per recording — no state lingers between runs.
@MainActor
public final class MicRecorder {
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
        engine.inputNode.installTap(
            onBus: 0,
            bufferSize: 4096,
            format: format
        ) { buffer, _ in
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

    static func currentPermissionStatus() -> AVAuthorizationStatus {
        AVCaptureDevice.authorizationStatus(for: .audio)
    }

    public static func requestPermissionIfNeeded() async -> Bool {
        switch currentPermissionStatus() {
        case .authorized:
            return true
        case .notDetermined:
            return await AVCaptureDevice.requestAccess(for: .audio)
        case .denied, .restricted:
            return false
        @unknown default:
            return false
        }
    }

    private static let log = Logger(subsystem: "work.miklos.audio-pipeline", category: "mic")
}

enum MicRecorderError: Error {
    case invalidInputFormat
    case permissionDenied
}

public struct RecordingTrackResult: Sendable {
    public let url: URL
    public let format: AVAudioFormat
    public let framesWritten: Int64
}
