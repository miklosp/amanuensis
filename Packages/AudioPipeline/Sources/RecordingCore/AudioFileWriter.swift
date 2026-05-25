import AVFoundation
import Foundation
import os

// Wraps an AVAudioFile with a private serial queue so the real-time audio
// callback can hand off PCM buffers without blocking on disk I/O.
//
// Concurrency contract:
// - `enqueue` is callable from any thread, including the audio render thread.
//   It must not allocate beyond what `DispatchQueue.async` already requires.
// - All AVAudioFile mutation happens on `queue`. The class is `@unchecked
//   Sendable` because we serialize writes ourselves.
// - `close()` blocks the caller until pending writes drain.
final class AudioFileWriter: @unchecked Sendable {
    let url: URL
    let processingFormat: AVAudioFormat

    private let queue: DispatchQueue
    private var file: AVAudioFile?
    private var framesWritten: Int64 = 0
    private var didFail: Bool = false
    private var closed: Bool = false

    init(url: URL, format: AVAudioFormat, label: String) throws {
        self.url = url
        self.processingFormat = format
        self.queue = DispatchQueue(
            label: "work.miklos.audio-pipeline.writer.\(label)",
            qos: .userInitiated
        )
        self.file = try AVAudioFile(
            forWriting: url,
            settings: Self.alacSettings(from: format),
            commonFormat: format.commonFormat,
            interleaved: format.isInterleaved
        )
        Self.log.info("opened writer \(label, privacy: .public) at \(url.path, privacy: .public) — \(format.sampleRate, privacy: .public)Hz \(format.channelCount, privacy: .public)ch")
    }

    nonisolated func enqueue(_ buffer: AVAudioPCMBuffer) {
        // The buffer is freshly constructed on the audio thread; ownership
        // hops to the writer queue via this `@unchecked Sendable` wrapper.
        let handoff = BufferHandoff(buffer: buffer)
        queue.async { [self] in
            guard !closed, !didFail, let file else { return }
            do {
                try file.write(from: handoff.buffer)
                framesWritten &+= Int64(handoff.buffer.frameLength)
            } catch {
                didFail = true
                Self.log.error("write failed: \(String(describing: error), privacy: .public)")
            }
        }
    }

    // Drains pending writes and releases the file handle. Returns the total
    // frames written. Safe to call only once; subsequent calls are no-ops.
    @discardableResult
    nonisolated func close() -> Int64 {
        queue.sync {
            closed = true
            file = nil   // AVAudioFile finalizes the container on dealloc.
        }
        return framesWritten
    }

    private struct BufferHandoff: @unchecked Sendable {
        let buffer: AVAudioPCMBuffer
    }

    private static func alacSettings(from format: AVAudioFormat) -> [String: Any] {
        [
            AVFormatIDKey: kAudioFormatAppleLossless,
            AVSampleRateKey: format.sampleRate,
            AVNumberOfChannelsKey: Int(format.channelCount),
        ]
    }

    private static let log = Logger(subsystem: "work.miklos.audio-pipeline", category: "writer")
}
