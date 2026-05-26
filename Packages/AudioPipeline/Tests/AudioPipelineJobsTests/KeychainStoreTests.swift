import Foundation
import Testing
@testable import AudioPipelineJobs

// Each test uses a unique service so concurrent runs and prior failures
// don't collide. teardown wipes everything under that service.
private func withFreshKeychain(_ body: (KeychainStore) async throws -> Void) async throws {
    let service = "work.miklos.audio-pipeline.test-\(UUID().uuidString)"
    let store = KeychainStore(service: service)
    do {
        try await body(store)
        try? await store.deleteAll()
    } catch {
        try? await store.deleteAll()
        throw error
    }
}

@Suite struct KeychainStoreBehavior {
    @Test func set_then_get_returnsTheKey() async throws {
        try await withFreshKeychain { store in
            try await store.set(account: "test-account", key: "sk-secret-123")
            let value = try await store.get(account: "test-account")
            #expect(value == "sk-secret-123")
        }
    }

    @Test func set_overwrites_existingValue() async throws {
        try await withFreshKeychain { store in
            try await store.set(account: "acc", key: "first")
            try await store.set(account: "acc", key: "second")
            let value = try await store.get(account: "acc")
            #expect(value == "second")
        }
    }

    @Test func list_returnsAllAccounts() async throws {
        try await withFreshKeychain { store in
            try await store.set(account: "a", key: "1")
            try await store.set(account: "b", key: "2")
            let accounts = try await store.list()
            #expect(Set(accounts) == ["a", "b"])
        }
    }

    @Test func delete_removesEntry() async throws {
        try await withFreshKeychain { store in
            try await store.set(account: "doomed", key: "x")
            try await store.delete(account: "doomed")
            do {
                _ = try await store.get(account: "doomed")
                Issue.record("expected get to throw after delete")
            } catch KeychainStore.Error.itemNotFound {
                // expected
            }
        }
    }

    @Test func get_unknownAccount_throwsItemNotFound() async throws {
        try await withFreshKeychain { store in
            do {
                _ = try await store.get(account: "missing")
                Issue.record("expected itemNotFound")
            } catch KeychainStore.Error.itemNotFound {
                // expected
            }
        }
    }
}
