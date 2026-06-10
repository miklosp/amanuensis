import Foundation
import Testing
@testable import AppLog

private func tempFile() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString)
        .appendingPathExtension("json")
}

@Suite struct LogStoreBehavior {
    @Test func logAppendsEntry() {
        let store = LogStore(fileURL: tempFile())
        store.log(.info, "hello", category: .job)
        #expect(store.entries.count == 1)
        #expect(store.entries.first?.message == "hello")
        #expect(store.entries.first?.level == .info)
        #expect(store.entries.first?.category == .job)
    }

    @Test func logTrimsToLimitKeepingMostRecent() {
        let store = LogStore(fileURL: tempFile(), limit: 3)
        for i in 1...5 {
            store.log(.info, "entry \(i)", category: .job)
        }
        #expect(store.entries.count == 3)
        // Oldest two dropped; order preserved oldest -> newest.
        #expect(store.entries.map(\.message) == ["entry 3", "entry 4", "entry 5"])
    }

    @Test func persistenceRoundTrip() {
        let url = tempFile()
        let store = LogStore(fileURL: url)
        store.log(.warning, "first", category: .recording)
        store.log(.error, "second", category: .job)
        let captured = store.entries

        let reloaded = LogStore(fileURL: url)
        #expect(reloaded.entries == captured)
    }

    @Test func clearEmptiesAndPersists() {
        let url = tempFile()
        let store = LogStore(fileURL: url)
        store.log(.info, "x", category: .job)
        store.clear()
        #expect(store.entries.isEmpty)

        let reloaded = LogStore(fileURL: url)
        #expect(reloaded.entries.isEmpty)
    }

    @Test func missingFileYieldsEmpty() {
        let store = LogStore(fileURL: tempFile())  // path does not exist yet
        #expect(store.entries.isEmpty)
    }

    @Test func corruptFileYieldsEmpty() throws {
        let url = tempFile()
        try Data("not json".utf8).write(to: url)
        let store = LogStore(fileURL: url)
        #expect(store.entries.isEmpty)
    }
}
