import Testing
@testable import LocalTranscription

/// Scripted inference: `plan[frame]` is the list of tokens to emit on that frame
/// (a blank ends each frame). `predictAndProject` runs once initially and once after
/// each emit (cache is reused across blank frames), so `predictCalls - 1` == the number
/// of tokens emitted so far — which `jointLogits` uses to index the plan.
private final class ScriptedInference: IndicConformerInference {
    let plan: [[Int]]
    var predictCalls = 0
    init(plan: [[Int]]) { self.plan = plan }

    func encode(audio: [Float]) async throws -> Int { plan.count }
    func zeroState() -> LSTMState { LSTMState(h: [0], c: [0]) }
    func predictAndProject(previousToken: Int, state: LSTMState) async throws -> PredictionStep {
        predictCalls += 1
        return PredictionStep(projected: [Float(predictCalls - 1)], nextState: LSTMState(h: [0], c: [0]))
    }
    func jointLogits(frameIndex: Int, predProjected: [Float], language: IndicConformerLanguage) async throws -> [Float] {
        let emitsSoFar = Int(predProjected[0])
        let emittedBeforeFrame = plan[0..<frameIndex].reduce(0) { $0 + $1.count }
        let pos = emitsSoFar - emittedBeforeFrame
        let frameTokens = plan[frameIndex]
        var logits = [Float](repeating: 0, count: IndicConformerConfig.blankId + 1)
        if pos >= 0 && pos < frameTokens.count {
            logits[frameTokens[pos]] = 10   // emit next token
        } else {
            logits[IndicConformerConfig.blankId] = 10   // blank ⇒ advance frame
        }
        return logits
    }
}

@Test func decodesScriptedTokensAcrossFrames() async throws {
    let fake = ScriptedInference(plan: [[5, 6], [], [7]])
    let decoder = IndicConformerGreedyDecoder(inference: fake)
    let ids = try await decoder.decodeChunk(audio: [], language: .hi)
    #expect(ids == [5, 6, 7])
}

@Test func predictionCachedAcrossBlankFrames() async throws {
    // Two empty (blank-only) frames then one emit: predict runs once for the initial
    // state, is reused across the blanks, then once more after the emit.
    let fake = ScriptedInference(plan: [[], [], [9]])
    let decoder = IndicConformerGreedyDecoder(inference: fake)
    let ids = try await decoder.decodeChunk(audio: [], language: .hi)
    #expect(ids == [9])
    // 1 initial predict (reused across both blank frames) + 1 after the emit.
    #expect(fake.predictCalls == 2)
}

@Test func capsSymbolsPerFrame() async throws {
    // A frame that would emit forever is capped at rnntMaxSymbols.
    let runaway = Array(repeating: 1, count: 100)
    let fake = ScriptedInference(plan: [runaway])
    let decoder = IndicConformerGreedyDecoder(inference: fake)
    let ids = try await decoder.decodeChunk(audio: [], language: .hi)
    #expect(ids.count == IndicConformerConfig.rnntMaxSymbols)
}
