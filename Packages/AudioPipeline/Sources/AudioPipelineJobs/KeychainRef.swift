import Foundation

// A name pointing at a Keychain entry. The actual secret never travels with
// the Job; it's fetched from KeychainStore at run time.
public struct KeychainRef: Codable, Hashable, Sendable {
    public let account: String      // user-chosen label, e.g. "openai-personal"

    public init(account: String) {
        self.account = account
    }
}
