import Foundation
import Testing
@testable import AudioPipelineJobs

@Suite struct PresetCodable {
    @Test func roundTrip_preservesAllFields() throws {
        let preset = Preset(
            id: "openai-compat-chat",
            displayName: "OpenAI-compatible Chat",
            shape: .chatCompletionsAudio,
            baseURL: "https://example.com",
            suggestedModels: ["gpt-4o-audio-preview"],
            defaults: ["temperature": "0.2"],
            docsURL: "https://docs.example.com"
        )
        let data = try JSONEncoder().encode(preset)
        let decoded = try JSONDecoder().decode(Preset.self, from: data)
        #expect(decoded == preset)
    }

    @Test func docsURL_isOptional() throws {
        let json = #"""
        {"id":"x","displayName":"X","shape":"chatCompletionsAudio",
         "baseURL":"","suggestedModels":[],"defaults":{}}
        """#
        let decoded = try JSONDecoder().decode(Preset.self, from: Data(json.utf8))
        #expect(decoded.docsURL == nil)
    }

    @Test func fieldHelp_isOptional() throws {
        let json = #"""
        {"id":"x","displayName":"X","shape":"chatCompletionsAudio",
         "baseURL":"","suggestedModels":[],"defaults":{}}
        """#
        let decoded = try JSONDecoder().decode(Preset.self, from: Data(json.utf8))
        #expect(decoded.fieldHelp == nil)
    }

    @Test func roundTrip_preservesFieldHelp() throws {
        let preset = Preset(
            id: "p", displayName: "P", shape: .transcriptionMultipart,
            baseURL: "https://example.com", suggestedModels: ["m"],
            defaults: [:], docsURL: nil,
            fieldHelp: ["prompt": "biases spelling, not instructions"]
        )
        let data = try JSONEncoder().encode(preset)
        let decoded = try JSONDecoder().decode(Preset.self, from: data)
        #expect(decoded == preset)
        #expect(decoded.fieldHelp?["prompt"] == "biases spelling, not instructions")
    }
}
