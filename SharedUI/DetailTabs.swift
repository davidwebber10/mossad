import SwiftUI

/// A page's tabs: a raised glass segmented control centered on the lower edge of the page's band. The meeting
/// page and the person page share it.
struct DetailTabs<Tab: Hashable & RawRepresentable>: View where Tab.RawValue == String {
    @Binding var tab: Tab
    let tabs: [Tab]
    var accessibilityLabel = "Tabs"
    @Namespace private var selection

    var body: some View {
        HStack(spacing: 0) {
            ForEach(tabs, id: \.self) { t in
                let on = t == tab
                Button { withAnimation(.snappy(duration: 0.2)) { tab = t } } label: {
                    Text(t.rawValue)
                        .font(.system(size: Self.textSize, weight: on ? .semibold : .regular))
                        .foregroundStyle(on ? Palette.ink : Palette.secondary)
                        .lineLimit(1)
                        .padding(.horizontal, 14).padding(.vertical, Self.verticalPadding)
                        .background {
                            if on {
                                Capsule().fill(Palette.segmentOn)
                                    .shadow(color: .black.opacity(0.12), radius: 1, y: 1)
                                    .matchedGeometryEffect(id: "on", in: selection)
                            }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(on ? [.isSelected] : [])
            }
        }
        .padding(3)
        // Solid and raised: lighter than the band, with an edge and a floating shadow, so the tabs read as their own
        // control and nothing shows through them.
        .background(Palette.raised, in: Capsule())
        .chromeGlass(in: Capsule(), fill: .clear, shadow: .floating)
        .overlay(Capsule().strokeBorder(Palette.bar, lineWidth: 1).allowsHitTesting(false))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(accessibilityLabel)
    }

    #if os(iOS)
    private static var textSize: CGFloat { 14 }
    private static var verticalPadding: CGFloat { 7 }
    #else
    private static var textSize: CGFloat { 12.5 }
    private static var verticalPadding: CGFloat { 5 }
    #endif
}
