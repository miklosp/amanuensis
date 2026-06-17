import Foundation
import Security

// Async wrapper around Security.framework. The actor serialises access so
// callers don't need to think about thread safety. Service id is injected;
// production uses the app's bundle id, tests use a per-run unique id.
public actor KeychainStore {
    public enum Error: Swift.Error, Equatable {
        case itemNotFound
        case unexpectedData
        case osStatus(OSStatus)
    }

    public static let defaultService = "work.miklos.amanuensis.api-keys"

    private let service: String

    public init(service: String = KeychainStore.defaultService) {
        self.service = service
    }

    public func set(account: String, key: String) throws {
        let data = Data(key.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]

        // Try update first; if missing, add. Cheaper than always delete+add.
        let updateAttrs: [String: Any] = [kSecValueData as String: data]
        let updateStatus = SecItemUpdate(query as CFDictionary, updateAttrs as CFDictionary)
        if updateStatus == errSecSuccess { return }
        if updateStatus != errSecItemNotFound { throw Error.osStatus(updateStatus) }

        var addQuery = query
        addQuery[kSecValueData as String] = data
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        guard addStatus == errSecSuccess else { throw Error.osStatus(addStatus) }
    }

    public func get(account: String) throws -> String {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { throw Error.itemNotFound }
        guard status == errSecSuccess else { throw Error.osStatus(status) }
        guard let data = result as? Data, let str = String(data: data, encoding: .utf8) else {
            throw Error.unexpectedData
        }
        return str
    }

    public func list() throws -> [String] {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return [] }
        guard status == errSecSuccess else { throw Error.osStatus(status) }
        guard let items = result as? [[String: Any]] else { return [] }
        return items.compactMap { $0[kSecAttrAccount as String] as? String }
    }

    public func delete(account: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let status = SecItemDelete(query as CFDictionary)
        if status == errSecItemNotFound { return }
        guard status == errSecSuccess else { throw Error.osStatus(status) }
    }

    public func deleteAll() throws {
        // macOS legacy file-based keychain removes one item per SecItemDelete
        // call when the query has no kSecMatchLimit. Loop until nothing matches.
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
        ]
        while true {
            let status = SecItemDelete(query as CFDictionary)
            if status == errSecItemNotFound { return }
            guard status == errSecSuccess else { throw Error.osStatus(status) }
        }
    }
}

// Minimal protocol so JobRunner can be tested with a fake.
public protocol KeychainProviding: Sendable {
    func get(account: String) async throws -> String
}

extension KeychainStore: KeychainProviding {}
