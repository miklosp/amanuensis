import SwiftUI

struct SidebarActivityBar: View {
    let coordinator: AppCoordinator

    var body: some View {
        if coordinator.recordingActivity == nil && coordinator.jobActivity == nil {
            EmptyView()
        } else {
            VStack(alignment: .leading, spacing: 8) {
                if let s = coordinator.recordingActivity {
                    ActivityRow(text: s)
                }
                if let s = coordinator.jobActivity {
                    ActivityRow(text: s)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .glassEffect(.regular, in: .rect(cornerRadius: 9))
            .padding(.horizontal, 8)
            .padding(.bottom, 6)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }
}

private struct ActivityRow: View {
    let text: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            ProgressView()
                .controlSize(.small)
            Text(text)
                .font(.callout)
                .lineLimit(2)
                .truncationMode(.middle)
        }
    }
}
