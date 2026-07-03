import Foundation

public enum IndicConformerLanguage: String, CaseIterable, Sendable {
    case hi, bn, mr, te, ta, ml, kn

    public var label: String {
        switch self {
        case .hi: return "Hindi"; case .bn: return "Bengali"; case .mr: return "Marathi"
        case .te: return "Telugu"; case .ta: return "Tamil"; case .ml: return "Malayalam"
        case .kn: return "Kannada"
        }
    }

    public var postNetPackage: String { "indic_conformer_joint_post_net_\(rawValue).mlpackage" }

    /// Resolves an incoming language code to one of the seven supported languages,
    /// or `nil` when the code is blank or unsupported. IndicConformer has no
    /// language auto-detect and no meaningful default, so the caller must pass an
    /// explicit supported code — there is deliberately no fallback. Guessing (the
    /// old default-to-Hindi behavior) would silently transcribe an unsupported
    /// request with the wrong language's post-net.
    public static func supported(_ code: String?) -> Self? {
        let normalized = code?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard let normalized, !normalized.isEmpty else { return nil }
        if let exact = Self(rawValue: normalized) { return exact }
        let base = normalized.split(separator: "-").first.map(String.init) ?? normalized
        return Self(rawValue: base)
    }

    /// Supported codes as a comma-separated list, for error messages.
    public static var supportedCodes: String { allCases.map(\.rawValue).joined(separator: ", ") }
}

enum IndicConformerConfig {
    static let repoId = "phequals/indic-conformer-600m-multilingual-coreml-rnnt"
    static let repoRevision = "5590d07c06e95d461790ff753d4af536f0660197"

    // Model contract constants (see Global Constraints).
    static let sampleRate = 16_000
    static let nFFT = 512
    static let hopLength = 160
    static let winLength = 400
    static let nMels = 80
    static let melFrames = 1_024
    static let encoderDim = 1_024
    static let predHiddenDim = 640
    static let predLayers = 2
    static let blankId = 256
    static let sosId = 5_632
    static let rnntMaxSymbols = 10
    static let chunkSeconds = 10.0
    static let overlapSeconds = 1.0

    static let encoderPackage = "indic_conformer_encoder_int8.mlpackage"
    static let rnntDecoderPackage = "indic_conformer_rnnt_decoder_reconstructed.mlpackage"
    static let jointEncPackage = "indic_conformer_joint_enc.mlpackage"
    static let jointPredPackage = "indic_conformer_joint_pred.mlpackage"
    static let jointPreNetPackage = "indic_conformer_joint_pre_net.mlpackage"
    static let vocabFile = "vocab.json"
    static let preprocessorConstantsFile = "preprocessor_constants.bin"

    static let sharedPackages = [
        encoderPackage, rnntDecoderPackage, jointEncPackage, jointPredPackage, jointPreNetPackage,
    ]
    static let languagePackages = IndicConformerLanguage.allCases.map(\.postNetPackage)
    static var allPackages: [String] { sharedPackages + languagePackages }
    /// jointPreNet ships with an empty weights dir (no learned parameters).
    static let weightlessPackages: Set<String> = [jointPreNetPackage]
    static let requiredMetadata = [vocabFile, preprocessorConstantsFile]

    static func packageRelativeDirectory(_ packageName: String) -> String {
        packageName == encoderPackage ? "coreml/encoder/\(packageName)" : "coreml/rnnt/\(packageName)"
    }
    static func metadataRelativePath(_ fileName: String) -> String { "metadata/\(fileName)" }
}
