import MossadCore
import SwiftUI

/// "How to present to them": the card that code builds from the shown traits. On a page each line has its label
/// in the label column; in the prep page's narrow column (`compact`) the labels stand over the lines. Under each
/// line: the strongest trait's words and counts ("Likely, seen in 3 of 4 calls") and a link that plays its moment.
struct PersonaCardView: View {
    let card: PersonaCard
    /// The first name, for the title.
    let first: String
    var compact = false

    var body: some View {
        if compact {
            VStack(alignment: .leading, spacing: Rhythm.itemGap) {
                ForEach(card.lines) { line in
                    VStack(alignment: .leading, spacing: Rhythm.pairGap) {
                        Text(line.kind.title).textRole(.label).foregroundStyle(Palette.secondary)
                        Text(line.text).textRole(.body).foregroundStyle(Palette.ink).fixedSize(horizontal: false, vertical: true)
                        PersonaEvidenceLine(text: line.confidenceLine, moment: line.moment)
                    }
                }
            }
            .textSelection(.enabled)
        } else {
            // The headline is the opening line's words: it stands once, with that line's counts.
            let lead = card.lines.first { $0.text == card.headline }
            VStack(alignment: .leading, spacing: Rhythm.groupGap) {
                LabelColumn(label: "How to present to \(first)") {
                    VStack(alignment: .leading, spacing: Rhythm.pairGap) {
                        Text(card.headline).textRole(.lede).lineSpacing(Rhythm.secondaryLineGap).foregroundStyle(Palette.ink).fixedSize(horizontal: false, vertical: true)
                        if let lead { PersonaEvidenceLine(text: lead.confidenceLine, moment: lead.moment) }
                    }
                }
                ForEach(card.lines.filter { $0.id != lead?.id }) { line in
                    LabelColumn(label: line.kind.title) {
                        VStack(alignment: .leading, spacing: Rhythm.pairGap) {
                            Text(line.text).textRole(.body).lineSpacing(Rhythm.secondaryLineGap).foregroundStyle(Palette.ink)
                                .frame(maxWidth: Rhythm.measure, alignment: .leading).fixedSize(horizontal: false, vertical: true)
                            PersonaEvidenceLine(text: line.confidenceLine, moment: line.moment)
                        }
                    }
                }
            }
            .textSelection(.enabled)
        }
    }
}

/// "Likely, seen in 3 of 4 calls · Play": the hedge is the count, and the moment is one click away.
struct PersonaEvidenceLine: View {
    let text: String
    let moment: PersonaPointer?

    var body: some View {
        HStack(spacing: Space.s) {
            Text(text.prefix(1).uppercased() + text.dropFirst())
            if let url = moment?.link {
                Text("·").accessibilityHidden(true)
                Link(destination: url) { Label("Play", systemImage: "play.fill").labelStyle(.titleAndIcon) }
                    .foregroundStyle(Palette.accent)
                    .accessibilityLabel("Play the moment")
            }
        }
        .textRole(.secondary).foregroundStyle(Palette.tertiary)
    }
}

/// "How they think": each shown trait with its label, its counts, its number, its moments, and what goes against
/// it, then how many things were seen in one call only.
struct PersonaTraitsView: View {
    let read: PersonaSummary
    /// The start of a call, for the moments' dates.
    let date: (String) -> Date?

    var body: some View {
        LabelColumn(label: "How they think") {
            VStack(alignment: .leading, spacing: Rhythm.rowGap) {
                ForEach(read.traits) { trait in
                    VStack(alignment: .leading, spacing: Rhythm.pairGap) {
                        Text(trait.statement).textRole(.body).foregroundStyle(Palette.ink)
                            .frame(maxWidth: Rhythm.measure, alignment: .leading).fixedSize(horizontal: false, vertical: true)
                        HStack(spacing: Space.s) {
                            Text(trait.confidenceLine.prefix(1).uppercased() + trait.confidenceLine.dropFirst())
                            Text("·").accessibilityHidden(true)
                            // The number lives here, in the trait's detail; the card says it in words.
                            Text("confidence \(trait.numberText)").monospacedDigit()
                                .help("Computed by code from the calls for and against, the topics, and your answers. A trait shows at 0.70 or more until your answers in Findings move that bound.")
                            if let c = trait.condition { Text("·").accessibilityHidden(true); Text(c.words) }
                        }
                        .textRole(.secondary).foregroundStyle(Palette.tertiary)
                        FlowLayout(spacing: 10) {
                            ForEach(trait.moments, id: \.self) { m in moment(m, prefix: "") }
                            ForEach(trait.counter, id: \.self) { m in moment(m, prefix: "But on ") }
                        }
                        .textRole(.secondary)
                    }
                }
                if read.oneCall > 0 {
                    Text("\(read.oneCall) more \(read.oneCall == 1 ? "thing" : "things") seen in one call. One call never shows.")
                        .textRole(.secondary).foregroundStyle(Palette.tertiary)
                }
            }
        }
        .textSelection(.enabled)
    }

    @ViewBuilder
    private func moment(_ p: PersonaPointer, prefix: String) -> some View {
        if let url = p.link {
            // The year when it is not this year: an old trait must not look new.
            let day = date(p.callID).map { d in
                Calendar.current.isDate(d, equalTo: Date(), toGranularity: .year) ? d.formatted(.dateTime.month(.abbreviated).day())
                    : d.formatted(.dateTime.month(.abbreviated).day().year())
            } ?? "a call"
            Link(destination: url) {
                Label(prefix.isEmpty ? day : "\(prefix)\(day)", systemImage: prefix.isEmpty ? "play.circle" : "arrow.uturn.left.circle")
            }
            .foregroundStyle(prefix.isEmpty ? Palette.accent : Palette.secondary)
            .help(prefix.isEmpty ? "Play the moment" : "Play a moment that goes against it")
        }
    }
}

/// The closed row while the owner shares the screen or records a call with the person. One click opens it.
struct PersonaCoverRow: View {
    var why = "hidden while you share or record a call with them"
    let open: () -> Void

    var body: some View {
        Button(action: open) {
            HStack(spacing: Space.s) {
                Image(systemName: "eye.slash").foregroundStyle(Palette.tertiary)
                Text("The coach’s read (\(why))").foregroundStyle(Palette.secondary)
                Spacer(minLength: 8)
                Text("Show").foregroundStyle(Palette.accent)
            }
            .textRole(.body)
            .padding(.horizontal, 12).padding(.vertical, 9)
            .background(Palette.fill, in: RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .frame(maxWidth: Rhythm.measure, alignment: .leading)
        .accessibilityLabel("The coach’s read is hidden. Show it")
    }
}
