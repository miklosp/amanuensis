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
    }

    private var provider: Provider? {
        providerID.flatMap { providers.provider(id: $0) }
    }

    private var preset: Preset? {
        provider.flatMap { presets.preset(id: $0.presetID) }
    }

    private var shape: JobShape? { preset?.shape }

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
                let newPreset = newID
                    .flatMap { providers.provider(id: $0) }
                    .flatMap { presets.preset(id: $0.presetID) }
                model = ""
                fields = newPreset?.defaults ?? [:]
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
                        let newShape = newID
                            .flatMap { providers.provider(id: $0) }
                            .flatMap { presets.preset(id: $0.presetID) }?.shape
                        if oldShape != newShape {
                            model = ""
                            let newDefaults = newID
                                .flatMap { providers.provider(id: $0) }
                                .flatMap { presets.preset(id: $0.presetID) }?.defaults ?? [:]
                            fields = newDefaults
                        }
                    }
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
                    TextField("Output extension", text: $outputExt)
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

                if let shape {
                    Section("Parameters") {
                        JobFieldFormView(shape: shape, values: $fields)
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
        return !name.isEmpty && providerID != nil && !model.isEmpty && folderOK
    }

    private func save() {
        let job = Job(
            id: initialID, name: name, providerID: providerID,
            model: model, fields: fields, outputExt: outputExt,
            outputFolderPath: customOutputFolder && !outputFolderPath.isEmpty
                ? outputFolderPath : nil
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
        }
    }
}
