import AudioPipelineJobs
import SwiftUI

struct JobsSettingsPanel: View {
    let presets: PresetsStore
    @Bindable var jobs: JobsStore
    let keychain: KeychainStore

    @State private var selectedJobID: UUID?
    @State private var editing: Job?
    @State private var creating = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            List(selection: $selectedJobID) {
                ForEach(jobs.jobs) { job in
                    JobRow(job: job, preset: presets.preset(id: job.presetID))
                        .tag(Optional(job.id))
                }
            }
            .listStyle(.inset)

            Divider()

            GlassEffectContainer(spacing: 8) {
                HStack(spacing: 8) {
                    Button {
                        creating = true
                    } label: {
                        Image(systemName: "plus")
                    }
                    .buttonStyle(.glass)

                    Button {
                        if let id = selectedJobID,
                           let job = jobs.jobs.first(where: { $0.id == id }) {
                            editing = job
                        }
                    } label: {
                        Image(systemName: "pencil")
                    }
                    .buttonStyle(.glass)
                    .disabled(selectedJobID == nil)

                    Button {
                        if let id = selectedJobID {
                            jobs.delete(id: id)
                            selectedJobID = nil
                        }
                    } label: {
                        Image(systemName: "minus")
                    }
                    .buttonStyle(.glass)
                    .disabled(selectedJobID == nil)

                    Spacer()
                }
            }
            .padding(8)
        }
        .sheet(item: $editing) { job in
            JobEditorView(initial: job, presets: presets, keychain: keychain) { updated in
                jobs.upsert(updated)
            }
        }
        .sheet(isPresented: $creating) {
            JobEditorView(initial: nil, presets: presets, keychain: keychain) { created in
                jobs.upsert(created)
            }
        }
    }
}

private struct JobRow: View {
    let job: Job
    let preset: Preset?

    var body: some View {
        VStack(alignment: .leading) {
            Text(job.name).font(.headline)
            HStack(spacing: 6) {
                Text(preset?.displayName ?? job.presetID)
                Text("·")
                Text(job.model.isEmpty ? "—" : job.model)
            }
            .foregroundStyle(.secondary)
            .font(.subheadline)
        }
        .padding(.vertical, 2)
    }
}
