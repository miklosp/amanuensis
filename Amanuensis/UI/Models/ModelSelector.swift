// ModelSelector.swift
import LocalTranscription
import SwiftUI

/// Reusable model picker used by both the Job editor and Dictation settings.
///
/// - Local mode (`isLocal == true`): strict `Picker` over the caller-supplied
///   list of downloaded model IDs; shows each model's display name from
///   `LocalModelCatalog`.
/// - Cloud mode (`isLocal == false`): editable `TextField` with an optional
///   "Suggested" convenience menu (mirrors `JobEditorView`).
struct ModelSelector: View {
    let isLocal: Bool
    @Binding var model: String
    /// IDs of locally downloaded models; used when `isLocal` is `true`.
    let downloadedLocalModelIDs: [String]
    /// Suggested model strings shown in the convenience menu; used when `isLocal` is `false`.
    let suggestedModels: [String]

    var body: some View {
        if isLocal {
            Picker("Model", selection: $model) {
                ForEach(downloadedLocalModelIDs, id: \.self) { id in
                    Text(LocalModelCatalog.model(id: id)?.displayName ?? id).tag(id)
                }
            }
        } else {
            HStack {
                TextField("Model", text: $model)
                if !suggestedModels.isEmpty {
                    Menu("Suggested") {
                        ForEach(suggestedModels, id: \.self) { s in
                            Button(s) { model = s }
                        }
                    }
                    .frame(width: 110)
                }
            }
        }
    }
}
