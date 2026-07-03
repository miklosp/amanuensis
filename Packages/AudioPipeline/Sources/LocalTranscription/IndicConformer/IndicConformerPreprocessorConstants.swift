import Foundation

nonisolated struct IndicConformerPreprocessorConstants: Sendable {
    let preemphasis: Float
    let logZeroGuard: Float
    let normGuard: Float
    let window: [Float]
    let filterBank: [Float]

    static func load(from url: URL) throws -> IndicConformerPreprocessorConstants {
        let data = try Data(contentsOf: url)
        let headerSize = 8 + 4 * MemoryLayout<Int32>.stride + 3 * MemoryLayout<Float>.stride
        guard data.count >= headerSize else {
            throw LocalTranscriptionError.transcriptionFailed("IndicConformer preprocessor constants file is truncated.")
        }
        guard String(data: data[0..<8], encoding: .ascii) == "IASRPC01" else {
            throw LocalTranscriptionError.transcriptionFailed("IndicConformer preprocessor constants file has an unsupported format.")
        }
        func int32(at offset: Int) -> Int {
            Int(data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: Int32.self) }.littleEndian)
        }
        func float32(at offset: Int) -> Float {
            data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: Float.self) }
        }
        let nFFT = int32(at: 8)
        let winLength = int32(at: 12)
        let nBins = int32(at: 16)
        let nMels = int32(at: 20)
        let preemphasis = float32(at: 24)
        let logZeroGuard = float32(at: 28)
        let normGuard = float32(at: 32)
        let expectedFloatCount = winLength + nMels * nBins
        let expectedSize = headerSize + expectedFloatCount * MemoryLayout<Float>.stride
        guard nFFT == IndicConformerConfig.nFFT,
              winLength == IndicConformerConfig.winLength,
              nBins == IndicConformerConfig.nFFT / 2 + 1,
              nMels == IndicConformerConfig.nMels,
              data.count == expectedSize else {
            throw LocalTranscriptionError.transcriptionFailed("IndicConformer preprocessor constants do not match the expected model shape.")
        }
        var values = [Float](repeating: 0, count: expectedFloatCount)
        _ = values.withUnsafeMutableBytes { data.copyBytes(to: $0, from: headerSize..<expectedSize) }
        return IndicConformerPreprocessorConstants(
            preemphasis: preemphasis, logZeroGuard: logZeroGuard, normGuard: normGuard,
            window: Array(values[0..<winLength]),
            filterBank: Array(values[winLength..<values.count])
        )
    }
}
