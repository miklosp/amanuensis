import Foundation

extension Provider {
    /// Reserved sentinel `providerID` meaning "on-device (Local)". Not a stored
    /// provider; recognised at the read boundary by `TranscriptionSource`. Fixed
    /// forever — it is persisted in saved jobs / dictation settings.
    public static let localID = UUID(uuidString: "10CA110C-0000-0000-0000-000000000000")!

    /// Transient, non-persisted stand-in for the Local source. `LocalTranscriptionSender`
    /// ignores the provider, so only `id == .localID` matters here.
    public static var localPlaceholder: Provider {
        Provider(name: "Local", presetID: "", baseURL: "",
                 apiKeyRef: KeychainRef(account: ""), id: Provider.localID)
    }
}

/// The target of a transcription, resolved from the persisted `providerID: UUID?`.
/// Keeps the magic sentinel in ONE place so all logic switches exhaustively.
public enum TranscriptionSource: Equatable, Sendable {
    case none                 // providerID == nil (draft / unset)
    case local                // providerID == Provider.localID
    case provider(UUID)       // a stored provider

    public init(providerID: UUID?) {
        guard let id = providerID else { self = .none; return }
        self = (id == Provider.localID) ? .local : .provider(id)
    }

    public var providerID: UUID? {
        switch self {
        case .none: return nil
        case .local: return Provider.localID
        case .provider(let id): return id
        }
    }
}
