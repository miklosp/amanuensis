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
                    applyModelDefaultLanguage()
                    Task { await coordinator.syncDictationWarmModel() }
                }

                if let languages = localDictationLanguages, languages.count > 1 {
                    Picker("Language", selection: $settings.dictation.language) {
                        ForEach(languages, id: \.self) { code in
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
        .onAppear(perform: reconcileDictationLanguage)
    }

    /// On model change: apply the newly-selected local model's declared default
    /// language (Hindi for IndicConformer, ja for the Japanese model, zh for
    /// SenseVoice). No-op for auto-detect and cloud models, which keep the current
    /// language.
    private func applyModelDefaultLanguage() {
        if let def = LocalModelCatalog.model(id: settings.dictation.model)?.defaultLanguage {
            settings.dictation.language = def
        }
    }

    /// On appear: only fix a language the selected local model can't handle (a
    /// stale/blank value), preserving a valid explicit choice. No-op for cloud
    /// models and already-supported languages.
    private func reconcileDictationLanguage() {
        if let lang = LocalModelCatalog.defaultLanguage(
            forModel: settings.dictation.model, current: settings.dictation.language) {
            settings.dictation.language = lang
        }
    }

    private var downloadedLocalIDs: [String] {
        LocalModelCatalog.all.map(\.id).filter { coordinator.localModelsStore.states[$0]?.isDownloaded == true }
    }

    /// Supported language codes of the selected local dictation model, or nil for
    /// cloud dictation (whose language lives in the provider's own fields).
    private var localDictationLanguages: [String]? {
        guard TranscriptionSource(providerID: settings.dictation.providerID) == .local else { return nil }
        return LocalModelCatalog.model(id: settings.dictation.model)?.supportedLanguages
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
}
