import AppKit
import AudioPipelineJobs
import SwiftUI

struct JobEditorView: View {
    @State private var name: String
    @State private var providerID: UUID?
    @State private var model: String
    @State private var fields: [String: String]
    @State private var outputExt: String
    @State private var customOutputFolder: Bool
    @State private var outputFolderPath: String
    // Security-scoped bookmark minted when the user picks a folder, so the job
    // can write there after relaunch. Preserved from the saved job when editing
    // without re-picking; reset whenever the path changes or custom folder is off.
    @State private var outputFolderBookmark: Data?

    private let initialID: UUID
    private let presets: PresetsStore
    private let providers: ProvidersStore
    private let onSave: (Job) -> Void

    init(initial: Job, presets: PresetsStore, providers: ProvidersStore,
         onSave: @escaping (Job) -> Void) {
        self.presets = presets
        self.providers = providers
        self.onSave = onSave

        self.initialID = initial.id
        _name = State(initialValue: initial.name)
        _providerID = State(initialValue: initial.providerID)
        _model = State(initialValue: initial.model)
        _fields = State(initialValue: initial.fields)
        _outputExt = State(initialValue: initial.outputExt)
        let startingFolder = initial.outputFolderPath ?? ""
        _customOutputFolder = State(initialValue: !startingFolder.isEmpty)
        _outputFolderPath = State(initialValue: startingFolder)
        _outputFolderBookmark = State(initialValue: initial.outputFolderBookmark)
    }

    private var provider: Provider? {
        providerID.flatMap { providers.provider(id: $0) }
    }

    private var preset: Preset? {
        provider.flatMap { presets.preset(id: $0.presetID) }
    }

    var body: some View {
        if providerID == nil || provider == nil {
            repairPane
        } else {
            editorForm
        }
    }

    @ViewBuilder
    private var repairPane: some View {
        VStack(spacing: 16) {
            ContentUnavailableView {
                Label("Provider missing", systemImage: "key.slash")
            } description: {
                Text("Pick a provider to repair this job. Switching shapes resets prompt/parameters.")
            }
            Picker("Provider", selection: $providerID) {
                Text("Select…").tag(UUID?.none)
                ForEach(providers.providers.sorted(by: { $0.name.localizedStandardCompare($1.name) == .orderedAscending })) { p in
                    Text(p.name).tag(Optional(p.id))
                }
            }
            .onChange(of: providerID) { _, newID in
                // Always reset — the old provider is gone, so there's no shape
                // to preserve. Differs from editorForm's onChange below.
                let newPreset = newID
                    .flatMap { providers.provider(id: $0) }
                    .flatMap { presets.preset(id: $0.presetID) }
                model = Self.autoFilledModel(newPreset)
                fields = newPreset?.defaults ?? [:]
                outputExt = newPreset?.defaultOutputExt ?? "txt"
            }
            .frame(maxWidth: 360)
            Button("Save repair") { save() }
                .keyboardShortcut(.defaultAction)
                .disabled(!canSave)
                .buttonStyle(.glassProminent)
        }
        .padding(24)
    }

