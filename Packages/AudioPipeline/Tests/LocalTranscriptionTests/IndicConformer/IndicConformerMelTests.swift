import Foundation
import Testing
@testable import LocalTranscription

private func makeConstants() -> IndicConformerPreprocessorConstants {
    // Hann-ish window + a trivial filterbank (each mel bin = sum of a contiguous FFT-bin span)
    let nBins = IndicConformerConfig.nFFT / 2 + 1
    var window = [Float](repeating: 0, count: IndicConformerConfig.winLength)
    for i in 0..<window.count { window[i] = 0.5 - 0.5 * cos(2 * .pi * Float(i) / Float(window.count - 1)) }
    var fb = [Float](repeating: 0, count: IndicConformerConfig.nMels * nBins)
    let span = nBins / IndicConformerConfig.nMels
    for m in 0..<IndicConformerConfig.nMels {
        for b in (m * span)..<min((m + 1) * span, nBins) { fb[m * nBins + b] = 1 }
    }
    return IndicConformerPreprocessorConstants(preemphasis: 0.97, logZeroGuard: 1e-5, normGuard: 1e-5,
                                               window: window, filterBank: fb)
}

@Test func melHasFixedShapeAndSilenceIsZeroFrames() throws {
    let mel = try IndicConformerMel(constants: makeConstants())
    let (silent, frames) = mel.compute(audio: [])
    #expect(silent.count == IndicConformerConfig.nMels * IndicConformerConfig.melFrames)
    #expect(frames == 0)
}

@Test func melProducesNormalizedFramesForTone() throws {
    let mel = try IndicConformerMel(constants: makeConstants())
    // 1 s of 220 Hz tone at 16 kHz
    let n = IndicConformerConfig.sampleRate
    var audio = [Float](repeating: 0, count: n)
    for i in 0..<n { audio[i] = 0.2 * sin(2 * .pi * 220 * Float(i) / Float(n) * Float(n) / Float(IndicConformerConfig.sampleRate)) }
    let (out, frames) = mel.compute(audio: audio)
    #expect(frames > 0 && frames <= IndicConformerConfig.melFrames)
    #expect(out.count == IndicConformerConfig.nMels * IndicConformerConfig.melFrames)
    // Per-bin CMVN ⇒ each mel row over its real frames is ~zero-mean.
    var mean: Float = 0
    for f in 0..<frames { mean += out[0 * IndicConformerConfig.melFrames + f] }
    mean /= Float(frames)
    #expect(abs(mean) < 1e-2)
}

@Test func melRegressionFixture() throws {
    let mel = try IndicConformerMel(constants: makeConstants())
    var audio = [Float](repeating: 0, count: 4000)
    for i in 0..<audio.count { audio[i] = sin(Float(i) * 0.03) * 0.3 + sin(Float(i) * 0.011) * 0.1 }
    let (out, frames) = mel.compute(audio: audio)
    #expect(frames > 0)
    let head = Array(out[0..<8])
    let expected: [Float] = [2.8005564, -1.1229907, 0.94819874, -1.4055233, 1.0891492, -1.562965, 1.1450855, -1.5077235]
    for (a, b) in zip(head, expected) { #expect(abs(a - b) < 1e-4) }
}
