import Foundation

/// All persisted dictation preferences. Stored by `AppSettings` as one JSON
/// blob (see Task 6).
public struct DictationSettings: Codable, Equatable, Sendable {
    public var enabled: Bool
    public var trigger: TriggerModifier
    public var holdThresholdMs: Int
    public var providerID: UUID?
    public var model: String
    public var insertMode: InsertMode
    public var showOverlay: Bool
    public var keepAudio: Bool

    public init(
        enabled: Bool = false,
        trigger: TriggerModifier = .rightCommand,
        holdThresholdMs: Int = 250,
        providerID: UUID? = nil,
        model: String = "whisper-large-v3-turbo",
        insertMode: InsertMode = .autoInsert,
        showOverlay: Bool = false,
        keepAudio: Bool = false
    ) {
        self.enabled = enabled
        self.trigger = trigger
        self.holdThresholdMs = holdThresholdMs
        self.providerID = providerID
        self.model = model
        self.insertMode = insertMode
        self.showOverlay = showOverlay
        self.keepAudio = keepAudio
    }

    public static let `default` = DictationSettings()
}
