import Testing
import Foundation
@testable import LocalTranscription

@Suite struct AppleSpeechDispatchTests {
    private func fixtureURL() -> URL { URL(fileURLWithPath: "/dev/null") }

    @Test func catalogHasAppleSpeechRow() {
        let m = LocalModelCatalog.model(id: "apple-speech")
        #expect(m != nil)
        #expect(m?.runner == .appleSpeech)
        #expect(m?.recommended == false)
        #expect(m?.defaultLanguage == nil)
        #expect((m?.supportedLanguages.isEmpty ?? true) == false)
        // Parakeet stays THE recommended default.
        #expect(LocalModelCatalog.model(id: "parakeet-tdt-ctc-110m")?.recommended == true)
    }

    @Test func nonAppleModelsAlwaysAvailable() {
        for m in LocalModelCatalog.all where m.runner != .appleSpeech {
            #expect(m.isAvailableOnThisOS)
        }
        #expect(LocalModelCatalog.available.allSatisfy { $0.isAvailableOnThisOS })
    }

    @Test func routesToInjectedAppleEngine() async throws {
        let fake = FakeEngine()
        await fake.setDownloaded(["apple-speech"])
        await fake.setTranscript("apple result")
        let svc = LocalTranscriptionService(
            fluidAudio: FakeEngine(), whisperKit: FakeEngine(),
            indicConformer: FakeEngine(), appleSpeech: fake)
        let text = try await svc.transcribe(audioURL: fixtureURL(), modelID: "apple-speech", language: "en")
        #expect(text == "apple result")
    }

    @Test func missingAppleEngineThrowsRequiresNewerOS() async {
        let svc = LocalTranscriptionService(
            fluidAudio: FakeEngine(), whisperKit: FakeEngine(),
            indicConformer: FakeEngine())   // appleSpeech defaults to nil
        await #expect(throws: LocalTranscriptionError.self) {
            _ = try await svc.transcribe(audioURL: fixtureURL(), modelID: "apple-speech", language: "en")
        }
    }
}
