import AVFoundation

extension AVAudioPCMBuffer {
    // Returns an independent copy whose backing storage outlives the source.
    // AVAudioEngine tap buffers are framework-owned and may be reused once the
    // tap callback returns, so any buffer that crosses onto another queue (e.g.
    // AudioFileWriter's serial write queue) must be copied first. Mirrors the
    // copy ProcessTapRecorder already makes for the system-tap path.
    //
    // Returns nil if the buffer carries no frames or allocation fails; callers
    // drop the frame in that case (nothing to write).
    func deepCopy() -> AVAudioPCMBuffer? {
        guard frameLength > 0,
              let copy = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameLength)
        else { return nil }
        copy.frameLength = frameLength

        let source = UnsafeMutableAudioBufferListPointer(
            UnsafeMutablePointer(mutating: audioBufferList)
        )
        let destination = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
        let pairs = min(source.count, destination.count)
        for index in 0..<pairs {
            let src = source[index]
            let dst = destination[index]
            guard let srcPtr = src.mData, let dstPtr = dst.mData else { continue }
            let bytes = min(src.mDataByteSize, dst.mDataByteSize)
            memcpy(dstPtr, srcPtr, Int(bytes))
        }
        return copy
    }
}
