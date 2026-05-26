import Foundation
import Testing
@testable import AudioPipelineJobs

private func tempFile() -> URL {
    let dir = URL(fileURLWithPath: NSTemporaryDirectory())
    return dir.appendingPathComponent("jobs-\(UUID().uuidString).json")
}

private func makeJob(name: String = "demo") -> Job {
    Job(name: name, presetID: "openai-compat-chat",
        baseURL: "http://localhost:4444/openai",
        model: "gemini-flash",
        apiKeyRef: KeychainRef(account: "bifrost"),
        fields: ["prompt": "Transcribe this."],
        outputExt: "txt")
}

@MainActor
@Suite struct JobsStoreBehavior {
    @Test func emptyStore_hasNoJobs() throws {
        let store = try JobsStore(fileURL: tempFile())
        #expect(store.jobs.isEmpty)
    }

    @Test func upsert_addsNewJob() throws {
        let store = try JobsStore(fileURL: tempFile())
        let job = makeJob()
        store.upsert(job)
        #expect(store.jobs == [job])
    }

    @Test func upsert_replacesExistingByID() throws {
        let store = try JobsStore(fileURL: tempFile())
        var job = makeJob()
        store.upsert(job)
        job.name = "renamed"
        store.upsert(job)
        #expect(store.jobs.count == 1)
        #expect(store.jobs.first?.name == "renamed")
    }

    @Test func delete_removesByID() throws {
        let store = try JobsStore(fileURL: tempFile())
        let job = makeJob()
        store.upsert(job)
        store.delete(id: job.id)
        #expect(store.jobs.isEmpty)
    }

    @Test func persistsAcrossInstances() throws {
        let url = tempFile()
        let first = try JobsStore(fileURL: url)
        first.upsert(makeJob(name: "persisted"))
        let second = try JobsStore(fileURL: url)
        #expect(second.jobs.first?.name == "persisted")
    }
}
