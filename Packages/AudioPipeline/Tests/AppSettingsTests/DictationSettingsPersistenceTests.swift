import Testing
import Foundation
import DictationCore
@testable import AppSettings

@Test func dictationDefaultsWhenAbsent() {
    let defaults = UserDefaults(suiteName: "dictation-test-\(UUID().uuidString)")!
    let settings = AppSettings(defaults: defaults)
    #expect(settings.dictation == .default)
}

@Test func dictationRoundTripsThroughDefaults() {
    let suite = "dictation-test-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    let settings = AppSettings(defaults: defaults)
    var d = DictationSettings.default
    d.enabled = true
    d.model = "whisper-large-v3"
    settings.dictation = d

    let reloaded = AppSettings(defaults: defaults)
    #expect(reloaded.dictation.enabled == true)
    #expect(reloaded.dictation.model == "whisper-large-v3")
}
