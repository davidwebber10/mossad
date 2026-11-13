import MossadCore
import SwiftUI

/// The coach's read on one person as prose, as the Mac's profile sets it: the headline in the lede step, where it
/// came from, then each of the coach's sections as a label over one paragraph. No card around it.
struct PersonBriefCard: View {
    let name: String
    let brief: PersonBrief?
    /// How many calls the owner has had with them, for the line shown before the first read.
    var calls = 0
    var refreshing = false
    var refresh: (() -> Void)?

    private var first: String { name.split(separator: " ").first.map(String.init) ?? name }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            LabelColumn(label: "The coach’s read") {
                VStack(alignment: .leading, spacing: Rhythm.pairGap) {
                    if let brief {
                        Text(brief.headline)
                            .textRole(.lede).lineSpacing(Rhythm.secondaryLineGap)
                            .foregroundStyle(Palette.ink)
                            .fixedSize(horizontal: false, vertical: true)
                        HStack(spacing: Space.s) {
                            Text("From \(brief.calls) \(brief.calls == 1 ? "call" : "calls") · updated \(brief.updated.formatted(.relative(presentation: .named)))")
                            refreshButton
                        }
                        .textRole(.secondary).foregroundStyle(Palette.tertiary)
                    } else {
                        Text(calls >= 2
                             ? "The coach has not read the calls with \(first) yet."
                             : "After two calls with \(first), the coach writes how to work with them: their goals, how to get through to them, and how they communicate.")
                            .textRole(.body).foregroundStyle(Palette.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            if let brief {
                ForEach(brief.sections, id: \.title) { section in
                    LabelColumn(label: section.title) { prose(section.points) }
                }
            }
        }
        .textSelection(.enabled)
    }

    @ViewBuilder
    private var refreshButton: some View {
        if let refresh {
            if refreshing {
                Text("Reading…")
            } else {
                Button("Read again", action: refresh).buttonStyle(.plain).foregroundStyle(Palette.accent)
            }
        }
    }

    /// The points as one paragraph; a point from a call ends in a quiet link that opens it.
    private func prose(_ points: [PersonBrief.Point]) -> some View {
        var text = AttributedString()
        for (i, point) in points.enumerated() {
            if i > 0 { text += AttributedString(" ") }
            text += AttributedString(point.text)
            if let id = point.callID, let url = URL(string: "mossad://call/\(id)") {
                var link = AttributedString(" ↗")
                link.link = url
                link.foregroundColor = Palette.tertiary
                text += link
            }
        }
        return Text(text)
            .textRole(.body).lineSpacing(Rhythm.secondaryLineGap)
            .foregroundStyle(Palette.ink)
            .tint(Palette.tertiary)
            .fixedSize(horizontal: false, vertical: true)
    }
}
