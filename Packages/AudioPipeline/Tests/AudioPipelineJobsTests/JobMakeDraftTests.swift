import Foundation
import Testing
@testable import AudioPipelineJobs

@Suite struct JobMakeDraft {
    @Test func usesFirstPresetWhenAvailable() {
        let preset = Preset(
            id: "openai-compat-chat",
            displayName: "OpenAI Compatible",
            shape: .chatCompletionsAudio,
            baseURL: "https://api.example/v1",
            suggestedModels: ["gpt-4o-audio", "gemini-flash"],
            defaults: ["temperature": "0.2", "prompt": "Transcribe"]
        )
        let presets = PresetsStore(presets: [preset])

        let draft = Job.makeDraft(presets: presets)

        #expect(draft.name == "Untitled")
        #expect(draft.presetID == "openai-compat-chat")
        #expect(draft.baseURL == "https://api.example/v1")
        #expect(draft.model == "gpt-4o-audio")
        #expect(draft.fields == ["temperature": "0.2", "prompt": "Transcribe"])
        #expect(draft.outputExt == "txt")
        #expect(draft.apiKeyRef.account == "")
        #expect(draft.outputFolderPath == nil)
    }

    @Test func fallsBackToEmptyDefaultsWhenNoPresets() {
        let presets = PresetsStore(presets: [])

        let draft = Job.makeDraft(presets: presets)

        #expect(draft.name == "Untitled")
        #expect(draft.presetID == "")
        #expect(draft.baseURL == "")
        #expect(draft.model == "")
        #expect(draft.fields == [:])
        #expect(draft.outputExt == "txt")
        #expect(draft.apiKeyRef.account == "")
    }

    @Test func assignsDistinctIDsPerCall() {
        let presets = PresetsStore(presets: [])
        let a = Job.makeDraft(presets: presets)
        let b = Job.makeDraft(presets: presets)
        #expect(a.id != b.id)
    }
}
