import Testing
import Foundation
import FluidAudio
@testable import LocalTranscription

@Test func diarizesTwoSpeakerFixtureWhenModelsPresent() async throws {
    // Provide a 2-speaker 16k mono fixture path via env; skip silently if unset/missing.
    guard let path = ProcessInfo.processInfo.environment["AMANUENSIS_DIARIZATION_FIXTURE"],
          FileManager.default.fileExists(atPath: path) else { return }
    let samples = try AudioConverter().resampleAudioFile(URL(filePath: path))
    let diarizer = FluidAudioDiarizer()
    let segments = try await diarizer.diarize(samples: samples)
    #expect(Set(segments.map(\.speakerId)).count >= 2)
    #expect(segments.allSatisfy { $0.end > $0.start })
}
