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
                    reconcileDictationLanguage()
                    Task { await coordinator.syncDictationWarmModel() }
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
        .onAppear(perform: reconcileDictationLanguage)
    }

    /// Keep the dictation language valid for the selected local model. When a
    /// model that doesn't support the current language is chosen (e.g. selecting
    /// IndicConformer while the language is still "en"), snap to the model's
    /// default supported language — Hindi for IndicConformer. No-op for cloud
    /// models and for languages the model already supports.
    private func reconcileDictationLanguage() {
        if let lang = LocalModelCatalog.defaultLanguage(
            forModel: settings.dictation.model, current: settings.dictation.language) {
            settings.dictation.language = lang
        }
    }

    private var downloadedLocalIDs: [String] {
        LocalModelCatalog.all.map(\.id).filter { coordinator.localModelsStore.states[$0]?.isDownloaded == true }
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
}
