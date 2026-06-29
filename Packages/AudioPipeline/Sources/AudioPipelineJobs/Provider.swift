import Foundation

// User-defined API endpoint + credentials. Many Jobs reference one Provider.
// Shape (the wire-level protocol) is pinned by the Provider's preset, so
// switching presets is a deliberate decision the user makes on the Provider,
// not implicitly when editing a Job.
public struct Provider: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    public var name: String
    public var presetID: String
    public var baseURL: String
    public var apiKeyRef: KeychainRef

    public init(name: String, presetID: String,
                baseURL: String, apiKeyRef: KeychainRef, id: UUID = UUID()) {
        self.id = id
        self.name = name
        self.presetID = presetID
        self.baseURL = baseURL
        self.apiKeyRef = apiKeyRef
    }

    // A base URL is acceptable only if its transport won't leak the attached
    // API key over cleartext: https is always allowed; plain http only for a
    // loopback host (the local dev/proxy case, e.g. a Bifrost gateway). A
    // missing scheme is rejected so the URL is unambiguous.
    public static func isAcceptableBaseURL(_ string: String) -> Bool {
        guard let url = URL(string: string), let scheme = url.scheme?.lowercased() else {
            return false
        }
        switch scheme {
        case "https":
            return true
        case "http":
            let host = (url.host ?? "").lowercased()
            return host == "localhost" || host == "127.0.0.1" || host == "::1"
        default:
            return false
        }
    }

    public static func makeDraft(presets: PresetsStore) -> Provider {
        let first = presets.all.first
        return Provider(
            name: "Untitled provider",
            presetID: first?.id ?? "",
            baseURL: first?.baseURL ?? "",
            apiKeyRef: KeychainRef(account: "")
        )
    }
}
