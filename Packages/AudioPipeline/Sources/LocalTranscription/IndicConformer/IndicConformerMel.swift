import Accelerate
import Foundation

nonisolated final class IndicConformerMel {
    private let filterBank: [Float]
    private let window: [Float]
    private let preemphasis: Float
    private let logZeroGuard: Float
    private let normGuard: Float
    private let fftSetup: FFTSetup
    private let fftLog2n: vDSP_Length
    private let nBins = IndicConformerConfig.nFFT / 2 + 1

    init(constants: IndicConformerPreprocessorConstants) throws {
        self.filterBank = constants.filterBank
        self.window = constants.window
        self.preemphasis = constants.preemphasis
        self.logZeroGuard = constants.logZeroGuard
        self.normGuard = constants.normGuard
        let log2n = vDSP_Length(log2(Double(IndicConformerConfig.nFFT)))
        self.fftLog2n = log2n
        guard let setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else {
            throw LocalTranscriptionError.transcriptionFailed("Failed to create IndicConformer FFT setup.")
        }
        self.fftSetup = setup
    }

    deinit {
        vDSP_destroy_fftsetup(fftSetup)
    }

    func compute(audio: [Float]) -> (mel: [Float], realFrameCount: Int) {
        guard !audio.isEmpty else {
            return ([Float](repeating: 0, count: IndicConformerConfig.nMels * IndicConformerConfig.melFrames), 0)
        }

        let nFFT = IndicConformerConfig.nFFT
        let winLength = IndicConformerConfig.winLength
        let hop = IndicConformerConfig.hopLength
        let nMels = IndicConformerConfig.nMels
        let melFrames = IndicConformerConfig.melFrames
        let halfN = nFFT / 2
        let pad = nFFT / 2
        let windowOffset = (nFFT - winLength) / 2

        let emphasized = Self.preemphasize(audio, coefficient: preemphasis)
        let padded = Self.reflectPad(emphasized, left: pad, right: pad)
        guard padded.count >= nFFT else {
            return ([Float](repeating: 0, count: nMels * melFrames), 0)
        }

        let frameCount = 1 + (padded.count - nFFT) / hop
        let realFrameCount = min(frameCount, melFrames)
        if realFrameCount == 0 {
            return ([Float](repeating: 0, count: nMels * melFrames), 0)
        }

        var frame = [Float](repeating: 0, count: nFFT)
        var realPart = [Float](repeating: 0, count: halfN)
        var imagPart = [Float](repeating: 0, count: halfN)
        var powerSpec = [Float](repeating: 0, count: realFrameCount * nBins)
        var reSq = [Float](repeating: 0, count: halfN - 1)
        var imSq = [Float](repeating: 0, count: halfN - 1)

        padded.withUnsafeBufferPointer { paddedBuffer in
            for frameIndex in 0..<realFrameCount {
                let start = frameIndex * hop
                frame.withUnsafeMutableBufferPointer { frameBuffer in
                    vDSP_vclr(frameBuffer.baseAddress!, 1, vDSP_Length(nFFT))
                    vDSP_vmul(
                        paddedBuffer.baseAddress! + start + windowOffset, 1,
                        window, 1,
                        frameBuffer.baseAddress! + windowOffset, 1,
                        vDSP_Length(winLength)
                    )
                }

                realPart.withUnsafeMutableBufferPointer { realBuffer in
                    imagPart.withUnsafeMutableBufferPointer { imagBuffer in
                        var split = DSPSplitComplex(realp: realBuffer.baseAddress!, imagp: imagBuffer.baseAddress!)
                        frame.withUnsafeBufferPointer { frameBuffer in
                            frameBuffer.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: halfN) { complexPtr in
                                vDSP_ctoz(complexPtr, 2, &split, 1, vDSP_Length(halfN))
                            }
                        }
                        vDSP_fft_zrip(fftSetup, &split, 1, fftLog2n, FFTDirection(kFFTDirection_Forward))
                        powerSpec.withUnsafeMutableBufferPointer { powerBuffer in
                            let destination = powerBuffer.baseAddress! + frameIndex * nBins
                            destination[0] = realBuffer[0] * realBuffer[0]
                            destination[halfN] = imagBuffer[0] * imagBuffer[0]
                            vDSP_vsq(realBuffer.baseAddress! + 1, 1, &reSq, 1, vDSP_Length(halfN - 1))
                            vDSP_vsq(imagBuffer.baseAddress! + 1, 1, &imSq, 1, vDSP_Length(halfN - 1))
                            vDSP_vadd(reSq, 1, imSq, 1, destination + 1, 1, vDSP_Length(halfN - 1))
                        }
                    }
                }
            }
        }

        var powerSpecT = [Float](repeating: 0, count: nBins * realFrameCount)
        // powerSpec is [frames, nBins] row-major; vDSP_mtrans M/N are columns/rows here.
        vDSP_mtrans(powerSpec, 1, &powerSpecT, 1, vDSP_Length(nBins), vDSP_Length(realFrameCount))

        var melRaw = [Float](repeating: 0, count: nMels * realFrameCount)
        vDSP_mmul(filterBank, 1, powerSpecT, 1, &melRaw, 1,
                  vDSP_Length(nMels), vDSP_Length(realFrameCount), vDSP_Length(nBins))

        var guardValue = logZeroGuard
        var logMel = [Float](repeating: 0, count: nMels * realFrameCount)
        vDSP_vsadd(melRaw, 1, &guardValue, &logMel, 1, vDSP_Length(logMel.count))
        var vectorLength = Int32(logMel.count)
        vvlogf(&logMel, logMel, &vectorLength)

        var normalized = [Float](repeating: 0, count: nMels * melFrames)
        let realFrameVLength = vDSP_Length(realFrameCount)
        let invNm1 = 1.0 / Float(max(realFrameCount - 1, 1))
        for melIndex in 0..<nMels {
            let sourceOffset = melIndex * realFrameCount
            let destinationOffset = melIndex * melFrames
            var mean: Float = 0
            logMel.withUnsafeBufferPointer { buffer in
                vDSP_meanv(buffer.baseAddress! + sourceOffset, 1, &mean, realFrameVLength)
            }
            var negMean = -mean
            var centered = [Float](repeating: 0, count: realFrameCount)
            logMel.withUnsafeBufferPointer { buffer in
                vDSP_vsadd(buffer.baseAddress! + sourceOffset, 1, &negMean, &centered, 1, realFrameVLength)
            }
            var sumSq: Float = 0
            vDSP_dotpr(centered, 1, centered, 1, &sumSq, realFrameVLength)
            let std = sqrtf(max(sumSq * invNm1, logZeroGuard)) + normGuard
            var invStd = 1.0 / std
            normalized.withUnsafeMutableBufferPointer { buffer in
                vDSP_vsmul(centered, 1, &invStd, buffer.baseAddress! + destinationOffset, 1, realFrameVLength)
            }
        }

        return (normalized, realFrameCount)
    }

    private static func preemphasize(_ audio: [Float], coefficient: Float) -> [Float] {
        var emphasized = [Float](repeating: 0, count: audio.count)
        guard !audio.isEmpty else { return emphasized }
        emphasized[0] = audio[0]
        if audio.count > 1 {
            for index in 1..<audio.count {
                emphasized[index] = audio[index] - coefficient * audio[index - 1]
            }
        }
        return emphasized
    }

    private static func reflectPad(_ input: [Float], left: Int, right: Int) -> [Float] {
        guard input.count > 1 else {
            let value = input.first ?? 0
            return [Float](repeating: value, count: left + input.count + right)
        }
        var padded = [Float](repeating: 0, count: left + input.count + right)
        for index in 0..<left {
            padded[index] = input[reflectIndex(left - index, count: input.count)]
        }
        for index in 0..<input.count {
            padded[left + index] = input[index]
        }
        for index in 0..<right {
            padded[left + input.count + index] = input[reflectIndex(input.count - 2 - index, count: input.count)]
        }
        return padded
    }

    private static func reflectIndex(_ rawIndex: Int, count: Int) -> Int {
        guard count > 1 else { return 0 }
        let period = 2 * count - 2
        var index = rawIndex % period
        if index < 0 { index += period }
        if index >= count {
            index = period - index
        }
        return index
    }
}
