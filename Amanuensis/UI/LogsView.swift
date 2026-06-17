import AppLog
import SwiftUI

struct LogsView: View {
    let logs: LogStore

    var body: some View {
        Group {
            if logs.entries.isEmpty {
                ContentUnavailableView(
                    "No activity yet",
                    systemImage: "list.bullet.rectangle",
                    description: Text("Job and recording events will appear here.")
                )
            } else {
                List(logs.entries.reversed()) { entry in
                    LogRow(entry: entry)
                }
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Clear", systemImage: "trash") {
                    logs.clear()
                }
                .disabled(logs.entries.isEmpty)
            }
        }
    }
}

private struct LogRow: View {
    let entry: LogEntry

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: iconName)
                .foregroundStyle(iconColor)
                .font(.callout)
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.message)
                    .font(.callout)
                    .textSelection(.enabled)
                HStack(spacing: 6) {
                    Text(entry.category.rawValue.capitalized)
                        .font(.caption2)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(.quaternary, in: .capsule)
                    Text(entry.date, format: .dateTime.year().month().day().hour().minute().second())
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
        }
        .padding(.vertical, 2)
    }

    private var iconName: String {
        switch entry.level {
        case .info: "info.circle"
        case .warning: "exclamationmark.triangle.fill"
        case .error: "xmark.octagon.fill"
        }
    }

    private var iconColor: Color {
        switch entry.level {
        case .info: .secondary
        case .warning: .yellow
        case .error: .red
        }
    }
}
