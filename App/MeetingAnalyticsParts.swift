import MossadCore
import SwiftUI

// MARK: Playing a moment

/// Plays the meeting from a second of it. Nil in the environment while there is no audio to play.
struct MomentPlayer: Sendable {
    let play: @MainActor @Sendable (TimeInterval) -> Void
}

private struct MomentPlayerKey: EnvironmentKey {
    static let defaultValue: MomentPlayer? = nil
}

extension EnvironmentValues {
    var momentPlayer: MomentPlayer? {
        get { self[MomentPlayerKey.self] }
        set { self[MomentPlayerKey.self] = newValue }
    }
}

/// A time of the call that plays from there, as the summary's times do.
struct PlayAt: View {
    @Environment(\.momentPlayer) private var player
    let at: TimeInterval
    var long = false
    /// Words before the time, such as a turn's length.
    var lead: String?
    var icon = false

    var body: some View {
        Button { player?.play(at) } label: {
            HStack(spacing: Space.xs) {
                if icon { IconImage(.play, size: 8) }
                if let lead { Text(lead).foregroundStyle(Palette.ink) }
                Text(long ? longClock(at) : clock(at)).foregroundStyle(icon ? Palette.accent : Palette.tertiary)
            }
            .monospacedDigit()
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(Palette.accent)
        .disabled(player == nil)
        .help(player == nil ? "The audio is not available" : "Play from \(clock(at))")
        .accessibilityLabel((lead.map { "\($0), " } ?? "") + "play from \(clock(at))")
    }
}

// MARK: A number against its usual

/// A number in a table with its mark: an arrow when it stood out against the person's history, a quiet dot when
/// the history calls it usual, and nothing when the history is too short to say. The range is the tooltip.
struct Marked: View {
    let text: String
    var reading: MeetingAnalytics.Reading?
    /// The tooltip: "Usually 30 to 40% in 1:1s with you (from 8 meetings)".
    var tip: String?

    static let markWidth: CGFloat = 9

    var body: some View {
        let out = reading?.stoodOut == true
        HStack(spacing: Space.xs) {
            mark.frame(width: Self.markWidth)
            Text(text).fontWeight(out ? .semibold : .regular).foregroundStyle(Palette.ink)
        }
        .help(tip ?? "")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spoken)
    }

    @ViewBuilder
    private var mark: some View {
        switch reading?.standing {
        case .above: Text("↑").font(.system(size: Rhythm.noteSize, weight: .bold)).foregroundStyle(Palette.accent)
        case .below: Text("↓").font(.system(size: Rhythm.noteSize, weight: .bold)).foregroundStyle(Palette.accent)
        case .usual: Circle().fill(Palette.tertiaryMark).frame(width: 3, height: 3)
        case nil: Color.clear
        }
    }

    private var spoken: String {
        let standing = switch reading?.standing {
        case .above: ", above the usual"
        case .below: ", below the usual"
        case .usual: ", as usual"
        case nil: ""
        }
        return text + standing + (tip.map { ". \($0)" } ?? "")
    }
}

/// "↑ ↓ far from the person's usual · as usual": the key under a table with marks.
struct MarkKey: View {
    var body: some View {
        FlowLayout(spacing: 12) {
            HStack(spacing: Space.xs) {
                Text("↑ ↓").font(.system(size: Rhythm.noteSize, weight: .bold)).foregroundStyle(Palette.accent)
                Text("far from the person’s usual")
            }
            HStack(spacing: Space.xs) {
                Circle().fill(Palette.tertiaryMark).frame(width: 3, height: 3)
                Text("as usual")
            }
            Text("No mark: fewer than 5 earlier meetings. Point at a number for the range.")
        }
        .font(.system(size: Rhythm.secondarySize))
        .foregroundStyle(Palette.tertiary)
        .accessibilityHidden(true)
    }
}

/// "Usually 30 to 40% in 1:1s with you": a sentence part with its first letter in upper case.
func sentenceCase(_ text: String) -> String { text.prefix(1).uppercased() + text.dropFirst() }

