import Foundation
import Testing
@testable import LocalTranscription

private func fixtureURL(_ name: String) -> URL? {
    let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures")
    let url = dir.appendingPathComponent(name)
    return FileManager.default.fileExists(atPath: url.path) ? url : nil
}

@Test func transcribesHindiEndToEndWhenModelAndFixturePresent() async throws {
    let engine = IndicConformerEngine()
    let model = LocalModelCatalog.model(id: "indic-conformer-600m")!
    guard await engine.isDownloaded(model), let wav = fixtureURL("fleurs_hi.wav") else {
        // Model or fixture absent (e.g. CI) — nothing to verify, pass by skipping.
        return
    }
    try await engine.preload(model)
    let text = try await engine.transcribe(audioURL: wav, model: model, language: "hi")
    #expect(!text.isEmpty)
    // Loose check: at least one Devanagari scalar present.
    #expect(text.unicodeScalars.contains { (0x0900...0x097F).contains($0.value) })
    print("INDIC_E2E transcript=\(text)")
}
