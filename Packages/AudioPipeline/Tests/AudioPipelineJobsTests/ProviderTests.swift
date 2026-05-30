import Foundation
import Testing
@testable import AudioPipelineJobs

@Suite struct ProviderCodable {
    @Test func roundTrip_preservesAllFields() throws {
        let id = UUID()
        let provider = Provider(
            id: id,
            name: "OpenAI (chat audio)",
            presetID: "openai-chat-audio",
            baseURL: "https://api.openai.com",
            apiKeyRef: KeychainRef(account: "openai-personal")
        )
        let data = try JSONEncoder().encode(provider)
        let decoded = try JSONDecoder().decode(Provider.self, from: data)
        #expect(decoded == provider)
    }

    @Test func id_isStable_acrossEdits() {
        let id = UUID()
        var p = Provider(id: id, name: "a", presetID: "x",
                         baseURL: "", apiKeyRef: KeychainRef(account: ""))
        p.name = "b"
        #expect(p.id == id)
    }
}

@Suite struct ProviderMakeDraft {
    @Test func usesFirstPresetWhenAvailable() {
        let preset = Preset(
            id: "openai-compat-chat",
            displayName: "OpenAI Compatible",
            shape: .chatCompletionsAudio,
            baseURL: "https://api.example/v1",
            suggestedModels: ["gpt-4o-audio"],
            defaults: [:]
        )
        let presets = PresetsStore(presets: [preset])

        let draft = Provider.makeDraft(presets: presets)

        #expect(draft.name == "Untitled provider")
        #expect(draft.presetID == "openai-compat-chat")
        #expect(draft.baseURL == "https://api.example/v1")
        #expect(draft.apiKeyRef.account == "")
    }

    @Test func fallsBackToEmptyDefaultsWhenNoPresets() {
        let presets = PresetsStore(presets: [])

        let draft = Provider.makeDraft(presets: presets)

        #expect(draft.name == "Untitled provider")
        #expect(draft.presetID == "")
        #expect(draft.baseURL == "")
        #expect(draft.apiKeyRef.account == "")
    }

    @Test func assignsDistinctIDsPerCall() {
        let presets = PresetsStore(presets: [])
        let a = Provider.makeDraft(presets: presets)
        let b = Provider.makeDraft(presets: presets)
        #expect(a.id != b.id)
    }
}
