import Foundation
import Testing
@testable import AudioPipelineJobs

@Suite struct PresetsStoreBehavior {
    @Test func loadsAllBundledPresets() throws {
        let store = try PresetsStore.loadBundled()
        let ids = Set(store.all.map(\.id))
        #expect(ids.contains("openai-compat-chat"))
        #expect(ids.contains("mistral-voxtral"))
        #expect(ids.contains("cohere"))
        #expect(ids.contains("gemini"))
        #expect(ids.contains("openrouter"))
        #expect(store.all.count == 10)
    }

    @Test func lookupByID_returnsPreset() throws {
        let store = try PresetsStore.loadBundled()
        let preset = store.preset(id: "mistral-voxtral")
        #expect(preset?.shape == .transcriptionMultipart)
        #expect(preset?.suggestedModels.contains("voxtral-mini-2602") == true)
    }

    @Test func lookupByID_missing_returnsNil() throws {
        let store = try PresetsStore.loadBundled()
        #expect(store.preset(id: "does-not-exist") == nil)
    }

    @Test func openrouter_isChatShape() throws {
        let store = try PresetsStore.loadBundled()
        let p = store.preset(id: "openrouter")
        #expect(p?.shape == .chatCompletionsAudio)
    }
}
