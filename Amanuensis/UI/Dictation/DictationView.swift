import AppSettings
import AudioPipelineJobs
import DictationCore
import LocalTranscription
import SwiftUI

struct DictationView: View {
    @Bindable var settings: AppSettings
    let coordinator: AppCoordinator

    var body: some View {
        Form {
            Section {
                Toggle("Enable dictation", isOn: $settings.dictation.enabled)
                    .onChange(of: settings.dictation.enabled) { _, _ in
                        coordinator.dictation.settingsChanged()
                    }

                Picker("Trigger key", selection: $settings.dictation.trigger) {
                    ForEach(TriggerModifier.allCases, id: \.self) { modifier in
                        Text(modifier.displayName).tag(modifier)
                    }
                }
                .onChange(of: settings.dictation.trigger) { _, _ in
                    coordinator.dictation.settingsChanged()
                }

                Picker("Short tap", selection: $settings.dictation.shortTapAction) {
                    Text("Start / stop one capture").tag(DictationSettings.ShortTapAction.oneShot)
                    Text("Toggle auto-listening").tag(DictationSettings.ShortTapAction.autoListening)
                }
                .onChange(of: settings.dictation.shortTapAction) { _, _ in
                    coordinator.dictation.settingsChanged()
                }
                .help("With auto-listening, a tap of the trigger turns hands-free dictation on or off. Hold still works as push-to-talk.")

                if settings.dictation.shortTapAction == .autoListening {
                    LabeledContent("Pause before typing") {
                        HStack {
                            Slider(value: autoPauseBinding, in: 300...1500, step: 100)
                            Text("\(settings.dictation.autoPauseMs) ms")
                                .monospacedDigit().foregroundStyle(.secondary)
                        }
                    }
                    .onChange(of: settings.dictation.autoPauseMs) { _, _ in
                        coordinator.dictation.autoPauseChanged()
                    }
                    .help("How long a pause ends an utterance and types it. Shorter reacts faster; longer lets you pause mid-thought without it cutting in.")
                }

                if settings.dictation.trigger == .function {
                    Text("Fn may also trigger a macOS action (System Settings ▸ Keyboard ▸ “Press 🌐 to”).")
                        .font(.caption).foregroundStyle(.secondary)
                }

                LabeledContent("Hold threshold") {
                    HStack {
                        Slider(value: holdThresholdBinding, in: 150...600, step: 50)
                        Text("\(settings.dictation.holdThresholdMs) ms")
                            .monospacedDigit().foregroundStyle(.secondary)
                    }
                }
            }

            Section("Transcription") {
                Picker("Provider", selection: $settings.dictation.providerID) {
                    Text("None").tag(UUID?.none)
                    ForEach(coordinator.allProviders) { provider in
                        Text(provider.name).tag(UUID?.some(provider.id))
                    }
                    if !downloadedLocalIDs.isEmpty {
                        Text("Local").tag(UUID?.some(Provider.localID))
                    }
                }
                .onChange(of: settings.dictation.providerID) { _, _ in
                    Task { await coordinator.syncDictationWarmModel() }
                }

                ModelSelector(
                    isLocal: TranscriptionSource(providerID: settings.dictation.providerID) == .local,
                    model: $settings.dictation.model,
                    downloadedLocalModelIDs: downloadedLocalIDs,
                    suggestedModels: dictationSuggestedModels,
                    isBusy: coordinator.localModelsStore.loadingModelID != nil
                        || coordinator.localModelsStore.unloadingModelID != nil)
                .onChange(of: settings.dictation.model) { _, _ in
                    normalizeDictationLanguage()
                    Task { await coordinator.syncDictationWarmModel() }
                }

                if let model = selectedLocalModel, model.supportedLanguages.count > 1 {
                    Picker("Language", selection: $settings.dictation.language) {
                        // Auto-detecting models (no declared default) get an explicit
                        // Auto-detect entry so switching from a disjoint-language model
                        // lands on a valid selection rather than a blank row.
                        if model.defaultLanguage == nil {
                            Text("Auto-detect").tag("")
                        }
                        ForEach(model.supportedLanguages, id: \.self) { code in
                            Text(Self.languageLabel(code)).tag(code)
                        }
                    }
                }
            }

            Section {
                Picker("On finish", selection: $settings.dictation.insertMode) {
                    Text("Insert at cursor").tag(InsertMode.autoInsert)
                    Text("Copy to clipboard").tag(InsertMode.clipboardOnly)
                }
                Toggle("Show overlay while dictating", isOn: $settings.dictation.showOverlay)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Dictation")
        .onAppear(perform: normalizeDictationLanguage)
    }

    /// Snap the dictation language to one the selected local model can handle:
    /// keep a supported explicit choice, otherwise fall to the model's declared
    /// default (Hindi for IndicConformer, …) or "" (auto-detect) for broad models.
    /// Runs on appear (fixes stale persisted state) and on model change. No-op for
    /// cloud dictation, whose language lives in the provider's own fields.
    private func normalizeDictationLanguage() {
        guard TranscriptionSource(providerID: settings.dictation.providerID) == .local,
              LocalModelCatalog.model(id: settings.dictation.model) != nil else { return }
        settings.dictation.language = LocalModelCatalog.pickerLanguage(
            forModel: settings.dictation.model, current: settings.dictation.language)
    }

    private var downloadedLocalIDs: [String] {
        guard LocalModelSupport.isSupported else { return [] }
        return LocalModelCatalog.all.map(\.id).filter { coordinator.localModelsStore.states[$0]?.isDownloaded == true }
    }

    /// The selected local dictation model, or nil for cloud dictation (whose
    /// language lives in the provider's own fields, not this picker).
    private var selectedLocalModel: LocalModel? {
        guard TranscriptionSource(providerID: settings.dictation.providerID) == .local else { return nil }
        return LocalModelCatalog.model(id: settings.dictation.model)
    }

    private static func languageLabel(_ code: String) -> String {
        Locale.current.localizedString(forLanguageCode: code)?.capitalized ?? code.uppercased()
    }

    private var dictationSuggestedModels: [String] {
        guard case .provider(let id) = TranscriptionSource(providerID: settings.dictation.providerID),
              let provider = coordinator.allProviders.first(where: { $0.id == id }),
              let preset = coordinator.presets.preset(id: provider.presetID) else { return [] }
        return preset.suggestedModels
    }

    private var holdThresholdBinding: Binding<Double> {
        Binding(
            get: { Double(settings.dictation.holdThresholdMs) },
            set: { settings.dictation.holdThresholdMs = Int($0) })
    }

    private var autoPauseBinding: Binding<Double> {
        Binding(
            get: { Double(settings.dictation.autoPauseMs) },
            set: { settings.dictation.autoPauseMs = Int($0) })
    }
}
