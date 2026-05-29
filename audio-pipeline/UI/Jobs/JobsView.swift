import AudioPipelineJobs
import SwiftUI

struct JobsView: View {
    let presets: PresetsStore
    @Bindable var jobs: JobsStore
    let keychain: KeychainStore

    @State private var selection: Job.ID?

    var body: some View {
        HSplitView {
            List(jobs.jobs, selection: $selection) { job in
                Text(job.name).tag(Optional(job.id))
            }
            .frame(minWidth: 200, idealWidth: 240)

            if let id = selection, let job = jobs.jobs.first(where: { $0.id == id }) {
                JobEditorView(initial: job,
                              presets: presets,
                              keychain: keychain,
                              onSave: { jobs.upsert($0) })
                    .id(job.id)
                    .frame(minWidth: 420)
            } else {
                ContentUnavailableView("Select a job", systemImage: "wand.and.stars")
                    .frame(minWidth: 420)
            }
        }
        .toolbar {
            ToolbarItemGroup {
                Button {
                    addJob()
                } label: {
                    Label("New Job", systemImage: "plus")
                }
                Button(role: .destructive) {
                    deleteSelected()
                } label: {
                    Label("Delete", systemImage: "minus")
                }
                .disabled(selection == nil)
            }
        }
    }

    private func addJob() {
        let draft = Job.makeDraft(presets: presets)
        jobs.upsert(draft)
        selection = draft.id
    }

    private func deleteSelected() {
        guard let id = selection else { return }
        jobs.delete(id: id)
        selection = nil
    }
}
