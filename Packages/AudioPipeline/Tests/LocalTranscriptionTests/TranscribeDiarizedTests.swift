import Testing
import Foundation
@testable import LocalTranscription

private struct FakeTimedEngine: LocalTranscriptionEngine {
    let words: [TimedWord]
    func isDownloaded(_ model: LocalModel) async -> Bool { true }
    func installedBytes(_ model: LocalModel) async -> Int64 { 0 }
    func download(_ model: LocalModel, progress: @escaping @Sendable (Double) -> Void) async throws {}
    func delete(_ model: LocalModel) async throws {}
    func transcribe(audioURL: URL, model: LocalModel, language: String?) async throws -> String {
        words.map(\.text).joined().trimmingCharacters(in: .whitespaces)
    }
    func transcribeTimed(audioURL: URL, model: LocalModel, language: String?) async throws -> [TimedWord] { words }
}

private struct FakeDiarizer: SpeakerDiarizing {
    let segments: [DiarizedSegment]
    func diarize(samples: [Float]) async throws -> [DiarizedSegment] { segments }
}

// A resampler seam is needed because the real AudioConverter reads a file.
// If LocalTranscriptionService loads samples via an injected closure (see Step 3),
// tests pass a stub. Otherwise these tests must point audioURL at a real 16k mono file.

private let turboID = "whisper-large-v3-turbo"

@Test func diarizedOutputLabelsMultipleSpeakers() async throws {
    let words = [TimedWord(text: " hi", start: 0, end: 0.5), TimedWord(text: " yo", start: 2, end: 2.5)]
    let segs  = [DiarizedSegment(speakerId: "S1", start: 0, end: 1), DiarizedSegment(speakerId: "S2", start: 1.5, end: 3)]
    let service = LocalTranscriptionService(
        fluidAudio: FakeTimedEngine(words: []),
        whisperKit: FakeTimedEngine(words: words),
        indicConformer: FakeTimedEngine(words: []),
        diarizer: FakeDiarizer(segments: segs),
        loadSamples: { _ in [] })
    let out = try await service.transcribeDiarized(audioURL: URL(filePath: "/dev/null"), modelID: turboID, language: "en")
    #expect(out == "[00:00] Speaker 1: hi\n[00:02] Speaker 2: yo")
}

@Test func diarizedOutputIsPlainForSingleSpeaker() async throws {
    let words = [TimedWord(text: " a", start: 0, end: 0.5), TimedWord(text: " b", start: 0.5, end: 1)]
    let segs  = [DiarizedSegment(speakerId: "S1", start: 0, end: 2)]
    let service = LocalTranscriptionService(
        fluidAudio: FakeTimedEngine(words: []),
        whisperKit: FakeTimedEngine(words: words),
        indicConformer: FakeTimedEngine(words: []),
        diarizer: FakeDiarizer(segments: segs),
        loadSamples: { _ in [] })
    let out = try await service.transcribeDiarized(audioURL: URL(filePath: "/dev/null"), modelID: turboID, language: "en")
    #expect(out == "a b")
}
