import Foundation

public protocol LocalTranscriptionEngine: Sendable {
    func isDownloaded(_ model: LocalModel) async -> Bool
    func installedBytes(_ model: LocalModel) async -> Int64
    func download(_ model: LocalModel, progress: @escaping @Sendable (Double) -> Void) async throws
    func delete(_ model: LocalModel) async throws
    func transcribe(audioURL: URL, model: LocalModel, language: String?) async throws -> String
}

public enum LocalTranscriptionError: LocalizedError {
    case unsupportedModel(String)
    case modelNotDownloaded(String)
    case transcriptionFailed(String)

    public var errorDescription: String? {
        switch self {
        case .unsupportedModel(let id):  return "Unknown on-device model \"\(id)\"."
        case .modelNotDownloaded(let n): return "The on-device model \"\(n)\" is not downloaded. Download it in Settings → Models."
        case .transcriptionFailed(let m): return "On-device transcription failed: \(m)"
        }
    }
}
