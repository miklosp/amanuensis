import Foundation
import Testing
@testable import DictationCore

@Test func keyCodesMatchMacOSVirtualKeys() {
    #expect(TriggerSide.leftCommand.keyCode == 55)   // kVK_Command, 0x37
    #expect(TriggerSide.rightCommand.keyCode == 54)  // kVK_RightCommand, 0x36
}

@Test func triggerSideRoundTripsCodable() throws {
    let data = try JSONEncoder().encode(TriggerSide.rightCommand)
    #expect(try JSONDecoder().decode(TriggerSide.self, from: data) == .rightCommand)
}
