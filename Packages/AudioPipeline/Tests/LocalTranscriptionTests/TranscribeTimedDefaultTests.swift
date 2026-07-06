import Testing
import Foundation
@testable import LocalTranscription

private struct NoTimestampEngine: LocalTranscriptionEngine {
    func isDownloaded(_ model: LocalModel) async -> Bool { true }
    func installedBytes(_ model: LocalModel) async -> Int64 { 0 }
    func download(_ model: LocalModel, progress: @escaping @Sendable (Double) -> Void) async throws {}
    func delete(_ model: LocalModel) async throws {}
    func transcribe(audioURL: URL, model: LocalModel, language: String?) async throws -> String { "plain" }
    // uses default transcribeTimed
}

@Test func defaultTranscribeTimedThrowsUnsupported() async {
    let engine = NoTimestampEngine()
    let model = LocalModelCatalog.all[0]
    await #expect(throws: LocalTranscriptionError.self) {
        _ = try await engine.transcribeTimed(audioURL: URL(filePath: "/dev/null"), model: model, language: nil)
    }
}
