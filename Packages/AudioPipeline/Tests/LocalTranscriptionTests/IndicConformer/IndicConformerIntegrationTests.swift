import Foundation
import Testing
@testable import LocalTranscription

/// One supported language + the Unicode block its script occupies, used to
/// sanity-check that a transcript came out in the right script.
private struct IndicLang {
    let code: String
    let scriptRange: ClosedRange<UInt32>
    let name: String
}

private let indicLangs: [IndicLang] = [
    IndicLang(code: "hi", scriptRange: 0x0900...0x097F, name: "Hindi (Devanagari)"),
    IndicLang(code: "mr", scriptRange: 0x0900...0x097F, name: "Marathi (Devanagari)"),
    IndicLang(code: "bn", scriptRange: 0x0980...0x09FF, name: "Bengali"),
    IndicLang(code: "te", scriptRange: 0x0C00...0x0C7F, name: "Telugu"),
    IndicLang(code: "ta", scriptRange: 0x0B80...0x0BFF, name: "Tamil"),
    IndicLang(code: "ml", scriptRange: 0x0D00...0x0D7F, name: "Malayalam"),
    IndicLang(code: "kn", scriptRange: 0x0C80...0x0CFF, name: "Kannada"),
]

private func fixturesDir() -> URL {
    URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures")
}

private func fixtureURL(_ name: String) -> URL? {
    let url = fixturesDir().appendingPathComponent(name)
    return FileManager.default.fileExists(atPath: url.path) ? url : nil
}

private func fixtureText(_ name: String) -> String? {
    guard let url = fixtureURL(name) else { return nil }
    return try? String(contentsOf: url, encoding: .utf8)
}

/// Gated end-to-end test across all seven Indic languages. Skips (passes) when
/// the real ~700 MB model isn't downloaded or no FLEURS fixtures are present —
/// so CI/dev without the weights stays green. When the model + fixtures are
/// present (run `scripts/fetch-fleurs-indic-samples.sh` first, and download the
/// model in-app), it transcribes each language's clip and checks the output is
/// non-empty and in that language's script. It prints the reference transcript
/// next to the hypothesis for each language so you can eyeball the match — there
/// is no strict WER assertion (ASR output won't match the reference exactly).
@Test func transcribesAllIndicLanguagesEndToEndWhenModelAndFixturesPresent() async throws {
    let engine = IndicConformerEngine()
    let model = LocalModelCatalog.model(id: "indic-conformer-600m")!
    guard await engine.isDownloaded(model) else { return }   // model absent — skip

    let present = indicLangs.filter { fixtureURL("fleurs_\($0.code).wav") != nil }
    guard !present.isEmpty else { return }                    // no fixtures — skip

    try await engine.preload(model)
    for lang in present {
        let wav = fixtureURL("fleurs_\(lang.code).wav")!
        let text = try await engine.transcribe(audioURL: wav, model: model, language: lang.code)
        let expected = fixtureText("fleurs_\(lang.code).txt") ?? "(no reference)"
        print("INDIC_E2E[\(lang.code)] expected = \(expected)")
        print("INDIC_E2E[\(lang.code)] got      = \(text)")
        #expect(!text.isEmpty, "\(lang.name): empty transcript")
        #expect(
            text.unicodeScalars.contains { lang.scriptRange.contains($0.value) },
            "\(lang.name): transcript has no \(lang.name) script")
    }
}
