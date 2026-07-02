import Foundation
import Testing
@testable import LocalTranscription

// Mirrors WhisperKit.loadModels' precondition: the three compiled models must all
// be present, so a crash-interrupted download is not reported as ready.
@Test func whisperKitDownloadRequiresAllThreeCompiledModels() throws {
    let fm = FileManager.default
    let dir = fm.temporaryDirectory.appendingPathComponent("wk-\(UUID().uuidString)", isDirectory: true)
    try fm.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: dir) }

    #expect(WhisperKitEngine.hasRequiredModels(in: dir) == false)   // empty folder

    for name in ["MelSpectrogram", "AudioEncoder"] {                // interrupted: 2 of 3
        try fm.createDirectory(
            at: dir.appendingPathComponent("\(name).mlmodelc", isDirectory: true),
            withIntermediateDirectories: true)
    }
    #expect(WhisperKitEngine.hasRequiredModels(in: dir) == false)

    try fm.createDirectory(
        at: dir.appendingPathComponent("TextDecoder.mlmodelc", isDirectory: true),
        withIntermediateDirectories: true)
    #expect(WhisperKitEngine.hasRequiredModels(in: dir) == true)    // complete
}
