import AudioPipelineJobs
import SwiftUI

struct JobEditorView: View {
    @Environment(\.dismiss) private var dismiss

    @State private var name: String
    @State private var presetID: String
    @State private var baseURL: String
    @State private var model: String
    @State private var apiKeyAccount: String
    @State private var fields: [String: String]
    @State private var outputExt: String

    private let initialID: UUID
    private let presets: PresetsStore
    private let keychain: KeychainStore
    private let onSave: (Job) -> Void

    init(initial: Job?, presets: PresetsStore, keychain: KeychainStore,
         onSave: @escaping (Job) -> Void) {
        self.presets = presets
        self.keychain = keychain
        self.onSave = onSave

        let firstPreset = presets.all.first
        let starting = initial ?? Job(
            name: "Untitled",
            presetID: firstPreset?.id ?? "",
            baseURL: firstPreset?.baseURL ?? "",
            model: firstPreset?.suggestedModels.first ?? "",
            apiKeyRef: KeychainRef(account: ""),
            fields: firstPreset?.defaults ?? [:],
            outputExt: "txt"
        )
        self.initialID = starting.id
        _name = State(initialValue: starting.name)
        _presetID = State(initialValue: starting.presetID)
        _baseURL = State(initialValue: starting.baseURL)
        _model = State(initialValue: starting.model)
        _apiKeyAccount = State(initialValue: starting.apiKeyRef.account)
        _fields = State(initialValue: starting.fields)
        _outputExt = State(initialValue: starting.outputExt)
    }

    private var preset: Preset? { presets.preset(id: presetID) }
    private var shape: JobShape? { preset?.shape }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Job").font(.title2).padding([.top, .horizontal])

            Form {
                Section("General") {
                    TextField("Name", text: $name)
                    Picker("Preset", selection: $presetID) {
                        ForEach(presets.all) { p in
                            Text(p.displayName).tag(p.id)
                        }
                    }
                    .onChange(of: presetID) { _, newID in
                        guard let p = presets.preset(id: newID) else { return }
                        baseURL = p.baseURL
                        if model.isEmpty { model = p.suggestedModels.first ?? "" }
                        for (k, v) in p.defaults where fields[k] == nil { fields[k] = v }
                    }
                    TextField("Base URL", text: $baseURL)
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
                    KeychainAccountPicker(account: $apiKeyAccount, keychain: keychain)
                    TextField("Output extension", text: $outputExt)
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
                Button("Cancel") { dismiss() }
                Button("Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSave)
            }
            .padding(12)
        }
        .frame(width: 540, height: 560)
    }

    private var canSave: Bool {
        !name.isEmpty && !presetID.isEmpty && !apiKeyAccount.isEmpty && !model.isEmpty
    }

    private func save() {
        let job = Job(id: initialID, name: name, presetID: presetID,
                      baseURL: baseURL, model: model,
                      apiKeyRef: KeychainRef(account: apiKeyAccount),
                      fields: fields, outputExt: outputExt)
        onSave(job)
        dismiss()
    }
}
