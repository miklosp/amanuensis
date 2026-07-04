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

    static func isDownloaded(root: URL) -> Bool {
        let fm = FileManager.default
        let packagesOK = IndicConformerConfig.allPackages.allSatisfy { name in
            if fm.fileExists(atPath: compiledURL(name, root: root).appendingPathComponent("coremldata.bin").path) { return true }
            let pkg = packageURL(name, root: root)
            return packageContents(name).allSatisfy { fm.fileExists(atPath: pkg.appendingPathComponent($0).path) }
        }
        let metaOK = IndicConformerConfig.requiredMetadata.allSatisfy { fm.fileExists(atPath: metadataURL($0, root: root).path) }
        return packagesOK && metaOK
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
            progress(Double(index) / Double(total))
            let destination = root.appendingPathComponent(relativePath)
            try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            let (temp, response) = try await URLSession.shared.download(from: remoteURL(for: relativePath))
            do { try requireHTTPOK(response, relativePath) }
            catch { try? fm.removeItem(at: temp); throw error }
            try? fm.removeItem(at: destination)
            try fm.moveItem(at: temp, to: destination)
        }
        // jointPreNet ships weightless: ensure its (empty) weights dir exists before compile.
        for name in IndicConformerConfig.weightlessPackages {
            try fm.createDirectory(at: packageURL(name, root: root).appendingPathComponent("Data/com.apple.CoreML/weights"),
                                   withIntermediateDirectories: true)
        }
        progress(1.0)
    }
}