// MARK: Sparkline

/// A small line over the last meetings, in the Analytics page's line: the accent, 1.5 pt, with this call as a dot
/// at the end and a hairline at the median of the meetings before it.
struct Sparkline: View {
    let values: [Double]
    var median = false
    /// The scale's ends when the values do not set it: a rating always runs from 1 to 3.
    var domain: ClosedRange<Double>?
    /// The least the scale covers, around the values: 20 points for a share, so 30% to 32% does not fill the height.
    var minimumSpan: Double?

    private var scale: ClosedRange<Double> {
        if let domain { return domain }
        let low = values.min() ?? 0, high = values.max() ?? 1
        guard let minimumSpan, high - low < minimumSpan else { return low...max(high, low) }
        let middle = (low + high) / 2
        return (middle - minimumSpan / 2)...(middle + minimumSpan / 2)
    }

    var body: some View {
        Canvas { context, size in
            guard values.count >= 2 else { return }
            let low = scale.lowerBound, span = scale.upperBound - scale.lowerBound
            let inset: CGFloat = 3
            func y(_ value: Double) -> CGFloat {
                let part = span > 0 ? (value - low) / span : 0.5
                return inset + (size.height - inset * 2) * (1 - min(max(part, 0), 1))
            }
            func point(_ i: Int) -> CGPoint {
                CGPoint(x: inset + (size.width - inset * 2) * CGFloat(i) / CGFloat(values.count - 1), y: y(values[i]))
            }
            if median, span > 0 {
                // The earlier meetings only: this call is what the line is read against.
                let earlier = values.dropLast().sorted()
                let middle = earlier[earlier.count / 2]
                context.fill(Path(CGRect(x: 0, y: y(middle) - 0.5, width: size.width, height: 1)), with: .color(Palette.hairline))
            }
            var line = Path()
            line.move(to: point(0))
            for i in 1..<values.count { line.addLine(to: point(i)) }
            context.stroke(line, with: .color(Palette.accentFill), style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
            let last = point(values.count - 1)
            context.fill(Path(ellipseIn: CGRect(x: last.x - 3.5, y: last.y - 3.5, width: 7, height: 7)), with: .color(Palette.window))
            context.fill(Path(ellipseIn: CGRect(x: last.x - 2.5, y: last.y - 2.5, width: 5, height: 5)), with: .color(Palette.accentFill))
        }
        .accessibilityHidden(true)
    }
}

// MARK: Sentences with a person

/// A sentence that begins with a speaker: the name is a link (or "You"), the rest is text. The words follow the
/// name with the font's own word space and wrap under the name, as one line of text does. `size` is the font
/// size, which the caller also sets as the font; the color comes from the caller.
struct SpeakerSentence: View {
    let speaker: MeetingPeople.Speaker?
    let callID: String
    let text: String
    var size: CGFloat = 15

