import AppKit
import AudioPipelineJobs
import SwiftUI

struct ProviderEditorView: View {
    @State private var name: String
    @State private var presetID: String
    @State private var baseURL: String
    @State private var apiKeyAccount: String

    private let initialID: UUID
    private let presets: PresetsStore
    private let keychain: KeychainStore
    private let onSave: (Provider) -> Void

    init(initial: Provider, presets: PresetsStore, keychain: KeychainStore,
         onSave: @escaping (Provider) -> Void) {
        self.presets = presets
        self.keychain = keychain
        self.onSave = onSave

        self.initialID = initial.id
        _name = State(initialValue: initial.name)
        _presetID = State(initialValue: initial.presetID)
        _baseURL = State(initialValue: initial.baseURL)
        _apiKeyAccount = State(initialValue: initial.apiKeyRef.account)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
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
                    }
                    TextField("Base URL", text: $baseURL)
                    KeychainAccountPicker(account: $apiKeyAccount, keychain: keychain)
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
        !name.isEmpty && !presetID.isEmpty && !apiKeyAccount.isEmpty
    }

    private func save() {
        let provider = Provider(id: initialID, name: name, presetID: presetID,
                                baseURL: baseURL,
                                apiKeyRef: KeychainRef(account: apiKeyAccount))
        onSave(provider)
    }
}
