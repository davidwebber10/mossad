import SwiftUI

/// The page grammar: a 150 pt label column on the left and the content on the right. The summary, the coach,
/// a person's profile, Analytics, and Settings all use it. In a compact width (the iPhone) the label stacks
/// over the content.
struct LabelColumn<Content: View>: View {
    static var labelWidth: CGFloat { 150 }

    let label: String
    /// A second line under the label, in the accent: "3 need attention".
    var note: String?
    /// Lines up the label with the first row's text when the rows have their own padding.
    var labelTopPadding: CGFloat = 2
    @ViewBuilder let content: Content

    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var sizeClass
    private var stacked: Bool { sizeClass == .compact }
    #else
    private let stacked = false
    #endif

    var body: some View {
        if stacked {
            VStack(alignment: .leading, spacing: 6) {
                labelView(alignment: .leading).padding(.top, Space.l)
                content.frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            HStack(alignment: .top, spacing: Space.m) {
                labelView(alignment: .trailing)
                    .frame(width: Self.labelWidth, alignment: .trailing)
                    .padding(.top, labelTopPadding)
                content.frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func labelView(alignment: HorizontalAlignment) -> some View {
        VStack(alignment: alignment, spacing: 3) {
            Text(label).textRole(.label).foregroundStyle(Palette.secondary)
            if let note {
                // Sentence case: the canvas sets only the label itself in caps.
                Text(note).font(.system(size: TextRole.label.size, weight: .semibold)).monospacedDigit()
                    .foregroundStyle(Palette.accent)
            }
        }
        .multilineTextAlignment(alignment == .trailing ? .trailing : .leading)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

/// Label column groups one after another, with a hairline or a gap between them.
struct LabelColumnStack<Content: View>: View {
    var spacing: CGFloat = 26
    var divided = false
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: divided ? 0 : spacing) {
            if divided {
                Group(subviews: content) { groups in
                    ForEach(groups) { group in
                        if group.id != groups.first?.id { Hairline().padding(.vertical, spacing / 2) }
                        group
                    }
                }
            } else {
                content
            }
        }
    }
}
