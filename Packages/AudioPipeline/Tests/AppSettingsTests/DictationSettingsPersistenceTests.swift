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

@Test func shortTapActionDefaultsToOneShot() {
    #expect(DictationSettings().shortTapAction == .oneShot)
}

@Test func shortTapActionRoundTrips() throws {
    var s = DictationSettings()
    s.shortTapAction = .autoListening
    let data = try JSONEncoder().encode(s)
    let decoded = try JSONDecoder().decode(DictationSettings.self, from: data)
    #expect(decoded.shortTapAction == .autoListening)
}

@Test func shortTapActionAbsentDecodesToOneShot() throws {
    // A pre-auto-dictation blob has no shortTapAction key.
    let json = """
    {"enabled":false,"trigger":"rightCommand","holdThresholdMs":250,
     "model":"whisper-large-v3-turbo","insertMode":"autoInsert",
     "showOverlay":false,"keepAudio":false,"streamLive":false,"language":"en"}
    """
    let decoded = try JSONDecoder().decode(DictationSettings.self, from: Data(json.utf8))
    #expect(decoded.shortTapAction == .oneShot)
}
