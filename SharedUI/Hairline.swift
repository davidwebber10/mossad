import SwiftUI

/// The 1 pt line that separates groups instead of cards. Its color rises to 20% ink under Increase Contrast.
struct Hairline: View {
    var axis: Axis = .horizontal

    var body: some View {
        Rectangle()
            .fill(Palette.hairline)
            .frame(width: axis == .vertical ? 1 : nil, height: axis == .horizontal ? 1 : nil)
            .accessibilityHidden(true)
    }
}

extension View {
    /// A hairline along one edge, inside the view's bounds.
    func hairline(_ edge: VerticalEdge = .bottom) -> some View {
        overlay(alignment: edge == .top ? .top : .bottom) { Hairline() }
    }

    /// A hairline border that follows a shape, such as a row or an empty state.
    func hairlineBorder<S: InsettableShape>(_ shape: S) -> some View {
        overlay { shape.strokeBorder(Palette.hairline, lineWidth: 1) }
    }
}
