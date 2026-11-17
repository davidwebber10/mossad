import MossadCore
import SwiftUI

/// The profile colors: the speaker hues for five, the in-person gray for graphite.
extension ProfileColor {
    var color: Color {
        switch self {
        case .orange: Self.hue(55)
        case .blue: Self.hue(235)
        case .green: Self.hue(145)
        case .purple: Self.hue(295)
        case .pink: Self.hue(355)
        case .graphite: Palette.inPerson
        }
    }

    var title: String { rawValue.prefix(1).uppercased() + rawValue.dropFirst() }

    private static func hue(_ h: Double) -> Color {
        Color(light: OKLCH(lightness: 0.58, chroma: 0.15, hue: h), dark: OKLCH(lightness: 0.74, chroma: 0.15, hue: h))
    }
}

/// The dot of a profile's color.
struct ProfileDot: View {
    let color: ProfileColor
    var size: CGFloat = 8

    var body: some View {
        Circle().fill(color.color).frame(width: size, height: size).accessibilityHidden(true)
    }
}
