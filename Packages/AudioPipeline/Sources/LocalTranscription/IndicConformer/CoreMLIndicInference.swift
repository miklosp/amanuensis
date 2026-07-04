import CoreML
import Foundation

/// Core ML conformer of the `IndicConformerInference` seam: runs the encoder, prediction LSTM,
/// and split joint network via `MLModel`. Ported from the MIT reference `IndicASRRNNTGreedyDecoder`
/// (ported from Muesli, github.com/pHequals7/muesli, MIT; see NOTICE.md), restructured into the
/// three seam methods. Per-call decoder caching now lives in `IndicConformerGreedyDecoder`; this class
/// is stateless per call except the stashed `encoderFrames`.
///
/// One Core ML inference session for a single transcription. It holds per-decode
/// mutable state — the reusable `DecodeWorkspace` buffers and the `encoderFrames`
/// stash — so a single instance is safe ONLY for one sequential decode. It must NOT
/// be shared across concurrent or reentrant transcriptions. `IndicConformerModels`
/// (Task 8) vends a fresh instance per transcribe via `makeInference()`; the resident
/// MLModels + mel are read-only and safe to share. The `nonisolated(unsafe)` marks on the
/// stored models/workspace encode exactly this "serial, single-owner" invariant — they are
/// sound only while it holds.
nonisolated final class CoreMLIndicInference: IndicConformerInference {
    // MLModel/MLFeatureProvider aren't Sendable, but Apple documents `MLModel.prediction(from:)`
    // as safe to call repeatedly/concurrently on the same instance; CoreML predates SE-0461, so
    // its async APIs keep `@concurrent` (global-executor) semantics and the compiler can't prove
    // that on its own. `nonisolated(unsafe)` is the sanctioned escape hatch for that known-safe case.
    private nonisolated(unsafe) let encoder: MLModel
    private nonisolated(unsafe) let decoder: MLModel
    private nonisolated(unsafe) let jointEnc: MLModel
    private nonisolated(unsafe) let jointPred: MLModel
    private nonisolated(unsafe) let jointPreNet: MLModel
    private nonisolated(unsafe) let jointPostNets: [IndicConformerLanguage: MLModel]
    private let mel: IndicConformerMel
    private nonisolated(unsafe) let workspace: DecodeWorkspace
    private var encoderFrames: EncoderFrameView?

    init(encoder: MLModel, decoder: MLModel, jointEnc: MLModel, jointPred: MLModel,
         jointPreNet: MLModel, jointPostNets: [IndicConformerLanguage: MLModel],
         mel: IndicConformerMel) throws {
        self.encoder = encoder
        self.decoder = decoder
        self.jointEnc = jointEnc
        self.jointPred = jointPred
        self.jointPreNet = jointPreNet
        self.jointPostNets = jointPostNets
        self.mel = mel
        self.workspace = try DecodeWorkspace()
    }

    func zeroState() -> LSTMState {
        let n = IndicConformerConfig.predLayers * 1 * IndicConformerConfig.predHiddenDim
        return LSTMState(h: [Float](repeating: 0, count: n), c: [Float](repeating: 0, count: n))
    }

    func encode(audio: [Float]) async throws -> Int {
        let (melValues, realFrames) = mel.compute(audio: audio)
        let melArray = try makeFloatArray(shape: [1, IndicConformerConfig.nMels, IndicConformerConfig.melFrames],
                                          values: melValues)
        let lengthArray = try MLMultiArray(shape: [1], dataType: .int32)
        lengthArray[0] = NSNumber(value: Int32(realFrames))
        let input = try MLDictionaryFeatureProvider(dictionary: [
            "audio_signal": MLFeatureValue(multiArray: melArray),
            "length": MLFeatureValue(multiArray: lengthArray),
        ])
        let output = try await encoder.prediction(from: input)
        guard let encoded = output.featureValue(for: "outputs")?.multiArrayValue,
              let lengths = output.featureValue(for: "encoded_lengths")?.multiArrayValue else {
            throw LocalTranscriptionError.transcriptionFailed("IndicConformer encoder did not return outputs.")
        }
        let count = min(max(lengths[0].intValue, 0), IndicConformerConfig.melFrames)
        encoderFrames = count > 0 ? try EncoderFrameView(encoded: encoded, encodedFrameCount: count) : nil
        return count
    }

    func predictAndProject(previousToken: Int, state: LSTMState) async throws -> PredictionStep {
        // Build state MLMultiArrays from the flat vectors.
        let hArr = try makeFloatArray(shape: [IndicConformerConfig.predLayers, 1, IndicConformerConfig.predHiddenDim], values: state.h)
        let cArr = try makeFloatArray(shape: [IndicConformerConfig.predLayers, 1, IndicConformerConfig.predHiddenDim], values: state.c)
        workspace.tokenArray[0] = NSNumber(value: Int32(previousToken))
        let input = try MLDictionaryFeatureProvider(dictionary: [
            "targets": MLFeatureValue(multiArray: workspace.tokenArray),
            "target_length": MLFeatureValue(multiArray: workspace.tokenLength),
            "states_1": MLFeatureValue(multiArray: hArr),
            "cell_state_in": MLFeatureValue(multiArray: cArr),
        ])
        let output = try await decoder.prediction(from: input)
        guard let outputs = output.featureValue(for: "outputs")?.multiArrayValue,
              let nextH = output.featureValue(for: "states")?.multiArrayValue,
              let nextC = output.featureValue(for: "cell_state_out")?.multiArrayValue else {
            throw LocalTranscriptionError.transcriptionFailed("IndicConformer RNN-T decoder did not return state outputs.")
        }
        // jointPred projection (fills workspace.decoderFrameInput from outputs, runs jointPred).
        let projected = try await runJointPred(outputs)
        let projectedVec = flatten(projected, count: IndicConformerConfig.predHiddenDim)
        return PredictionStep(projected: projectedVec,
                              nextState: LSTMState(h: flatten(nextH, count: nextH.count),
                                                   c: flatten(nextC, count: nextC.count)))
    }

    func jointLogits(frameIndex: Int, predProjected: [Float], language: IndicConformerLanguage) async throws -> [Float] {
        guard let encoderFrames else { throw LocalTranscriptionError.transcriptionFailed("IndicConformer encoder frames missing.") }
        guard let postNet = jointPostNets[language] else {
            throw LocalTranscriptionError.transcriptionFailed("Missing IndicConformer joint post-net for \(language.label).")
        }
        // jointEnc(frame)
        try encoderFrames.copyFrame(frameIndex, into: workspace.encoderFrameInput)
        let encFrame = try await predict(model: jointEnc, provider: workspace.jointEncInputProvider, outputName: "output")
        // write predProjected into workspace.decoderFrameInput-shaped jointPred output buffer:
        let predFrame = try makeFloatArray(shape: [1, 1, IndicConformerConfig.predHiddenDim], values: predProjected)
        // add ⇒ jointInput ⇒ preNet ⇒ postNet
        try addArrays(encFrame, predFrame, into: workspace.jointInput)
        let preNetOut = try await predict(model: jointPreNet, provider: workspace.jointPreNetInputProvider, outputName: "output")
        let logits = try await predict(model: postNet, inputName: "input", input: preNetOut, outputName: "output")
        return flatten(logits, count: IndicConformerConfig.blankId + 1)
    }

    private func flatten(_ array: MLMultiArray, count: Int) -> [Float] {
        (0..<min(count, array.count)).map { Self.floatValue(array, linearIndex: $0) }
    }

    // MARK: - Ported from IndicASRRNNTGreedyDecoder (Muesli, github.com/pHequals7/muesli, MIT; see NOTICE.md)

    private final class DecodeWorkspace {
        let encoderFrameInput: MLMultiArray
        let decoderFrameInput: MLMultiArray
        let jointInput: MLMultiArray
        let tokenArray: MLMultiArray
        let tokenLength: MLMultiArray
        let jointEncInputProvider: MLDictionaryFeatureProvider
        let jointPredInputProvider: MLDictionaryFeatureProvider
        let jointPreNetInputProvider: MLDictionaryFeatureProvider

        init() throws {
            encoderFrameInput = try MLMultiArray(
                shape: [1, 1, NSNumber(value: IndicConformerConfig.encoderDim)],
                dataType: .float32
            )
            decoderFrameInput = try MLMultiArray(
                shape: [1, 1, NSNumber(value: IndicConformerConfig.predHiddenDim)],
                dataType: .float32
            )
            jointInput = try MLMultiArray(
                shape: [1, 1, NSNumber(value: IndicConformerConfig.predHiddenDim)],
                dataType: .float32
            )
            tokenArray = try MLMultiArray(shape: [1, 1], dataType: .int32)
            tokenLength = try MLMultiArray(shape: [1], dataType: .int32)
            tokenLength[0] = NSNumber(value: Int32(1))
            jointEncInputProvider = try MLDictionaryFeatureProvider(dictionary: [
                "input": MLFeatureValue(multiArray: encoderFrameInput),
            ])
            jointPredInputProvider = try MLDictionaryFeatureProvider(dictionary: [
                "input": MLFeatureValue(multiArray: decoderFrameInput),
            ])
            jointPreNetInputProvider = try MLDictionaryFeatureProvider(dictionary: [
                "input": MLFeatureValue(multiArray: jointInput),
            ])
        }
    }

    private struct EncoderFrameView {
        let encoded: MLMultiArray
        let frameCount: Int
        let strides: [Int]

        init(encoded: MLMultiArray, encodedFrameCount: Int) throws {
            let shape = encoded.shape.map(\.intValue)
            let strides = encoded.strides.map(\.intValue)
            guard shape.count == 3, strides.count == 3 else {
                throw LocalTranscriptionError.transcriptionFailed(
                    "Unexpected Indic ASR encoder output rank \(shape.count); expected [batch, encoderDim, frames]. Shape: \(encoded.shape).")
            }
            guard shape[1] == IndicConformerConfig.encoderDim else {
                throw LocalTranscriptionError.transcriptionFailed(
                    "Unexpected Indic ASR encoder hidden dimension \(shape[1]); expected \(IndicConformerConfig.encoderDim). Shape: \(encoded.shape).")
            }
            let frameCapacity = shape[2]
            self.frameCount = min(max(encodedFrameCount, 0), frameCapacity)
            self.encoded = encoded
            self.strides = strides
        }

        func copyFrame(_ frameIndex: Int, into destination: MLMultiArray) throws {
            guard frameIndex >= 0, frameIndex < frameCount else {
                throw LocalTranscriptionError.transcriptionFailed(
                    "Indic ASR frame index \(frameIndex) is outside available frame count \(frameCount).")
            }
            let ptr = destination.dataPointer.bindMemory(to: Float.self, capacity: IndicConformerConfig.encoderDim)
            for dim in 0..<IndicConformerConfig.encoderDim {
                let sourceOffset = strides[1] * dim + strides[2] * frameIndex
                ptr[dim] = CoreMLIndicInference.floatValue(encoded, offset: sourceOffset)
            }
        }
    }

    private func runJointPred(_ decoderOutputs: MLMultiArray) async throws -> MLMultiArray {
        let shape = decoderOutputs.shape.map(\.intValue)
        let strides = decoderOutputs.strides.map(\.intValue)
        let hasExpectedRank = shape.count == 2 || (shape.count == 3 && shape[2] == 1)
        guard hasExpectedRank, strides.count == shape.count else {
            throw LocalTranscriptionError.transcriptionFailed(
                "Unexpected Indic ASR decoder output shape; expected [batch, predHiddenDim] or [batch, predHiddenDim, 1]. Shape: \(decoderOutputs.shape).")
        }
        guard shape[1] == IndicConformerConfig.predHiddenDim else {
            throw LocalTranscriptionError.transcriptionFailed(
                "Unexpected Indic ASR decoder hidden dimension \(shape[1]); expected \(IndicConformerConfig.predHiddenDim). Shape: \(decoderOutputs.shape).")
        }
        let ptr = workspace.decoderFrameInput.dataPointer.bindMemory(to: Float.self, capacity: IndicConformerConfig.predHiddenDim)
        for dim in 0..<IndicConformerConfig.predHiddenDim {
            ptr[dim] = Self.floatValue(decoderOutputs, offset: strides[1] * dim)
        }
        return try await predict(model: jointPred, provider: workspace.jointPredInputProvider, outputName: "output")
    }

    private func predict(model: MLModel, inputName: String, input: MLMultiArray, outputName: String) async throws -> MLMultiArray {
        let provider = try MLDictionaryFeatureProvider(dictionary: [
            inputName: MLFeatureValue(multiArray: input),
        ])
        return try await predict(model: model, provider: provider, outputName: outputName)
    }

    private func predict(model: MLModel, provider: MLFeatureProvider, outputName: String) async throws -> MLMultiArray {
        // See the `nonisolated(unsafe)` note above: MLModel/MLFeatureProvider aren't Sendable, but
        // CoreML documents `prediction(from:)` as safe to call repeatedly on the same instance.
        nonisolated(unsafe) let model = model
        nonisolated(unsafe) let provider = provider
        let output = try await model.prediction(from: provider)
        guard let result = output.featureValue(for: outputName)?.multiArrayValue else {
            throw LocalTranscriptionError.transcriptionFailed("IndicConformer CoreML model did not return \(outputName).")
        }
        return result
    }

    private func makeFloatArray(shape: [Int], values: [Float]) throws -> MLMultiArray {
        let array = try MLMultiArray(shape: shape.map(NSNumber.init(value:)), dataType: .float32)
        let ptr = array.dataPointer.bindMemory(to: Float.self, capacity: array.count)
        let count = min(values.count, array.count)
        _ = values.withUnsafeBufferPointer { source in
            memcpy(ptr, source.baseAddress!, count * MemoryLayout<Float>.stride)
        }
        if count < array.count {
            ptr.advanced(by: count).initialize(repeating: 0, count: array.count - count)
        }
        return array
    }

    private func addArrays(_ lhs: MLMultiArray, _ rhs: MLMultiArray, into output: MLMultiArray) throws {
        let ptr = output.dataPointer.bindMemory(to: Float.self, capacity: output.count)
        for index in 0..<output.count {
            ptr[index] = Self.floatValue(lhs, linearIndex: index) + Self.floatValue(rhs, linearIndex: index)
        }
    }

    private static func floatValue(_ array: MLMultiArray, linearIndex: Int) -> Float {
        floatValue(array, offset: linearIndex)
    }

    private static func floatValue(_ array: MLMultiArray, offset: Int) -> Float {
        switch array.dataType {
        case .float32:
            return array.dataPointer.bindMemory(to: Float.self, capacity: array.count)[offset]
        case .float16:
            #if arch(arm64)
            return Float(array.dataPointer.bindMemory(to: Float16.self, capacity: array.count)[offset])
            #else
            // `Float(Float16)` needs arm64 hardware; on the x86_64 slice (where
            // local models are runtime-gated off and this never executes) use
            // MLMultiArray's portable NSNumber accessor so the slice compiles.
            return array[offset].floatValue
            #endif
        case .double:
            return Float(array.dataPointer.bindMemory(to: Double.self, capacity: array.count)[offset])
        case .int32:
            return Float(array.dataPointer.bindMemory(to: Int32.self, capacity: array.count)[offset])
        default:
            return array[offset].floatValue
        }
    }
}
