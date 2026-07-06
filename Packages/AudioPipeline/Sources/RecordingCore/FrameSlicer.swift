/// Buffers a running stream of samples and emits fixed-size frames. The audio
/// tap delivers variable-length buffers; the VAD requires exactly `frameSize`
/// samples per call, so this slices the stream into uniform frames and carries
/// the remainder to the next push. Pure and Sendable for unit testing.
public struct FrameSlicer: Sendable {
    private var buffer: [Float] = []
    private let frameSize: Int

    public init(frameSize: Int) {
        precondition(frameSize > 0, "frameSize must be positive")
        self.frameSize = frameSize
    }

    /// Append `samples` and return every complete frame now available.
    public mutating func push(_ samples: [Float]) -> [[Float]] {
        buffer.append(contentsOf: samples)
        var frames: [[Float]] = []
        while buffer.count >= frameSize {
            frames.append(Array(buffer[0..<frameSize]))
            buffer.removeFirst(frameSize)
        }
        return frames
    }
}
