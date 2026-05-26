import AudioPipelineJobs
import SwiftUI

struct JobFieldFormView: View {
    let shape: JobShape
    @Binding var values: [String: String]

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
                    Text(label(spec))
                    if let help = spec.help {
                        Text(help).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func field<Content: View>(_ spec: FieldSpec, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label(spec)).font(.subheadline)
            content()
            if let help = spec.help {
                Text(help).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func label(_ spec: FieldSpec) -> String {
        spec.required ? "\(spec.label) *" : spec.label
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
