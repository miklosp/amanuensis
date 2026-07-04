import CoreML
import Foundation

nonisolated struct IndicConformerModels {
    let encoder: MLModel
    let decoder: MLModel
    let jointEnc: MLModel
    let jointPred: MLModel
    let jointPreNet: MLModel
    let jointPostNets: [IndicConformerLanguage: MLModel]
    let mel: IndicConformerMel
    let vocab: IndicConformerVocab

    /// A fresh per-transcribe inference session — its own `DecodeWorkspace` + encoder-frame
    /// stash — sharing the resident read-only MLModels + mel. Concurrent/reentrant transcribes
    /// MUST each build their own session; never share one `CoreMLIndicInference` across them.
    func makeInference() throws -> CoreMLIndicInference {
        try CoreMLIndicInference(encoder: encoder, decoder: decoder, jointEnc: jointEnc,
                                 jointPred: jointPred, jointPreNet: jointPreNet,
                                 jointPostNets: jointPostNets, mel: mel)
    }

    static func load(root: URL) async throws -> IndicConformerModels {
        let config = MLModelConfiguration()
        config.computeUnits = .all

        var postNets: [IndicConformerLanguage: MLModel] = [:]
        for language in IndicConformerLanguage.allCases {
            postNets[language] = try await loadModel(language.postNetPackage, root: root, config: config)
        }
        let encoder = try await loadModel(IndicConformerConfig.encoderPackage, root: root, config: config)
        let decoder = try await loadModel(IndicConformerConfig.rnntDecoderPackage, root: root, config: config)
        let jointEnc = try await loadModel(IndicConformerConfig.jointEncPackage, root: root, config: config)
        let jointPred = try await loadModel(IndicConformerConfig.jointPredPackage, root: root, config: config)
        let jointPreNet = try await loadModel(IndicConformerConfig.jointPreNetPackage, root: root, config: config)

        let constants = try IndicConformerPreprocessorConstants.load(
            from: IndicConformerModelStore.metadataURL(IndicConformerConfig.preprocessorConstantsFile, root: root))
        let mel = try IndicConformerMel(constants: constants)
        let vocab = try IndicConformerVocab(vocabURL: IndicConformerModelStore.metadataURL(IndicConformerConfig.vocabFile, root: root))

        return IndicConformerModels(
            encoder: encoder, decoder: decoder, jointEnc: jointEnc, jointPred: jointPred,
            jointPreNet: jointPreNet, jointPostNets: postNets, mel: mel, vocab: vocab)
    }

    private static func loadModel(_ name: String, root: URL, config: MLModelConfiguration) async throws -> MLModel {
        // Compiled at download time; this lazily compiles only if that was skipped or the
        // `.mlmodelc` is missing (idempotent — see `IndicConformerModelStore.ensureCompiled`).
        let modelURL = try await IndicConformerModelStore.ensureCompiled(name, root: root)
        // See CoreMLIndicInference's `predict(model:provider:outputName:)` note: MLModelConfiguration
        // isn't Sendable, but it's only read here (computeUnits set once by the caller), and CoreML's
        // async load API predates structured concurrency's Sendable checking.
        nonisolated(unsafe) let config = config
        do {
            return try await MLModel.load(contentsOf: modelURL, configuration: config)
        } catch {
            throw LocalTranscriptionError.transcriptionFailed(
                "Failed to load IndicConformer model \(name): \(error.localizedDescription)")
        }
    }
}
