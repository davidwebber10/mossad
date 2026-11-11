import MossadCore
import SwiftUI

/// One child of a sidebar item: a page inside a section, such as Coach › Findings.
struct SidebarChild<ID: Hashable>: Identifiable {
    let id: ID
    let title: String
    /// A quiet number at the right, such as the cards that wait. Nil or 0 shows none.
    var count: Int?
}

/// A sidebar item with child items, indented below it. The children show while the section is open; the click on
/// the item itself opens its first child. The item's own count shows only while the children are hidden: then the
/// child with the count says it. Used for Coach; any section with pages of its own can use it the same way.
struct SidebarItemGroup<ID: Hashable, Item: View>: View {
    let expanded: Bool
    let children: [SidebarChild<ID>]
    /// The child that is open, while the section is open.
    let selection: ID?
    let select: (ID) -> Void
    @ViewBuilder let item: Item
    @State private var hovered: ID?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: Chrome.navRowGap) {
            item
            if expanded {
                ForEach(children) { child in row(child) }
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: expanded)
    }

    private func row(_ child: SidebarChild<ID>) -> some View {
        let on = selection == child.id
        return Button { select(child.id) } label: {
            HStack(spacing: Chrome.navIconGap) {
                Text(child.title).foregroundStyle(on ? Palette.ink : Palette.navText).lineLimit(1)
                Spacer(minLength: 4)
                if let count = child.count, count > 0 {
                    Text("\(count)").font(.system(size: 11)).monospacedDigit().foregroundStyle(Palette.tertiary)
                        .accessibilityLabel("\(count) to review")
                }
            }
            .font(.system(size: 12.5, weight: on ? .medium : .regular))
            // Under the item's name: past its icon and the gap after it.
            .padding(.leading, Chrome.navRowPadding + Chrome.navIcon + Chrome.navIconGap)
            .padding(.trailing, Chrome.navRowPadding)
            .frame(height: Chrome.navRowHeight - 4)
            .background(on ? Palette.selection : hovered == child.id ? Palette.fill.opacity(0.5) : .clear,
                        in: RoundedRectangle(cornerRadius: Chrome.navRowRadius, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: Chrome.navRowRadius, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 ? child.id : (hovered == child.id ? nil : hovered) }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}
