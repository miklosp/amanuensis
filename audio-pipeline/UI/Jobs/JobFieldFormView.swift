import AudioPipelineJobs
import SwiftUI

struct JobFieldFormView: View {
    let preset: Preset
    @Binding var values: [String: String]

    private var shape: JobShape { preset.shape }

    var body: some View {
        ForEach(shape.fields, id: \.key) { spec in
            row(spec)
        }
    }

    @ViewBuilder
    private func row(_ spec: FieldSpec) -> some View {
        switch spec.kind {
        case .text:
            field(spec) { TextField("", text: binding(spec.key)) }
        case .longText:
            field(spec) {
                TextEditor(text: binding(spec.key))
                    .frame(minHeight: 88)
                    .font(.body.monospaced())
            }
        case .number:
            field(spec) { TextField("", text: binding(spec.key)) }
        case .language:
            field(spec) {
                TextField("ISO-639-1 (e.g. sv, en)", text: binding(spec.key))
                    .textCase(.lowercase)
            }
        case .picker(let options):
            field(spec) {
                Picker("", selection: binding(spec.key)) {
                    Text("—").tag("")
                    ForEach(options, id: \.self) { Text($0).tag($0) }
                }
                .labelsHidden()
            }
        case .checkbox:
            Toggle(isOn: boolBinding(spec.key)) {
                VStack(alignment: .leading) {
                    labelRow(spec)
                    if let help = hint(spec) {
                        Text(help).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func field<Content: View>(_ spec: FieldSpec, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            labelRow(spec).font(.subheadline)
            content()
            if let help = hint(spec) {
                Text(help).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    // Field label plus, when the selected preset documents this field, an
    // info icon whose hover tooltip carries the provider-specific constraints.
    @ViewBuilder
    private func labelRow(_ spec: FieldSpec) -> some View {
        HStack(spacing: 4) {
            Text(label(spec))
            if let tip = preset.fieldHelp?[spec.key], !tip.isEmpty {
                Image(systemName: "info.circle")
                    .imageScale(.small)
                    .foregroundStyle(.secondary)
                    .help(tip)
            }
        }
    }

    // Per-preset label override (e.g. gpt-4o-transcribe relabels the shared
    // "Vocabulary biasing" prompt field as "Prompt") falling back to the shape.
    private func label(_ spec: FieldSpec) -> String {
        let base = preset.fieldLabels?[spec.key] ?? spec.label
        return spec.required ? "\(base) *" : base
    }

    // Per-preset inline caption override, falling back to the shape's help.
    private func hint(_ spec: FieldSpec) -> String? {
        preset.fieldHints?[spec.key] ?? spec.help
    }

    private func binding(_ key: String) -> Binding<String> {
        Binding(
            get: { values[key] ?? "" },
            set: { values[key] = $0 }
        )
    }

    private func boolBinding(_ key: String) -> Binding<Bool> {
        Binding(
            get: { (values[key] ?? "false") == "true" },
            set: { values[key] = $0 ? "true" : "false" }
        )
    }
}
