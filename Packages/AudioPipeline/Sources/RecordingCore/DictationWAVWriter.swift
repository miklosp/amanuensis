import AVFoundation

/// Converts incoming hardware-format buffers to 16 kHz mono Int16 and writes
/// them to a WAV file, on a private serial queue. `@unchecked Sendable` so the
/// audio-thread tap can capture it (mirrors `AudioFileWriter`).
final class DictationWAVWriter: @unchecked Sendable {
    private let queue = DispatchQueue(
        label: "work.miklos.amanuensis.dictation.writer", qos: .userInitiated)
    // Optional so `close()` can release it: AVAudioFile finalizes the WAV
    // container (writes the header's data-chunk size) on dealloc, so the file
    // isn't guaranteed complete/readable until it's released — the transcriber
    // reads it immediately after close().
    private var file: AVAudioFile?
    private let converter: AVAudioConverter
    private let outputFormat: AVAudioFormat
    private let onLevel: (@Sendable (Float) -> Void)?
    private var frames: Int64 = 0

    init(url: URL, inputFormat: AVAudioFormat,
         onLevel: (@Sendable (Float) -> Void)?) throws {
        self.onLevel = onLevel
        guard let out = AVAudioFormat(
            commonFormat: .pcmFormatInt16, sampleRate: 16_000,
            channels: 1, interleaved: true) else {
            throw DictationRecorderError.formatUnavailable
        }
        self.outputFormat = out
        guard let conv = AVAudioConverter(from: inputFormat, to: out) else {
            throw DictationRecorderError.formatUnavailable
        }
        self.converter = conv
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 16_000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
        // Open with the 4-arg initializer so the file's processingFormat matches
        // the Int16/interleaved buffers we write below. The 2-arg
        // AVAudioFile(forWriting:settings:) leaves processingFormat at the
        // standard float32/deinterleaved default, and writing an Int16 buffer to
        // it makes ExtAudioFile assert-and-abort the process. Mirrors
        // AudioFileWriter, which uses the same 4-arg form for the same reason.
        self.file = try AVAudioFile(
            forWriting: url, settings: settings,
            commonFormat: out.commonFormat, interleaved: out.isInterleaved)
    }

    func enqueue(_ buffer: AVAudioPCMBuffer) {
        // The buffer is a deep-copy from the tap; ownership hops to the writer
        // queue via this `@unchecked Sendable` wrapper (mirrors AudioFileWriter).
        let handoff = BufferHandoff(buffer: buffer)
        queue.async { [self] in
            guard let file = self.file else { return }  // closed: drop the buffer
            self.onLevel?(Self.rms(handoff.buffer))
            let ratio = self.outputFormat.sampleRate / handoff.buffer.format.sampleRate
            let capacity = AVAudioFrameCount(Double(handoff.buffer.frameLength) * ratio) + 1_024
            guard let out = AVAudioPCMBuffer(
                pcmFormat: self.outputFormat, frameCapacity: capacity) else { return }
            // `remaining` starts with the buffer and is cleared after the first
            // call; the converter input block is called synchronously, so this
            // is safe — wrapping in a class lets us mutate across the @Sendable
            // boundary without introducing real concurrency.
            final class Once: @unchecked Sendable { var buf: AVAudioPCMBuffer? }
            let once = Once(); once.buf = handoff.buffer
            var err: NSError?
            let status = self.converter.convert(to: out, error: &err) { _, inStatus in
                guard let b = once.buf else { inStatus.pointee = .noDataNow; return nil }
                once.buf = nil
                inStatus.pointee = .haveData
                return b
            }
            // A sample-rate-converting AVAudioConverter fed one buffer per call
            // normally returns `.inputRanDry` — it consumed the buffer, then the
            // input block reported no more data — WITH valid output frames in
            // `out`. Treat that exactly like `.haveData`; only `.error` (or a
            // non-nil error) is a real failure. Writing solely on `.haveData`
            // silently dropped almost all converted audio.
            guard status != .error, err == nil, out.frameLength > 0 else { return }
            if (try? file.write(from: out)) != nil {
                self.frames += Int64(out.frameLength)
            }
        }
    }

    private struct BufferHandoff: @unchecked Sendable {
        let buffer: AVAudioPCMBuffer
    }

    func close() async -> Int64 {
        await withCheckedContinuation { cont in
            queue.async { [self] in
                self.file = nil  // release → finalizes the WAV container on disk
                cont.resume(returning: self.frames)
            }
        }
    }

    private static func rms(_ buffer: AVAudioPCMBuffer) -> Float {
        guard let ch = buffer.floatChannelData else { return 0 }
        let n = Int(buffer.frameLength)
        guard n > 0 else { return 0 }
        var sum: Float = 0
        for i in 0..<n { let s = ch[0][i]; sum += s * s }
        return (sum / Float(n)).squareRoot()
    }
}
