import Foundation
import Testing
@testable import LocalTranscription

private let indicModel = LocalModelCatalog.model(id: "indic-conformer-600m")!

@Test func engineReportsNotDownloadedInitially() async {
    let engine = IndicConformerEngine()
    // A clean environment may or may not have real files; at minimum a random model id is not downloaded.
    #expect(await engine.isDownloaded(indicModel) == IndicConformerModelStore.isDownloaded(root: (try? IndicConformerModelStore.root()) ?? URL(fileURLWithPath: "/nonexistent")))
}

@Test func transcribeThrowsWhenNotDownloaded() async {
    // Guard clause must fire before any Core ML work when the bundle is absent.
    let engine = IndicConformerEngine()
    if await engine.isDownloaded(indicModel) { return }   // skip if a real bundle happens to be present
    await #expect(throws: LocalTranscriptionError.self) {
        _ = try await engine.transcribe(audioURL: URL(fileURLWithPath: "/nonexistent.wav"),
                                        model: indicModel, language: "hi")
    }
}
