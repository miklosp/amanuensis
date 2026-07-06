import AVFoundation

/// Always-on mic capture for auto-dictation. Installs one AVAudioEngine tap,
/// converts hardware-format buffers to 16 kHz mono Float32, and delivers fixed
/// `frameSize`-sample frames via `onFrame` (called on the audio thread). The
/// frame callback is `@Sendable` and hops isolation itself — this type inherits
/// no actor isolation for the tap closure (SWIFT_DEFAULT_ACTOR_ISOLATION is
/// MainActor, so the closure is explicitly @Sendable to stay off-main).
public final class ContinuousMicTap: @unchecked Sendable {
    private let engine = AVAudioEngine()
    private let converter: AVAudioConverter
    private let inputFormat: AVAudioFormat
    private let outputFormat: AVAudioFormat
    private let onFrame: @Sendable ([Float]) -> Void

    // Framing state is only touched inside the serial tap callback.
    private var slicer: FrameSlicer

    public init(frameSize: Int, onFrame: @escaping @Sendable ([Float]) -> Void) throws {
        self.onFrame = onFrame
        self.slicer = FrameSlicer(frameSize: frameSize)
        let input = engine.inputNode.inputFormat(forBus: 0)
        guard input.sampleRate > 0, input.channelCount > 0 else {
            throw DictationRecorderError.noInput
        }
        self.inputFormat = input
        guard let out = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: 16_000,
            channels: 1, interleaved: false),
              let conv = AVAudioConverter(from: input, to: out) else {
            throw DictationRecorderError.formatUnavailable
        }
        self.outputFormat = out
        self.converter = conv
    }

    public func start() throws {
        engine.inputNode.installTap(
            onBus: 0, bufferSize: 4_096, format: inputFormat
        ) { @Sendable [weak self] buffer, _ in
            guard let self, let copy = buffer.deepCopy() else { return }
            self.handle(copy)
        }
        engine.prepare()
        try engine.start()
    }

    public func stop() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
    }

    private func handle(_ buffer: AVAudioPCMBuffer) {
        let ratio = outputFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1_024
        guard let out = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else { return }
        final class Once: @unchecked Sendable { var buf: AVAudioPCMBuffer? }
        let once = Once(); once.buf = buffer
        var err: NSError?
        let status = converter.convert(to: out, error: &err) { _, inStatus in
            guard let b = once.buf else { inStatus.pointee = .noDataNow; return nil }
            once.buf = nil
            inStatus.pointee = .haveData
            return b
        }
        guard status != .error, err == nil, out.frameLength > 0,
              let ch = out.floatChannelData else { return }
        let samples = Array(UnsafeBufferPointer(start: ch[0], count: Int(out.frameLength)))
        for frame in slicer.push(samples) { onFrame(frame) }
    }
}
