import Foundation

/// All persisted dictation preferences. Stored by `AppSettings` as one JSON
/// blob (see Task 6).
public struct DictationSettings: Codable, Equatable, Sendable {
    public enum ShortTapAction: String, Codable, Sendable {
        case oneShot        // tap toggles a single capture (default, today's behaviour)
        case autoListening  // tap toggles the always-on auto-dictation loop
    }

    public var enabled: Bool
    public var trigger: TriggerModifier
    public var holdThresholdMs: Int
    public var providerID: UUID?
    public var model: String
    public var insertMode: InsertMode
    public var showOverlay: Bool
    public var keepAudio: Bool
    public var streamLive: Bool
    public var shortTapAction: ShortTapAction
    public var language: String

    public init(
        enabled: Bool = false,
        trigger: TriggerModifier = .rightCommand,
        holdThresholdMs: Int = 250,
        providerID: UUID? = nil,
        model: String = "whisper-large-v3-turbo",
        insertMode: InsertMode = .autoInsert,
        showOverlay: Bool = false,
        keepAudio: Bool = false,
        streamLive: Bool = false,
        shortTapAction: ShortTapAction = .oneShot,
        language: String = "en"
    ) {
        self.enabled = enabled
        self.trigger = trigger
        self.holdThresholdMs = holdThresholdMs
        self.providerID = providerID
        self.model = model
        self.insertMode = insertMode
        self.showOverlay = showOverlay
        self.keepAudio = keepAudio
        self.streamLive = streamLive
        self.shortTapAction = shortTapAction
        self.language = language
    }

    // Tolerant decode: a pre-M3 persisted blob has neither streaming key.
    // `decodeIfPresent` + defaults keeps old installs loading cleanly.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decode(Bool.self, forKey: .enabled)
        trigger = try c.decode(TriggerModifier.self, forKey: .trigger)
        holdThresholdMs = try c.decode(Int.self, forKey: .holdThresholdMs)
        providerID = try c.decodeIfPresent(UUID.self, forKey: .providerID)
        model = try c.decode(String.self, forKey: .model)
        insertMode = try c.decode(InsertMode.self, forKey: .insertMode)
        showOverlay = try c.decode(Bool.self, forKey: .showOverlay)
        keepAudio = try c.decode(Bool.self, forKey: .keepAudio)
        streamLive = try c.decodeIfPresent(Bool.self, forKey: .streamLive) ?? false
        shortTapAction = try c.decodeIfPresent(ShortTapAction.self, forKey: .shortTapAction) ?? .oneShot
        language = try c.decodeIfPresent(String.self, forKey: .language) ?? "en"
    }

    public static let `default` = DictationSettings()
}
