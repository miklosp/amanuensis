public enum DictationError: Error, Equatable, Sendable {
    case noProviderConfigured
    case unsupportedShape
    case transcriptionFailed(String)
}
