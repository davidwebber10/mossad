import MossadCore
import SwiftUI

/// A person in a meeting: their hue as a dot, then the name. An unnamed voice asks to be named in the accent.
struct SpeakerChip: View {
    let name: String
    let color: Color
    /// A quiet word after the name, such as "you".
    var note: String?
    /// "Speaker A · name this voice": the chip turns to the accent because the owner needs to act.
    var needsYou = false
    // The canvas's sizes, scaled with Dynamic Type on iPhone (they stay as drawn on the Mac).
    @ScaledMetric(relativeTo: .body) private var textSize: CGFloat = 13
    @ScaledMetric(relativeTo: .body) private var height: CGFloat = 24
    @ScaledMetric(relativeTo: .body) private var dot: CGFloat = 8

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: dot, height: dot)
            Text(name).fontWeight(needsYou ? .medium : .regular)
            if let note { Text(note).foregroundStyle(needsYou ? Palette.accent : Palette.secondary) }
        }
        .font(.system(size: textSize))
        .lineLimit(1)
        .foregroundStyle(needsYou ? Palette.accent : Palette.ink)
        .padding(.leading, Space.s)
        .padding(.trailing, 10)
        .frame(minHeight: height)
        .background(needsYou ? Palette.accentTint : Palette.fill, in: Capsule())
        .accessibilityElement(children: .combine)
    }
}

/// A meeting's kind or topic: "Leadership offsite". Quiet, never colored.
struct TagChip: View {
    let text: String
    @ScaledMetric(relativeTo: .caption) private var textSize: CGFloat = 11
    @ScaledMetric(relativeTo: .caption) private var height: CGFloat = 20

    var body: some View {
        Text(text)
            .font(.system(size: textSize, weight: .medium))
            .lineLimit(1)
            .foregroundStyle(Palette.secondary)
            .padding(.horizontal, Space.s)
            .frame(minHeight: height)
            .background(Palette.fill, in: Capsule())
    }
}

/// "2 voices need names", "Overdue": the accent means the owner needs to act.
struct NeedsYouChip: View {
    let text: String
    var systemImage: String?
    @ScaledMetric(relativeTo: .caption) private var textSize: CGFloat = 11
    @ScaledMetric(relativeTo: .caption) private var height: CGFloat = 20

    var body: some View {
        HStack(spacing: 5) {
            if let systemImage { Image(systemName: systemImage).font(.system(size: textSize * 0.82, weight: .semibold)) }
            Text(text).lineLimit(1)
        }
        .font(.system(size: textSize, weight: .semibold))
        .monospacedDigit()
        .foregroundStyle(Palette.accent)
        .padding(.horizontal, Space.s)
        .frame(minHeight: height)
        .background(Palette.accentTint, in: Capsule())
    }
}

/// The platform as a dot, its only use of color. Hollow for a meeting that has not happened yet.
struct PlatformDot: View {
    let platform: Platform
    var size: CGFloat = 8
    var hollow = false

    var body: some View {
        Group {
            if hollow {
                Circle().strokeBorder(Palette.platform(platform), lineWidth: 1.5)
            } else {
                Circle().fill(Palette.platform(platform))
            }
        }
        .frame(width: size, height: size)
        .accessibilityLabel(platform.displayName)
    }
}
