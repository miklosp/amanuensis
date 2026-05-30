import Foundation
import Testing
@testable import AudioPipelineJobs

private func tempFile() -> URL {
    URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("providers-\(UUID().uuidString).json")
}

private func makeProvider(name: String = "demo") -> Provider {
    Provider(name: name, presetID: "openai-compat-chat",
             baseURL: "http://localhost:4444/openai",
             apiKeyRef: KeychainRef(account: "bifrost"))
}

@MainActor
@Suite struct ProvidersStoreBehavior {
    @Test func emptyStore_hasNoProviders() throws {
        let store = try ProvidersStore(fileURL: tempFile())
        #expect(store.providers.isEmpty)
    }

    @Test func upsert_addsNewProvider() throws {
        let store = try ProvidersStore(fileURL: tempFile())
        let p = makeProvider()
        store.upsert(p)
        #expect(store.providers == [p])
    }

    @Test func upsert_replacesExistingByID() throws {
        let store = try ProvidersStore(fileURL: tempFile())
        var p = makeProvider()
        store.upsert(p)
        p.name = "renamed"
        store.upsert(p)
        #expect(store.providers.count == 1)
        #expect(store.providers.first?.name == "renamed")
    }

    @Test func delete_removesByID() throws {
        let store = try ProvidersStore(fileURL: tempFile())
        let p = makeProvider()
        store.upsert(p)
        store.delete(id: p.id)
        #expect(store.providers.isEmpty)
    }

    @Test func provider_byID_returnsMatchOrNil() throws {
        let store = try ProvidersStore(fileURL: tempFile())
        let p = makeProvider()
        store.upsert(p)
        #expect(store.provider(id: p.id) == p)
        #expect(store.provider(id: UUID()) == nil)
    }

    @Test func persistsAcrossInstances() throws {
        let url = tempFile()
        let first = try ProvidersStore(fileURL: url)
        first.upsert(makeProvider(name: "persisted"))
        let second = try ProvidersStore(fileURL: url)
        #expect(second.providers.first?.name == "persisted")
    }
}
