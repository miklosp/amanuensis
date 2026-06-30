import Foundation
@testable import LocalTranscription

actor FakeEngine: LocalTranscriptionEngine {
    var downloaded: Set<String> = []
    var transcript = "fake transcript"
    var lastTranscribedModel: String?

    func isDownloaded(_ model: LocalModel) async -> Bool { downloaded.contains(model.id) }
    func installedBytes(_ model: LocalModel) async -> Int64 { downloaded.contains(model.id) ? 123 : 0 }
    func download(_ model: LocalModel, progress: @escaping @Sendable (Double) -> Void) async throws {
        progress(0.5); progress(1.0); downloaded.insert(model.id)
    }
    func delete(_ model: LocalModel) async throws { downloaded.remove(model.id) }
    func transcribe(audioURL: URL, model: LocalModel, language: String?) async throws -> String {
        guard downloaded.contains(model.id) else { throw LocalTranscriptionError.modelNotDownloaded(model.displayName) }
        lastTranscribedModel = model.id
        return transcript
    }
}
