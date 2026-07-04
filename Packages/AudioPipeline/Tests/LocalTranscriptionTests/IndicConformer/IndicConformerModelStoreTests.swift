import Foundation
import Testing
@testable import LocalTranscription

private func fabricateTree() throws -> URL {
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    for name in IndicConformerConfig.allPackages {
        let pkg = IndicConformerModelStore.packageURL(name, root: root)
        try fm.createDirectory(at: pkg.appendingPathComponent("Data/com.apple.CoreML/weights"), withIntermediateDirectories: true)
        try Data().write(to: pkg.appendingPathComponent("Manifest.json"))
        try Data().write(to: pkg.appendingPathComponent("Data/com.apple.CoreML/model.mlmodel"))
        if !IndicConformerConfig.weightlessPackages.contains(name) {
            try Data().write(to: pkg.appendingPathComponent("Data/com.apple.CoreML/weights/weight.bin"))
        }
    }
    let meta = root.appendingPathComponent("metadata", isDirectory: true)
    try fm.createDirectory(at: meta, withIntermediateDirectories: true)
    for f in IndicConformerConfig.requiredMetadata { try Data().write(to: meta.appendingPathComponent(f)) }
    return root
}

@Test func isDownloadedTrueForCompleteTree() throws {
    #expect(IndicConformerModelStore.isDownloaded(root: try fabricateTree()))
}

@Test func isDownloadedFalseWhenAPackageMissing() throws {
    let root = try fabricateTree()
    try FileManager.default.removeItem(at: IndicConformerModelStore.packageURL(IndicConformerConfig.encoderPackage, root: root))
    #expect(!IndicConformerModelStore.isDownloaded(root: root))
}

@Test func isDownloadedFalseWhenMetadataMissing() throws {
    let root = try fabricateTree()
    try FileManager.default.removeItem(at: IndicConformerModelStore.metadataURL(IndicConformerConfig.vocabFile, root: root))
    #expect(!IndicConformerModelStore.isDownloaded(root: root))
}

@Test func remoteURLPinsRevisionAndPath() {
    let url = IndicConformerModelStore.remoteURL(for: "metadata/vocab.json").absoluteString
    #expect(url.contains(IndicConformerConfig.repoId))
    #expect(url.contains(IndicConformerConfig.repoRevision))
    #expect(url.hasSuffix("metadata/vocab.json?download=1"))
}

@Test func requireHTTPOKAccepts2xxAndRejectsErrors() throws {
    let url = URL(string: "https://huggingface.co/x")!
    // 2xx passes.
    for code in [200, 206, 299] {
        let ok = HTTPURLResponse(url: url, statusCode: code, httpVersion: nil, headerFields: nil)!
        try IndicConformerModelStore.requireHTTPOK(ok, "a/b.bin")
    }
    // Non-2xx (rate-limit / not-found / server error / redirect) throws instead of
    // letting an error page be cached as a model file.
    for code in [301, 404, 429, 500, 503] {
        let bad = HTTPURLResponse(url: url, statusCode: code, httpVersion: nil, headerFields: nil)!
        #expect(throws: LocalTranscriptionError.self) {
            try IndicConformerModelStore.requireHTTPOK(bad, "a/b.bin")
        }
    }
}
