import SwiftUI

// The shared Control-Center-style cue tile used by both the mic-on and mic-off
// cues: a glassy, pointer-reactive Liquid Glass capsule with a red circular
// action button on the left and a two-line label on the right. The tint and
// text follow the system appearance, flipping together between light and dark.
// Hovering reveals a notification-style close badge in the top-left corner and
// pulses the action button. Tapping the action button invokes onAction; the
// close badge or anywhere else on the capsule invokes onDismiss. Rendered
// inside FloatingCueController's NSPanel.
struct CueCard: View {
    let systemImage: String
    let title: String
    let subtitle: String
    let onAction: () -> Void
    let onDismiss: () -> Void

    @State private var hovering = false
    @State private var pulse = false

    var body: some View {
        HStack(spacing: 10) {
            actionButton

            VStack(alignment: .leading, spacing: 0) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 8)
        .frame(width: 174)
        .glassTile(in: Capsule())
        .contentShape(Capsule())
        .onTapGesture { onDismiss() }
        .overlay(alignment: .topLeading) {
            if hovering { closeBadge }
        }
        .padding(8)   // room for the close badge to overhang the corner
        .contentShape(Rectangle())
        .onHover { isHovering in
            withAnimation(.snappy(duration: 0.15)) { hovering = isHovering }
        }
    }

    private var actionButton: some View {
        Button(action: onAction) {
            Image(systemName: systemImage)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 34, height: 34)
                .background(pulse ? Color.red.mix(with: .white, by: 0.45) : .red, in: Circle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering in
            if isHovering {
                withAnimation(.easeInOut(duration: 0.55).repeatForever(autoreverses: true)) {
                    pulse = true
                }
            } else {
                withAnimation(.easeInOut(duration: 0.2)) { pulse = false }
            }
        }
    }

    private var closeBadge: some View {
        Button(action: onDismiss) {
            Image(systemName: "xmark")
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(.secondary)
                .frame(width: 18, height: 18)
                .background(.thinMaterial, in: Circle())
                .overlay(Circle().strokeBorder(.white.opacity(0.25), lineWidth: 0.5))
                .shadow(radius: 1, y: 0.5)
        }
        .buttonStyle(.plain)
        .offset(x: -7, y: -7)
        .transition(.scale.combined(with: .opacity))
    }
}
