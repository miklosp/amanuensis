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

// Real-model E2E: opt-in via AMANUENSIS_DIARIZATION_FIXTURE (an English audio clip) and a
// downloaded Parakeet model. Silently no-ops when the fixture or models are absent — like the
// other gated E2Es (DiarizationE2ETests). Proves tokenTimings is actually populated per version.
@Test func parakeetVersionsProduceTimedWordsWhenPresent() async throws {
    guard let path = ProcessInfo.processInfo.environment["AMANUENSIS_DIARIZATION_FIXTURE"],
          FileManager.default.fileExists(atPath: path) else { return }
    let engine = FluidAudioEngine()
    // Both versions support English, so the same fixture exercises each. tdtJa needs a Japanese
    // clip and is verified manually.
    for id in ["parakeet-tdt-ctc-110m", "parakeet-tdt-v3"] {
        let model = LocalModelCatalog.model(id: id)!
        guard await engine.isDownloaded(model) else { continue }
        let words = try await engine.transcribeTimed(
            audioURL: URL(filePath: path), model: model, language: "en")
        #expect(!words.isEmpty, "\(id) produced no timed words")
        #expect(words.allSatisfy { $0.end >= $0.start }, "\(id) has a word with end < start")
        #expect(words.allSatisfy { $0.text.hasPrefix(" ") }, "\(id) violated the leading-space convention")
        #expect(zip(words, words.dropFirst()).allSatisfy { $0.start <= $1.start }, "\(id) word starts not monotonic")
    }
}
