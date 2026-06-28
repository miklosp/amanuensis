import SwiftUI

extension View {
    /// The app's raw Liquid Glass background. Defaults to neutral, untinted
    /// `.regular` glass; pass a different variant (e.g. `.clear.interactive()`)
    /// for a different surface.
    ///
    /// This is the single seam for the glass treatment: if the macOS deployment
    /// target is ever lowered below 26, add the `if #available(macOS 26, *)`
    /// material fallback here only. See `docs/lower-deployment-target.md`.
    func glassPanel(in shape: some Shape, glass: Glass = .regular) -> some View {
        glassEffect(glass, in: shape)
    }

    /// A Control Center-style glass tile: adaptive frosted glass (a dark wash in
    /// dark mode, a light wash in light mode) with a pointer-reactive surface
    /// and a bright specular rim. Shared by the floating HUDs (mic cue,
    /// dictation overlay) so they read consistently. Pair with adaptive
    /// `.primary` / `.secondary` foreground styles so text contrast follows the
    /// same appearance signal the tile does.
    func glassTile(in shape: some InsettableShape) -> some View {
        modifier(GlassTile(shape: shape))
    }
}

private struct GlassTile<S: InsettableShape>: ViewModifier {
    let shape: S
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        content
            .glassPanel(in: shape, glass: .regular.tint(tint).interactive())
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

    // Dark wash in dark mode, light wash in light mode, so the tile stays a
    // legible card and the adaptive text always has contrast.
    private var tint: Color {
        colorScheme == .dark ? .black.opacity(0.4) : .white.opacity(0.35)
    }
}
