import Foundation
import Testing
@testable import DictationCore

@Test func defaultsAreConservative() {
    let d = DictationSettings.default
    #expect(d.enabled == false)
    #expect(d.trigger == .rightCommand)
    #expect(d.holdThresholdMs == 250)
    #expect(d.providerID == nil)
    #expect(d.model == "whisper-large-v3-turbo")
    #expect(d.insertMode == .autoInsert)
    #expect(d.showOverlay == false)
    #expect(d.keepAudio == false)
}

@Test func roundTripsThroughJSON() throws {
    var d = DictationSettings.default
    d.enabled = true
    d.trigger = .leftCommand
    let data = try JSONEncoder().encode(d)
    #expect(try JSONDecoder().decode(DictationSettings.self, from: data) == d)
}

@Test func defaultsAreBatchEnglish() {
    let s = DictationSettings.default
    #expect(s.streamLive == false)
    #expect(s.language == "en")
}

@Test func codableRoundTripPreservesStreamingFields() throws {
    var s = DictationSettings.default
    s.streamLive = true
    s.language = "de"
    let data = try JSONEncoder().encode(s)
    let back = try JSONDecoder().decode(DictationSettings.self, from: data)
    #expect(back.streamLive == true)
    #expect(back.language == "de")
}

@Test func decodesLegacyBlobWithoutStreamingFields() throws {
    // A pre-M3 persisted blob has neither key; decoding must not fail.
    let legacy = #"{"enabled":false,"trigger":"rightCommand","holdThresholdMs":250,"model":"whisper-large-v3-turbo","insertMode":"autoInsert","showOverlay":false,"keepAudio":false}"#
    let s = try JSONDecoder().decode(DictationSettings.self, from: Data(legacy.utf8))
    #expect(s.streamLive == false)
    #expect(s.language == "en")
}
