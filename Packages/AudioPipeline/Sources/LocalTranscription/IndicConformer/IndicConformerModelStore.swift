import CoreML
import Foundation

nonisolated enum IndicConformerModelStore {
    static func root() throws -> URL { try ModelStorage.runnerDir(.indicConformer) }

    static func packageURL(_ name: String, root: URL) -> URL {
        root.appendingPathComponent(IndicConformerConfig.packageRelativeDirectory(name), isDirectory: true)
    }
    static func compiledURL(_ name: String, root: URL) -> URL {
        packageURL(name, root: root).deletingLastPathComponent()
            .appendingPathComponent(name.replacingOccurrences(of: ".mlpackage", with: ".mlmodelc"), isDirectory: true)
    }
    static func metadataURL(_ file: String, root: URL) -> URL {
        root.appendingPathComponent(IndicConformerConfig.metadataRelativePath(file), isDirectory: false)
    }

    private static func packageContents(_ name: String) -> [String] {
        var files = ["Manifest.json", "Data/com.apple.CoreML/model.mlmodel"]
        if !IndicConformerConfig.weightlessPackages.contains(name) { files.append("Data/com.apple.CoreML/weights/weight.bin") }
        return files
    }

    /// A package counts as compiled once its `.mlmodelc` has a `coremldata.bin`. Checking the
    /// marker file (not just the dir) rejects a half-written compile output.
    static func packageCompiled(_ name: String, root: URL) -> Bool {
        FileManager.default.fileExists(atPath: compiledURL(name, root: root).appendingPathComponent("coremldata.bin").path)
    }

    static func isDownloaded(root: URL) -> Bool {
        let fm = FileManager.default
        let packagesOK = IndicConformerConfig.allPackages.allSatisfy { name in
            if packageCompiled(name, root: root) { return true }
            let pkg = packageURL(name, root: root)
            return packageContents(name).allSatisfy { fm.fileExists(atPath: pkg.appendingPathComponent($0).path) }
        }
        let metaOK = IndicConformerConfig.requiredMetadata.allSatisfy { fm.fileExists(atPath: metadataURL($0, root: root).path) }
        return packagesOK && metaOK
    }

    /// Compile a downloaded `.mlpackage` to its sibling `.mlmodelc`, or return the existing
    /// compiled URL if it's already there. Idempotent, so the download-time warm-up and the
    /// lazy first-load path can both call it. Compilation is device/OS-specific, which is why
    /// the repo ships `.mlpackage` sources rather than precompiled `.mlmodelc`.
    static func ensureCompiled(_ name: String, root: URL) async throws -> URL {
        let compiled = compiledURL(name, root: root)
        if packageCompiled(name, root: root) { return compiled }
        let fm = FileManager.default
        // jointPreNet ships weightless: compileModel needs its (empty) weights dir present.
        if IndicConformerConfig.weightlessPackages.contains(name) {
            try fm.createDirectory(at: packageURL(name, root: root).appendingPathComponent("Data/com.apple.CoreML/weights"),
                                   withIntermediateDirectories: true)
        }
        let temp: URL
        do {
            temp = try await MLModel.compileModel(at: packageURL(name, root: root))
        } catch {
            throw LocalTranscriptionError.transcriptionFailed(
                "Failed to compile IndicConformer model \(name): \(error.localizedDescription)")
        }
        try? fm.removeItem(at: compiled)
        try fm.copyItem(at: temp, to: compiled)
        try? fm.removeItem(at: temp)
        return compiled
    }

    /// Delete the `.mlpackage` source of every package whose `.mlmodelc` is present. The
    /// compiled form is all that `load` needs, so keeping both roughly doubles on-disk size.
    /// Only prunes a source once its compiled sibling exists — never the sole copy of weights.
    static func pruneCompiledPackageSources(root: URL) throws {
        let fm = FileManager.default
        for name in IndicConformerConfig.allPackages where packageCompiled(name, root: root) {
            let pkg = packageURL(name, root: root)
            if fm.fileExists(atPath: pkg.path) { try fm.removeItem(at: pkg) }
        }
    }

    static func remoteURL(for relativePath: String) -> URL {
        var url = URL(string: "https://huggingface.co/\(IndicConformerConfig.repoId)/resolve/\(IndicConformerConfig.repoRevision)")!
        for c in relativePath.split(separator: "/") { url.appendPathComponent(String(c), isDirectory: false) }
        var comps = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        comps.queryItems = [URLQueryItem(name: "download", value: "1")]
        return comps.url!
    }

    /// `URLSession.download` does not throw on HTTP-level errors, so a 404 / 429 /
    /// 5xx hands back an error *page* as the "downloaded" file. Reject non-2xx
    /// before it gets moved into the model tree — otherwise `isDownloaded` (which
    /// only checks file existence) would treat the poisoned bundle as complete and
    /// every future load would fail until the user deletes the model by hand.
    static func requireHTTPOK(_ response: URLResponse, _ relativePath: String) throws {
        guard let http = response as? HTTPURLResponse else { return }   // non-HTTP: nothing to check
        guard (200..<300).contains(http.statusCode) else {
            throw LocalTranscriptionError.transcriptionFailed(
                "download of \(relativePath) failed with HTTP \(http.statusCode)")
        }
    }

    /// Share of the progress budget spent fetching vs. compiling. Coarse — the real split
    /// depends on connection speed vs. this machine's Core ML compile time — but reserving a
    /// tail for compilation keeps the bar from parking at 100% through a multi-second compile.
    private static let fetchProgressShare = 0.7

    static func download(root: URL, progress: @Sendable (Double) -> Void) async throws {
        let fm = FileManager.default
        let packageFiles = IndicConformerConfig.allPackages.flatMap { name in
            packageContents(name).map { "\(IndicConformerConfig.packageRelativeDirectory(name))/\($0)" }
        }
        let metadataFiles = IndicConformerConfig.requiredMetadata.map(IndicConformerConfig.metadataRelativePath)
        let required = packageFiles + metadataFiles
        let missing = required.filter { !fm.fileExists(atPath: root.appendingPathComponent($0).path) }
        let total = max(missing.count, 1)
        for (index, relativePath) in missing.enumerated() {
            progress(Double(index) / Double(total) * fetchProgressShare)
            let destination = root.appendingPathComponent(relativePath)
            try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            let (temp, response) = try await URLSession.shared.download(from: remoteURL(for: relativePath))
            do { try requireHTTPOK(response, relativePath) }
            catch { try? fm.removeItem(at: temp); throw error }
            try? fm.removeItem(at: destination)
            try fm.moveItem(at: temp, to: destination)
        }
        // Compile every package to its `.mlmodelc` now, moving the one-time, multi-second Core ML
        // compile out of the first transcription and into the download the user is already waiting
        // on. `ensureCompiled` also creates jointPreNet's (empty) weights dir before compiling it.
        let packages = IndicConformerConfig.allPackages
        for (index, name) in packages.enumerated() {
            progress(fetchProgressShare + Double(index) / Double(packages.count) * (1 - fetchProgressShare))
            _ = try await ensureCompiled(name, root: root)
        }
        // Drop the `.mlpackage` sources: the compiled form is all `load` needs, so keeping both
        // would roughly double on-disk size.
        try pruneCompiledPackageSources(root: root)
        progress(1.0)
    }
}