    var body: some View {
        if let speaker {
            // A word space of the system font is about a quarter of its size.
            FlowLayout(spacing: size * 0.26) {
                name(speaker)
                ForEach(Array(text.split(separator: " ").enumerated()), id: \.offset) { _, word in Text(word) }
            }
            // VoiceOver reads the link, then the sentence in one piece, not word by word.
            .accessibilityRepresentation {
                HStack {
                    name(speaker)
                    Text(text)
                }
            }
        } else {
            Text(text).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func name(_ speaker: MeetingPeople.Speaker) -> some View {
        SpeakerName(speaker: speaker, callID: callID, shown: speaker.isOwner ? "You" : nil).lineLimit(1).fixedSize()
    }
}

/// The finding that opens a group, about one speaker: the lede's weight, as `Finding`.
struct SpeakerFinding: View {
    let speaker: MeetingPeople.Speaker?
    let callID: String
    let text: String

    var body: some View {
        SpeakerSentence(speaker: speaker, callID: callID, text: text, size: 15)
            .font(.system(size: Rhythm.headingSize, weight: .medium))
            .foregroundStyle(Palette.ink)
            .accessibilityAddTraits(.isHeader)
    }
}

// MARK: Groups and tables

private struct AnalyticsWideKey: EnvironmentKey {
    static let defaultValue = true
}

extension EnvironmentValues {
    /// False when the tab is too narrow for the label column: the groups then put their label above.
    var analyticsWide: Bool {
        get { self[AnalyticsWideKey.self] }
        set { self[AnalyticsWideKey.self] = newValue }
    }
}

/// One group of the meeting's Analytics tab: the label column when the tab is wide, and the label above the
/// content (the label column's compact form) when it is not, so a table keeps its columns in a narrow window.
struct MeetingAnalyticsGroup<Content: View>: View {
    @Environment(\.analyticsWide) private var wide
    let label: String
    @ViewBuilder let content: Content

    init(_ label: String, @ViewBuilder content: () -> Content) {
        self.label = label
        self.content = content()
    }

    var body: some View {
        Group {
            if wide {
                LabelColumn(label: label, labelTopPadding: 4) { content }
            } else {
                VStack(alignment: .leading, spacing: Rhythm.itemGap) {
                    Text(label).textRole(.label).foregroundStyle(Palette.secondary).accessibilityAddTraits(.isHeader)
                    content.frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .id(label)
    }
}

/// A table with one row per speaker: the name with the speaker's color on the left, numbers in fixed columns on
/// the right, hairlines between rows, as the Analytics page's people table.
struct SpeakerTable: View {
    struct Column: Identifiable {
        let id: String
        let width: CGFloat
        let cell: (MeetingAnalytics.Speaker) -> AnyView

        init<Cell: View>(_ title: String, width: CGFloat, @ViewBuilder cell: @escaping (MeetingAnalytics.Speaker) -> Cell) {
            id = title
            self.width = width
            self.cell = { AnyView(cell($0)) }
        }
    }

    let speakers: [MeetingAnalytics.Speaker]
    let people: MeetingPeople
    let callID: String
    let columns: [Column]

    static let spacing: CGFloat = 12
    static let nameWidth: CGFloat = 130

    /// The least width the table needs, for picking the columns that fit.
    static func width(_ columns: [Column]) -> CGFloat {
        nameWidth + columns.reduce(0) { $0 + $1.width + spacing }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: Self.spacing) {
                Text("Name").frame(minWidth: Self.nameWidth, maxWidth: .infinity, alignment: .leading)
                ForEach(columns) { c in Text(c.id).lineLimit(1).frame(width: c.width, alignment: .trailing) }
            }
            .font(.system(size: Rhythm.noteSize))
            .foregroundStyle(Palette.tertiary)
            .padding(.bottom, 6)
            .hairline()
            .accessibilityHidden(true)
            ForEach(speakers) { s in
                HStack(spacing: Self.spacing) {
                    SpeakerCell(speaker: people.speaker(forKey: s.id), name: s.name, callID: callID)
                        .frame(minWidth: Self.nameWidth, maxWidth: .infinity, alignment: .leading)
                    ForEach(columns) { c in c.cell(s).frame(width: c.width, alignment: .trailing) }
                }
                .font(.system(size: Rhythm.bodySize)).monospacedDigit()
                .padding(.vertical, 7)
                .hairline()
            }
        }
    }
}

/// A speaker's color and name; the name opens the person, or names the voice.
struct SpeakerCell: View {
    let speaker: MeetingPeople.Speaker?
    let name: String
    let callID: String

    var body: some View {
        HStack(spacing: Space.s) {
            Circle().fill(speaker?.color ?? Palette.tertiaryMark).frame(width: 8, height: 8)
            Group {
                if let speaker { SpeakerName(speaker: speaker, callID: callID) } else { Text(name) }
            }
            .fontWeight(.medium)
            .lineLimit(1)
        }
    }
}

/// "–" in a cell with nothing to show.
struct NoValue: View {
    var body: some View {
        Text("–").foregroundStyle(Palette.tertiary).accessibilityLabel("No value")
    }
}
