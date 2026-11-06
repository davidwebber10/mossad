import SwiftUI

extension View {
    /// Liquid Glass for what floats: the sidebar, toolbar controls, the player, popovers, the composer. Never
    /// for rows, chips, stats, or summary text, and never glass on glass.
    func mossadGlass<S: InsettableShape>(in shape: S, interactive: Bool = false) -> some View {
        modifier(MossadGlass(shape: shape, interactive: interactive))
    }

    func mossadGlass(cornerRadius: CGFloat = Radius.pane, interactive: Bool = false) -> some View {
        mossadGlass(in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous), interactive: interactive)
    }
}

private struct MossadGlass<S: InsettableShape>: ViewModifier {
    let shape: S
    let interactive: Bool
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    func body(content: Content) -> some View {
        if reduceTransparency {
            // The design's fallback, rather than the system's own frosted gray, so it stays warm paper.
            content
                .background(Palette.surface, in: shape)
                .hairlineBorder(shape)
        } else {
            content
                .glassEffect(interactive ? .regular.interactive() : .regular, in: shape)
                // Glass has no edge of its own strong enough under Increase Contrast.
                .overlay { if contrast == .increased { shape.strokeBorder(Palette.hairline, lineWidth: 1) } }
        }
    }
}