    @ViewBuilder
    private var editorForm: some View {
        VStack(alignment: .leading, spacing: 0) {
            Form {
                Section("General") {
                    TextField("Name", text: $name)
                    Picker("Provider", selection: $providerID) {
                        Text("Select…").tag(UUID?.none)
                        ForEach(providers.providers.sorted(by: { $0.name.localizedStandardCompare($1.name) == .orderedAscending })) { p in
                            Text(p.name).tag(Optional(p.id))
                        }
                    }
                    .onChange(of: providerID) { oldID, newID in
                        let oldShape = oldID
                            .flatMap { providers.provider(id: $0) }
                            .flatMap { presets.preset(id: $0.presetID) }?.shape
                        let newPreset = newID
                            .flatMap { providers.provider(id: $0) }
                            .flatMap { presets.preset(id: $0.presetID) }
                        if oldShape != newPreset?.shape {
                            model = Self.autoFilledModel(newPreset)
                            fields = newPreset?.defaults ?? [:]
                            outputExt = newPreset?.defaultOutputExt ?? "txt"
                        }
                    }
                    if preset?.shape.requiresModel ?? true {
                        HStack {
                            TextField("Model", text: $model)
                            if let suggestions = preset?.suggestedModels, !suggestions.isEmpty {
                                Menu("Suggested") {
                                    ForEach(suggestions, id: \.self) { s in
                                        Button(s) { model = s }
                                    }
                                }
                                .frame(width: 110)
                            }
                        }
                    }
                    Picker("Output extension", selection: $outputExt) {
                        ForEach(outputExtOptions, id: \.self) { Text($0).tag($0) }
                    }
                    Toggle(isOn: $customOutputFolder) {
                        Text("Custom output folder")
                    }
                    if customOutputFolder {
                        HStack {
                            Text(outputFolderPath.isEmpty ? "—" : outputFolderPath)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Button("Choose…", action: chooseOutputFolder)
                        }
                    }
                }

                if let preset {
                    Section("Parameters") {
                        JobFieldFormView(preset: preset, values: $fields)
                    }
                }
            }
            .formStyle(.grouped)

            Divider()
            HStack {
                Spacer()
                Button("Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSave)
                    .buttonStyle(.glassProminent)
            }
            .padding(12)
        }
    }

    private var canSave: Bool {
        let folderOK = !customOutputFolder || !outputFolderPath.isEmpty
        // provider != nil (not just providerID != nil) — guards against the
        // repair-pane case where providerID still holds the dangling UUID of
        // a deleted Provider and the user hits Save without touching the Picker.
        let modelOK = !(preset?.shape.requiresModel ?? true) || !model.isEmpty
        // Required shape fields (e.g. Cohere's language) must be non-empty —
        // FieldSpec.required is otherwise only a label, so without this the
        // provider could dispatch a request the API rejects.
        let requiredFieldsOK = preset?.shape.fields
            .filter(\.required)
            .allSatisfy { !(fields[$0.key] ?? "").trimmingCharacters(in: .whitespaces).isEmpty }
            ?? true
        return !name.isEmpty && provider != nil && modelOK && folderOK && requiredFieldsOK
    }

    // A preset that suggests exactly one model pre-fills it; otherwise the user
    // picks from the Suggested menu or types one, so leave it empty.
    private static func autoFilledModel(_ preset: Preset?) -> String {
        guard let models = preset?.suggestedModels, models.count == 1 else { return "" }
        return models[0]
    }

    // The dropdown offers json/md/txt; keep any existing out-of-list value (e.g.
    // a legacy "srt") so editing an older job doesn't silently change its output.
    private var outputExtOptions: [String] {
        let base = ["json", "md", "txt"]
        if !outputExt.isEmpty && !base.contains(outputExt) { return base + [outputExt] }
        return base
    }

    private func save() {
        let useCustom = customOutputFolder && !outputFolderPath.isEmpty
        let job = Job(
            name: name, providerID: providerID,
            model: model, fields: fields, outputExt: outputExt,
            outputFolderPath: useCustom ? outputFolderPath : nil,
            outputFolderBookmark: useCustom ? outputFolderBookmark : nil,
            id: initialID
        )
        onSave(job)
    }

    private func chooseOutputFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        if let url = URL(string: outputFolderPath), FileManager.default.fileExists(atPath: url.path) {
            panel.directoryURL = url
        }
        if panel.runModal() == .OK, let url = panel.url {
            outputFolderPath = url.path
            // Mint a security-scoped bookmark now (the panel grants access), so
            // the job can still write here after a relaunch. Folders under
            // ~/Music don't need it; storing one anyway is harmless (the run
            // path ignores it where no scope is required).
            outputFolderBookmark = try? url.bookmarkData(
                options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil
            )
        }
    }
}
