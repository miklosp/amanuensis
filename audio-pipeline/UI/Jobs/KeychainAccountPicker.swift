import AudioPipelineJobs
import SwiftUI

struct KeychainAccountPicker: View {
    @Binding var account: String
    let keychain: KeychainStore

    @State private var accounts: [String] = []
    @State private var creating = false
    @State private var newAccount = ""
    @State private var newKey = ""
    @State private var loadError: String?

    var body: some View {
        HStack {
            Picker("API key", selection: $account) {
                Text("Select…").tag("")
                ForEach(accounts, id: \.self) { Text($0).tag($0) }
            }
            Button("New…") { creating = true }
        }
        .task { await refresh() }
        .sheet(isPresented: $creating) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Add API key").font(.title3)
                TextField("Label (e.g. openai-personal)", text: $newAccount)
                SecureField("Secret", text: $newKey)
                HStack {
                    Spacer()
                    Button("Cancel") { creating = false; newAccount = ""; newKey = "" }
                    Button("Save") {
                        Task { await save() }
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(newAccount.isEmpty || newKey.isEmpty)
                }
            }
            .padding(16)
            .frame(width: 360)
        }
        .alert("Keychain error", isPresented: Binding(get: { loadError != nil },
                                                       set: { _ in loadError = nil })) {
            Button("OK") { loadError = nil }
        } message: {
            Text(loadError ?? "")
        }
    }

    private func refresh() async {
        do {
            accounts = try await keychain.list().sorted()
        } catch {
            loadError = String(describing: error)
        }
    }

    private func save() async {
        do {
            try await keychain.set(account: newAccount, key: newKey)
            let saved = newAccount
            creating = false
            newAccount = ""; newKey = ""
            await refresh()
            account = saved
        } catch {
            loadError = String(describing: error)
        }
    }
}
