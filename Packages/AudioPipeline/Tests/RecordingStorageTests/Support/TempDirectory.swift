import Foundation

// Runs `body` with a unique temporary directory under the system temp area;
// removes the directory (and anything written under it) on exit, even if
// `body` throws.
func withTempDirectory(_ body: (URL) throws -> Void) throws {
    let url = FileManager.default.temporaryDirectory.appending(
        path: "audio-pipeline-tests-\(UUID().uuidString)",
        directoryHint: .isDirectory
    )
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: url) }
    try body(url)
}
