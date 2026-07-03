import Foundation

nonisolated struct IndicConformerGreedyDecoder {
    let inference: any IndicConformerInference

    func decodeChunk(audio: [Float], language: IndicConformerLanguage) async throws -> [Int] {
        let frameCount = try await inference.encode(audio: audio)
        guard frameCount > 0 else { return [] }

        var state = inference.zeroState()
        var previousToken = IndicConformerConfig.sosId
        var cached: PredictionStep?          // carried across blank frames; nil'd only on emit
        var tokenIds: [Int] = []

        for frameIndex in 0..<frameCount {
            for _ in 0..<IndicConformerConfig.rnntMaxSymbols {
                let step: PredictionStep
                if let cached {
                    step = cached
                } else {
                    step = try await inference.predictAndProject(previousToken: previousToken, state: state)
                    cached = step
                }
                let logits = try await inference.jointLogits(frameIndex: frameIndex,
                                                             predProjected: step.projected,
                                                             language: language)
                let token = argmax(logits, count: IndicConformerConfig.blankId + 1)
                if token == IndicConformerConfig.blankId { break }
                tokenIds.append(token)
                previousToken = token
                state = step.nextState
                cached = nil
            }
        }
        return tokenIds
    }

    private func argmax(_ logits: [Float], count: Int) -> Int {
        var best = 0
        var bestValue = -Float.infinity
        for i in 0..<min(count, logits.count) where logits[i] > bestValue { bestValue = logits[i]; best = i }
        return best
    }
}
