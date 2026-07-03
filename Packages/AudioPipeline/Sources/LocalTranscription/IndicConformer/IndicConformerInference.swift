import Foundation

nonisolated struct LSTMState { var h: [Float]; var c: [Float] }
nonisolated struct PredictionStep { let projected: [Float]; let nextState: LSTMState }

nonisolated protocol IndicConformerInference {
    /// Computes the mel for one raw 16 kHz mono audio chunk, runs the encoder, stashes
    /// the encoded frames internally, and returns the number of encoded frames to decode.
    func encode(audio: [Float]) async throws -> Int
    /// Prediction LSTM step + jointPred projection for `previousToken`/`state`.
    func predictAndProject(previousToken: Int, state: LSTMState) async throws -> PredictionStep
    /// jointEnc(frame) ⊕ predProjected → jointPreNet → jointPostNet[language] → logits.
    func jointLogits(frameIndex: Int, predProjected: [Float], language: IndicConformerLanguage) async throws -> [Float]
    func zeroState() -> LSTMState
}
