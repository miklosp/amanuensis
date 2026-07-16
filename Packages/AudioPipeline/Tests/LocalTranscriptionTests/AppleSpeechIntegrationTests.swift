import Foundation
import Testing
import Speech
@testable import LocalTranscription

@Suite struct AppleSpeechIntegrationTests {
    /// Real Apple Speech transcription of an English clip. Skips silently (like the other
    /// on-device e2e tests) unless macOS 26 Apple Speech is available AND a fixture path is
    /// supplied via AMANUENSIS_APPLE_SPEECH_FIXTURE (a short English audio file).
    ///
    /// `@available` sits on the test function, not the `@Suite` type: swift-testing rejects
    /// `@available` on a `@Suite` struct (swiftlang/swift-testing#608).
    @available(macOS 26, *)
    @Test func transcribesEnglishClipWhenAvailable() async throws {
        guard SpeechTranscriber.isAvailable,
              let path = ProcessInfo.processInfo.environment["AMANUENSIS_APPLE_SPEECH_FIXTURE"],
              FileManager.default.fileExists(atPath: path) else { return }
        let clip = URL(fileURLWithPath: path)
        let engine = AppleSpeechEngine()
        let model = LocalModelCatalog.model(id: "apple-speech")!

        let text = try await engine.transcribe(audioURL: clip, model: model, language: "en")
        #expect(!text.isEmpty)
        print("APPLE_SPEECH_E2E[en]: \(text)")

        let words = try await engine.transcribeTimed(audioURL: clip, model: model, language: "en")
        #expect(!words.isEmpty)
        #expect(words.allSatisfy { $0.end >= $0.start })
    }
}
