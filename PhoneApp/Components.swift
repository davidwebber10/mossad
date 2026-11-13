import MossadCore
import SwiftUI

extension Platform {
    var symbol: String {
        switch self {
        case .zoom: "video.fill"
        case .meet: "person.3.fill"
        case .teams: "person.2.wave.2.fill"
        case .inPerson: "mic.fill"
        }
    }

    var tint: Color { Palette.platform(self) }
}

extension CallRecord {
    var minutes: Int { max(1, Int(end.timeIntervalSince(start) / 60)) }
}

/// "45 min" or "1 h 20 min".
func duration(_ seconds: TimeInterval) -> String {
    let m = Int(seconds / 60)
    return m >= 60 ? (m % 60 == 0 ? "\(m / 60) h" : "\(m / 60) h \(m % 60) min") : "\(m) min"
}

/// "4:05" or "1:02:03".
func clock(_ t: TimeInterval) -> String {
    let s = Int(t)
    return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
}

/// `**bold**` and links in summary text.
func rich(_ text: String) -> AttributedString {
    (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text)
}

func scoreColor(_ score: Int) -> Color { score >= 4 ? Palette.ok : score == 3 ? Palette.secondary : Palette.accent }

/// A group on the page: no card around it, a hairline above, as the canvas separates groups by type and rules.
struct Card<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: Space.m) { content }
            .padding(.top, Space.l)
            .padding(.bottom, Space.xs)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .top) { Hairline() }
            .foregroundStyle(Palette.ink)
    }
}

/// A group's label in caps. The symbol is kept for callers but not drawn: the canvas labels groups with words.
struct CardTitle: View {
    let text: String
    var symbol: String?

    var body: some View { PhoneLabel(text) }
}

/// The coach's score for a meeting, as a small colored "4".
struct ScoreBadge: View {
    let score: Int

    var body: some View {
        Text("\(score)")
            .font(.caption.weight(.bold)).monospacedDigit()
            .foregroundStyle(scoreColor(score))
            .frame(width: 24, height: 24)
            .background(scoreColor(score).opacity(0.16), in: .circle)
            .accessibilityLabel("Coach score \(score) of 5")
    }
}

/// A figure as the canvas sets it: the number large, what it counts under it, no tile around it.
struct StatTile: View {
    let value: String
    let label: String
    var detail: String?

    var body: some View {
        VStack(alignment: .leading, spacing: Rhythm.pairGap) {
            Text(value).textRole(.title).foregroundStyle(Palette.ink).lineLimit(1).minimumScaleFactor(0.7)
            Text(label).textRole(.secondary).foregroundStyle(Palette.secondary)
            if let detail { Text(detail).textRole(.secondary).foregroundStyle(Palette.tertiary).lineLimit(2) }
        }
        .padding(.vertical, Space.s)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}
