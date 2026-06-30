// ModelStorageTests.swift
import Foundation
import Testing
@testable import LocalTranscription

@Test func directorySizeSumsFilesRecursively() throws {
    let tmp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
    let sub = tmp.appendingPathComponent("a/b")
    try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
    try Data(count: 1000).write(to: tmp.appendingPathComponent("root.bin"))
    try Data(count: 2000).write(to: sub.appendingPathComponent("leaf.bin"))
    defer { try? FileManager.default.removeItem(at: tmp) }
    #expect(ModelStorage.directorySize(tmp) == 3000)
}

@Test func directorySizeIsZeroForMissingDir() {
    #expect(ModelStorage.directorySize(URL(fileURLWithPath: "/no/such/dir/\(UUID())")) == 0)
}

@Test func runnerDirIsUnderBase() throws {
    let dir = try ModelStorage.runnerDir(.whisperKit)
    #expect(dir.path.contains("Amanuensis/Models"))
}
