import Testing
import Foundation
@testable import DictationCore

private func tmpDir() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("dtest-\(UUID().uuidString)", isDirectory: true)
}

@Test func newCaptureURLIsUniqueWavInDirectory() {
    let store = DictationTempStore(directory: tmpDir())
    let a = store.newCaptureURL()
    let b = store.newCaptureURL()
    #expect(a != b)
    #expect(a.pathExtension == "wav")
    #expect(a.deletingLastPathComponent() == store.directory)
}

@Test func sweepRemovesOrphans() throws {
    let store = DictationTempStore(directory: tmpDir())
    let url = store.newCaptureURL()
    try Data("x".utf8).write(to: url)
    #expect(FileManager.default.fileExists(atPath: url.path))
    store.sweep()
    #expect(!FileManager.default.fileExists(atPath: url.path))
}

@Test func deleteRemovesOne() throws {
    let store = DictationTempStore(directory: tmpDir())
    let url = store.newCaptureURL()
    try Data("x".utf8).write(to: url)
    store.delete(url)
    #expect(!FileManager.default.fileExists(atPath: url.path))
}
