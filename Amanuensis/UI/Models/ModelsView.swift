// ModelsView.swift
import SwiftUI
import LocalTranscription

struct ModelsView: View {
    @Bindable var store: LocalModelsStore
    var body: some View {
        List(LocalModelCatalog.all) { model in
            ModelRowView(model: model,
                         state: store.states[model.id] ?? .init(),
                         isDictation: model.id == store.dictationModelID,
                         isInMemory: model.id == store.residentModelID,
                         isLoading: model.id == store.loadingModelID,
                         isUnloading: model.id == store.unloadingModelID,
                         onDownload: { Task { await store.download(model) } },
                         onDelete: { Task { await store.delete(model) } })
        }
        .task { await store.refresh() }
        .navigationTitle("Local Models")
    }
}
