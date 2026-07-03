import Foundation

/// Single source of truth for "which providers can stream." A non-nil result
/// both selects the adapter and gates the "Stream results live" toggle.
public enum RealtimeProviderRegistry {
    public static func provider(for presetID: String) -> RealtimeSTTProvider? {
        switch presetID {
        case "reson8": return Reson8RealtimeProvider()
        // "soniox" added in Task 11.
        default: return nil
        }
    }
}
