import Testing
import Foundation
@testable import LocalTranscription

private func expectTimestampsUnsupported(_ modelID: String) async {
    let engine = FluidAudioEngine()
    let model = LocalModelCatalog.model(id: modelID)!
    do {
        _ = try await engine.transcribeTimed(audioURL: URL(filePath: "/dev/null"), model: model, language: nil)
        Issue.record("expected transcribeTimed to throw for \(modelID)")
    } catch let error as LocalTranscriptionError {
        guard case .timestampsUnsupported = error else {
            Issue.record("expected .timestampsUnsupported for \(modelID), got \(error)")
            return
        }
    } catch {
        Issue.record("unexpected error type for \(modelID): \(error)")
    }
}

@Test func senseVoiceTranscribeTimedThrowsUnsupported() async {
    await expectTimestampsUnsupported("sensevoice-small")
}

@Test func cohereTranscribeTimedThrowsUnsupported() async {
    await expectTimestampsUnsupported("cohere-transcribe")
}
