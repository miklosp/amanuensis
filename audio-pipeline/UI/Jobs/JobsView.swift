import AudioPipelineJobs
import SwiftUI

struct JobsView: View {
    let presets: PresetsStore
    @Bindable var jobs: JobsStore
    @Bindable var providers: ProvidersStore

    @State private var selection: Job.ID?

    private var sortedJobs: [Job] {
        jobs.jobs.sorted {
            $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    var body: some View {
        HSplitView {
            List(sortedJobs, selection: $selection) { job in
                Text(job.name).tag(Optional(job.id))
            }
            .frame(minWidth: 200, idealWidth: 240)

            JobsDetailPane(
                job: sortedJobs.first(where: { $0.id == selection }),
                presets: presets,
                providers: providers,
                onSave: { jobs.upsert($0) }
            )
            .frame(minWidth: 420)
        }
        .toolbar {
            ToolbarItemGroup {
                Button {
                    addJob()
                } label: {
                    Label("New Job", systemImage: "plus")
                }
                .disabled(providers.providers.isEmpty)
                Button(role: .destructive) {
                    deleteSelected()
                } label: {
                    Label("Delete", systemImage: "minus")
                }
                .disabled(selection == nil)
            }
        }
        .onAppear { selectFirstIfNeeded() }
        .onChange(of: sortedJobs.map(\.id)) { _, _ in selectFirstIfNeeded() }
    }

    private func selectFirstIfNeeded() {
        // If nothing is selected yet, or the previously-selected job no
        // longer exists, fall back to the alphabetically-first job.
        if let id = selection, sortedJobs.contains(where: { $0.id == id }) {
            return
        }
        selection = sortedJobs.first?.id
    }

    private func addJob() {
        guard !providers.providers.isEmpty else { return }
        let draft = Job.makeDraft()
        jobs.upsert(draft)
        selection = draft.id
    }

    private func deleteSelected() {
        guard let id = selection else { return }
        jobs.delete(id: id)
        selection = nil
    }
}

private struct JobsDetailPane: View {
    let job: Job?
    let presets: PresetsStore
    let providers: ProvidersStore
    let onSave: (Job) -> Void

    var body: some View {
        if let job {
            JobEditorView(initial: job,
                          presets: presets,
                          providers: providers,
                          onSave: onSave)
                .id(job.id)
        } else {
            ContentUnavailableView("Select a job", systemImage: "wand.and.stars")
        }
    }
}
