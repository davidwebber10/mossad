import MossadCore
import SwiftUI

/// The iPhone's page: warm paper with the canvas's faint accent glow in the top corner, under the system's
/// glass bars. Every tab and pushed page sits on it, so the phone reads as the same product as the Mac.
struct PhonePageBackground: View {
    var body: some View {
        ZStack(alignment: .topLeading) {
            Palette.window
            RadialGradient(colors: [Self.glow, Self.glow.opacity(0)], center: .topLeading, startRadius: 0, endRadius: 330)
                .frame(width: 520, height: 420)
                .scaleEffect(x: 1, y: 0.83, anchor: .topLeading)
        }
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }

    /// oklch(0.92 0.05 55 / .7) light, oklch(0.4 0.07 55 / .45) dark, from the canvas.
    static let glow = Color(light: 0xF8DCC6, lightAlpha: 0.7, dark: 0x5A3A1E, darkAlpha: 0.45)
}

extension View {
    /// The phone page: paper, the glow, and no system grouped gray behind lists.
    func phonePage() -> some View {
        scrollContentBackground(.hidden)
            .background { PhonePageBackground() }
            .toolbarBackgroundVisibility(.hidden, for: .navigationBar)
    }
}

/// "TODAY", "IN ONE LINE": the label step in caps, binding to what follows it.
struct PhoneLabel: View {
    let text: String
    var color: Color = Palette.tertiary

    init(_ text: String, color: Color = Palette.tertiary) {
        self.text = text
        self.color = color
    }

    var body: some View {
        Text(text)
            .textRole(.label)
            .foregroundStyle(color)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityAddTraits(.isHeader)
    }
}

/// Processing as the design draws it: a short accent track with a fill that keeps moving, never a spinner.
struct PhoneProcessingMark: View {
    var body: some View {
        TimelineView(.animation) { context in
            let phase = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.6) / 1.6
            Capsule().fill(Palette.accentFill.opacity(0.22))
                .overlay(alignment: .leading) {
                    GeometryReader { g in
                        Capsule().fill(Palette.accentFill)
                            .frame(width: g.size.width * 0.4)
                            .offset(x: (g.size.width * 1.4) * phase - g.size.width * 0.4)
                    }
                    .clipShape(Capsule())
                }
        }
        .frame(width: 18, height: 4)
        .accessibilityHidden(true)
    }
}

/// A row on the page with a hairline under it, as the canvas separates rows instead of carding them.
struct HairlineRow<Content: View>: View {
    var divided = true
    @ViewBuilder let content: Content

    var body: some View {
        content
            .padding(.vertical, Space.m)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .bottom) { if divided { Hairline() } }
            .contentShape(Rectangle())
    }
}

extension Platform {
    /// "Meet", "Teams": the list's short name; the dot carries the color.
    var shortName: String {
        switch self {
        case .zoom: "Zoom"
        case .meet: "Meet"
        case .teams: "Teams"
        case .inPerson: "In person"
        }
    }
}

/// The canvas's primary button: the accent fill, a capsule, full width when asked.
struct PhoneFillButtonStyle: ButtonStyle {
    var color: Color = Palette.accentFill
    var wide = false
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .textRole(.headline)
            .foregroundStyle(Palette.onAccent)
            .padding(.horizontal, 20).padding(.vertical, 13)
            .frame(maxWidth: wide ? .infinity : nil)
            .background(color.opacity(configuration.isPressed ? 0.85 : 1), in: Capsule())
            .opacity(isEnabled ? 1 : 0.45)
            .contentShape(Capsule())
    }
}

extension ButtonStyle where Self == PhoneFillButtonStyle {
    static var phoneFill: PhoneFillButtonStyle { PhoneFillButtonStyle() }
    static func phoneFill(_ color: Color = Palette.accentFill, wide: Bool = false) -> PhoneFillButtonStyle {
        PhoneFillButtonStyle(color: color, wide: wide)
    }
}

/// Open and Done, or Summary and Transcript: a segmented control centered under the title, on glass.
struct PhoneSegments<Value: Hashable>: View {
    let options: [(Value, String)]
    @Binding var selection: Value
    @Namespace private var selectionSpace

    var body: some View {
        // At the largest text sizes the segments do not fit; they scroll sideways rather than cut their names.
        ViewThatFits(in: .horizontal) {
            segments
            ScrollView(.horizontal, showsIndicators: false) { segments }
        }
    }

    private var segments: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.0) { value, title in
                let on = value == selection
                Button {
                    withAnimation(.snappy(duration: 0.25)) { selection = value }
                } label: {
                    Text(title)
                        .textRole(.secondary)
                        .fontWeight(on ? .semibold : .regular)
                        .foregroundStyle(on ? Palette.ink : Palette.secondary)
                        .lineLimit(1)
                        .fixedSize()
                        .padding(.horizontal, 14).padding(.vertical, 7)
                        .background {
                            if on {
                                Capsule().fill(Palette.segmentOn)
                                    .shadow(color: .black.opacity(0.08), radius: 2, y: 1)
                                    .matchedGeometryEffect(id: "on", in: selectionSpace)
                            }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(on ? [.isSelected] : [])
            }
        }
        .padding(3)
        .mossadGlass(in: Capsule())
        .fixedSize()
    }
}
