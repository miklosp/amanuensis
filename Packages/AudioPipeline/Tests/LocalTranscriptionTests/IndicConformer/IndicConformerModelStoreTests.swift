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

/// Fabricate compiled `.mlmodelc` dirs (each with a `coremldata.bin`) for the given
/// packages, mirroring what `MLModel.compileModel` writes next to the `.mlpackage`.
private func fabricateCompiled(_ names: [String], root: URL) throws {
    let fm = FileManager.default
    for name in names {
        let compiled = IndicConformerModelStore.compiledURL(name, root: root)
        try fm.createDirectory(at: compiled, withIntermediateDirectories: true)
        try Data().write(to: compiled.appendingPathComponent("coremldata.bin"))
    }
}

@Test func isDownloadedTrueForCompleteTree() throws {
    #expect(IndicConformerModelStore.isDownloaded(root: try fabricateTree()))
}

// Pre-compiling at download time lets us drop the `.mlpackage` sources (halving disk),
// so a compiled-only tree — no `.mlpackage` dirs left — must still read as downloaded.
@Test func isDownloadedTrueForCompiledOnlyTree() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try fabricateCompiled(IndicConformerConfig.allPackages, root: root)
    let meta = root.appendingPathComponent("metadata", isDirectory: true)
    try FileManager.default.createDirectory(at: meta, withIntermediateDirectories: true)
    for f in IndicConformerConfig.requiredMetadata { try Data().write(to: meta.appendingPathComponent(f)) }
    #expect(IndicConformerModelStore.isDownloaded(root: root))
}

@Test func pruneRemovesCompiledPackageSourcesKeepingCompiled() throws {
    let root = try fabricateTree()
    try fabricateCompiled(IndicConformerConfig.allPackages, root: root)
    try IndicConformerModelStore.pruneCompiledPackageSources(root: root)
    let fm = FileManager.default
    for name in IndicConformerConfig.allPackages {
        #expect(!fm.fileExists(atPath: IndicConformerModelStore.packageURL(name, root: root).path))
        #expect(fm.fileExists(atPath: IndicConformerModelStore.compiledURL(name, root: root).path))
    }
    #expect(IndicConformerModelStore.isDownloaded(root: root))
}

// Guard: a `.mlpackage` whose compiled form is absent is the only copy of the weights —
// pruning it would strand the model. Prune must leave uncompiled sources untouched.
@Test func pruneKeepsSourcesForUncompiledPackages() throws {
    let root = try fabricateTree()
    try IndicConformerModelStore.pruneCompiledPackageSources(root: root)
    let fm = FileManager.default
    for name in IndicConformerConfig.allPackages {
        #expect(fm.fileExists(atPath: IndicConformerModelStore.packageURL(name, root: root).path))
    }
}

// With a compiled model already present and no `.mlpackage` source to compile from,
// `ensureCompiled` must take the fast path and return the compiled URL rather than
// attempting a (here impossible) recompile.
@Test func ensureCompiledReusesExistingCompiled() async throws {
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    let name = IndicConformerConfig.encoderPackage
    try fabricateCompiled([name], root: root)
    let url = try await IndicConformerModelStore.ensureCompiled(name, root: root)
    #expect(url == IndicConformerModelStore.compiledURL(name, root: root))
    #expect(fm.fileExists(atPath: url.appendingPathComponent("coremldata.bin").path))
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
