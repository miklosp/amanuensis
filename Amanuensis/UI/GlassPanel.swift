import SwiftUI

extension View {
    /// A Control Center-style glass tile: adaptive frosted glass with a
    /// pointer-reactive surface and a bright specular rim, shared by the
    /// floating HUDs (mic cue, dictation overlay). Liquid Glass on macOS 26+,
    /// a frosted `.ultraThinMaterial` fallback below. Pair with adaptive
    /// `.primary` / `.secondary` foreground styles so text contrast follows the
    /// same appearance signal the tile does.
    ///
    /// This file is the single seam for the glass treatment: the
    /// `if #available(macOS 26, *)` branches live here only.
    func glassTile(in shape: some InsettableShape) -> some View {
        modifier(GlassTile(shape: shape))
    }

    /// A plain Liquid Glass background: `.glassEffect(.regular, in:)` on macOS
    /// 26+, `.ultraThinMaterial` below. Used by the sidebar activity bar.
    @ViewBuilder
    func glassBackground(in shape: some Shape) -> some View {
        if #available(macOS 26, *) {
            glassEffect(.regular, in: shape)
        } else {
            background(.ultraThinMaterial, in: shape)
        }
    }

    /// Prominent action-button style: `.glassProminent` on macOS 26+,
    /// `.borderedProminent` below.
    @ViewBuilder
    func glassProminentButtonStyle() -> some View {
        if #available(macOS 26, *) {
            buttonStyle(.glassProminent)
        } else {
            buttonStyle(.borderedProminent)
        }
    }
}

private struct GlassTile<S: InsettableShape>: ViewModifier {
    let shape: S
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        tile(content)
            .overlay {
                // The bright specular rim a Control Center tile has; brightest
                // along the top edge, fading toward the bottom.
                shape.strokeBorder(
                    LinearGradient(
                        colors: [.white.opacity(0.55), .white.opacity(0.1)],
                        startPoint: .top, endPoint: .bottom),
                    lineWidth: 1)
            }
    }

    @ViewBuilder
    private func tile(_ content: Content) -> some View {
        if #available(macOS 26, *) {
            content.glassEffect(.regular.tint(tint).interactive(), in: shape)
        } else {
            content.background(.ultraThinMaterial, in: shape)
        }
    }

    // Dark wash in dark mode, light wash in light mode, so the tile stays a
    // legible card and the adaptive text always has contrast.
    private var tint: Color {
        colorScheme == .dark ? .black.opacity(0.4) : .white.opacity(0.35)
    }
}
