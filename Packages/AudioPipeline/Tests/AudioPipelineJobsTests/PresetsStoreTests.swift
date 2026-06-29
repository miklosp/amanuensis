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
        #expect(ids.contains("deepgram"))
        #expect(ids.contains("gemini-openai"))
        #expect(store.all.count == 14)
    }

    @Test func cohere_usesCohereTranscribeShape_andDropsPromptOverrides() throws {
        let store = try PresetsStore.loadBundled()
        let p = store.preset(id: "cohere")
        #expect(p?.shape == .cohereTranscribe)
        #expect(p?.fieldLabels?["prompt"] == nil)
        #expect(p?.suggestedModels == ["cohere-transcribe-03-2026"])
    }

    @Test func geminiOpenAI_defaultsReasoningEffortLow() throws {
        let store = try PresetsStore.loadBundled()
        let p = store.preset(id: "gemini-openai")
        #expect(p?.shape == .chatCompletionsAudio)
        #expect(p?.defaults["reasoning_effort"] == "low")
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

    @Test func all_isSortedByDisplayName() throws {
        let store = try PresetsStore.loadBundled()
        let names = store.all.map(\.displayName)
        #expect(names == names.sorted { $0.localizedStandardCompare($1) == .orderedAscending })
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
        let constraintKeys: Set<String> = ["prompt", "context", "keyterm"]
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

    @Test func everyPreset_hasValidOutputExtDefault() throws {
        let store = try PresetsStore.loadBundled()
        let allowed: Set<String> = ["json", "md", "txt"]
        for p in store.all {
            #expect(p.defaultOutputExt != nil && allowed.contains(p.defaultOutputExt ?? ""),
                    "preset '\(p.id)' has invalid defaultOutputExt: \(p.defaultOutputExt ?? "nil")")
        }
    }

    @Test func outputExtDefaults_matchProviderType() throws {
        let store = try PresetsStore.loadBundled()
        #expect(store.preset(id: "deepgram")?.defaultOutputExt == "json")
        #expect(store.preset(id: "gemini")?.defaultOutputExt == "md")
        #expect(store.preset(id: "openai-chat-audio")?.defaultOutputExt == "md")
        #expect(store.preset(id: "openai-whisper")?.defaultOutputExt == "txt")
    }

    @Test func transcriptionPresets_overrideLabelAndHint_forPrompt() throws {
        let store = try PresetsStore.loadBundled()
        #expect(store.preset(id: "openai-gpt4o-transcribe")?.fieldLabels?["prompt"]?.isEmpty == false)
        #expect(store.preset(id: "openai-gpt4o-transcribe")?.fieldHints?["prompt"]?.isEmpty == false)
        #expect(store.preset(id: "mistral-voxtral")?.fieldHints?["prompt"]?.isEmpty == false)
    }

    @Test func deepgram_presetExists() throws {
        let store = try PresetsStore.loadBundled()
        let p = store.preset(id: "deepgram")
        #expect(p?.shape == .deepgramListen)
        #expect(p?.suggestedModels.contains("nova-3") == true)
        #expect(p?.fieldHelp?["keyterm"]?.isEmpty == false)
    }
}
