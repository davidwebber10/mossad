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
        if reduceTransparency || PreviewAccessibility.reduceTransparency {
            // The design's fallback, rather than the system's own frosted gray, so it stays warm paper.
            content
                .background(Palette.surface, in: shape)
                .hairlineBorder(shape)
        } else {
            content
                .glassEffect(interactive ? .regular.interactive() : .regular, in: shape)
                // Glass has no edge of its own strong enough under Increase Contrast.
                .overlay { if contrast == .increased || PreviewAccessibility.increaseContrast { shape.strokeBorder(Palette.hairline, lineWidth: 1) } }
        }
    }
}

extension View {
    /// The canvas's own glass for the window chrome: the sidebar card and the toolbar's capsules. A translucent
    /// warm fill, an inner 1 pt ring, and a soft shadow, rather than the system glass, whose rim and gray read
    /// heavier than the design on warm paper. Nothing scrolls under the chrome, so it needs no blur.
    func chromeGlass<S: InsettableShape>(in shape: S, fill: Color = Palette.glass, shadow: ChromeShadow = .control) -> some View {
        modifier(ChromeGlass(shape: shape, fill: fill, shadow: shadow))
    }
}

enum ChromeShadow {
    /// 0 2 8 at 8%: the toolbar's capsules.
    case control
    /// 0 1 2 at 6%: the sidebar card.
    case card
    /// 0 8 24 at 14%: what floats over scrolling content, such as the chat composer.
    case floating
}

private extension ChromeShadow {
    var opacity: Double { switch self { case .control: 0.08; case .card: 0.06; case .floating: 0.14 } }
    var radius: CGFloat { switch self { case .control: 4; case .card: 1; case .floating: 12 } }
    var y: CGFloat { switch self { case .control: 2; case .card: 1; case .floating: 8 } }
}

private struct ChromeGlass<S: InsettableShape>: ViewModifier {
    let shape: S
    let fill: Color
    let shadow: ChromeShadow
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    func body(content: Content) -> some View {
        if reduceTransparency || PreviewAccessibility.reduceTransparency {
            content
                .background(Palette.surface, in: shape)
                .hairlineBorder(shape)
        } else {
            let increased = contrast == .increased || PreviewAccessibility.increaseContrast
            content
                .background {
                    shape.fill(fill)
                        .overlay { shape.strokeBorder(increased ? Palette.hairline : Palette.glassRing, lineWidth: 1) }
                        .shadow(color: .black.opacity(shadow.opacity), radius: shadow.radius, y: shadow.y)
                }
        }
    }
}
