import Foundation
import Testing
@testable import DictationCore

private struct Expectation {
    let modifier: TriggerModifier
    let keyCode: Int64
    let deviceFlagBit: UInt64
    let displayName: String
}

private let expectations: [Expectation] = [
    .init(modifier: .leftControl,  keyCode: 59, deviceFlagBit: 0x0000_0001, displayName: "Left ⌃"),
    .init(modifier: .leftShift,    keyCode: 56, deviceFlagBit: 0x0000_0002, displayName: "Left ⇧"),
    .init(modifier: .rightShift,   keyCode: 60, deviceFlagBit: 0x0000_0004, displayName: "Right ⇧"),
    .init(modifier: .leftOption,   keyCode: 58, deviceFlagBit: 0x0000_0020, displayName: "Left ⌥"),
    .init(modifier: .rightOption,  keyCode: 61, deviceFlagBit: 0x0000_0040, displayName: "Right ⌥"),
    .init(modifier: .leftCommand,  keyCode: 55, deviceFlagBit: 0x0000_0008, displayName: "Left ⌘"),
    .init(modifier: .rightCommand, keyCode: 54, deviceFlagBit: 0x0000_0010, displayName: "Right ⌘"),
    .init(modifier: .function,     keyCode: 63, deviceFlagBit: 0x0080_0000, displayName: "Fn 🌐"),
]

@Test func everyModifierHasCorrectMetadata() {
    for e in expectations {
        #expect(e.modifier.keyCode == e.keyCode, "\(e.modifier) keyCode")
        #expect(e.modifier.deviceFlagBit == e.deviceFlagBit, "\(e.modifier) deviceFlagBit")
        #expect(e.modifier.displayName == e.displayName, "\(e.modifier) displayName")
    }
}

@Test func coversEveryStandardModifier() {
    // Eight momentary modifiers: Right Control (absent on Apple keyboards) and
    // Caps Lock (no hold-to-talk under the sandbox tap) are intentionally omitted.
    #expect(TriggerModifier.allCases.count == 8)
    #expect(Set(expectations.map(\.modifier)) == Set(TriggerModifier.allCases))
}

@Test func commandRawValuesPreservedSoStoredSettingsDecodeUnchanged() throws {
    // DictationSettings persists the trigger by case name. These two raw values
    // existed under the old `TriggerSide` type and must not change, or settings
    // saved before the rename fail to decode.
    #expect(TriggerModifier(rawValue: "leftCommand") == .leftCommand)
    #expect(TriggerModifier(rawValue: "rightCommand") == .rightCommand)

    let data = try JSONEncoder().encode(TriggerModifier.rightCommand)
    #expect(String(decoding: data, as: UTF8.self) == "\"rightCommand\"")
    #expect(try JSONDecoder().decode(TriggerModifier.self, from: data) == .rightCommand)
}
