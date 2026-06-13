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
        #expect(ids.contains("openai-gpt4o-transcribe"))
        #expect(store.all.count == 12)
    }

    @Test func lookupByID_sonioxAsync_returnsPreset() throws {
        let store = try PresetsStore.loadBundled()
        let preset = store.preset(id: "soniox-async")
        #expect(preset?.shape == .sonioxAsync)
        #expect(preset?.suggestedModels.contains("stt-async-v5") == true)
        #expect(preset?.defaults["enable_speaker_diarization"] == "true")
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

    @Test func everyPromptOrContextField_hasTooltip() throws {
        let store = try PresetsStore.loadBundled()
        let constraintKeys: Set<String> = ["prompt", "context"]
        for preset in store.all {
            for field in preset.shape.fields where constraintKeys.contains(field.key) {
                #expect(preset.fieldHelp?[field.key]?.isEmpty == false,
                        "preset '\(preset.id)' field '\(field.key)' has no tooltip text")
            }
        }
    }

    @Test func openaiWhisper_isWhisperOnly() throws {
        let store = try PresetsStore.loadBundled()
        #expect(store.preset(id: "openai-whisper")?.suggestedModels == ["whisper-1"])
    }

    @Test func gpt4oTranscribe_presetExists() throws {
        let store = try PresetsStore.loadBundled()
        let p = store.preset(id: "openai-gpt4o-transcribe")
        #expect(p?.shape == .transcriptionMultipart)
        #expect(p?.suggestedModels.contains("gpt-4o-transcribe") == true)
        #expect(p?.suggestedModels.contains("gpt-4o-mini-transcribe") == true)
    }
}
