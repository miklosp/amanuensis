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
