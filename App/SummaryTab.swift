import MossadCore
import SwiftUI

/// The summary in the label column: the meeting in one line, decisions and bookmarks with their times, action
/// items, the overview, topics, talk share, and who was invited. A time plays from there.
struct SummaryTab: View {
    @EnvironmentObject var controller: AppController
    let record: CallRecord
    let people: MeetingPeople
    @ObservedObject var player: AudioPlayer
    /// Asks to delete the meeting, for a call where nobody spoke.
    var delete: (() -> Void)?

    var body: some View {
        if ProcessingStep(status: record.status) != nil {
            Skeleton()
        } else if record.status == .failed, record.summary == nil {
            EmptyState(symbol: "doc.text.magnifyingglass", title: "No transcript yet", message: failedMessage)
        } else if record.status == .written, record.utterances.isEmpty {
            EmptyState(symbol: "mic.slash", title: "No speech detected", message: "The call was recorded, but nobody spoke.",
                       action: delete.map { ("Delete…", $0) })
        } else {
            LabelColumnStack(spacing: Rhythm.sectionGap) {
                if let line = oneLine {
                    LabelColumn(label: "In one line", labelTopPadding: Self.leadLabelTop) {
                        Text(line).font(.system(size: Rhythm.leadSize, weight: .medium)).foregroundStyle(Palette.ink)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                    }
                }
                if !record.decisions.isEmpty {
                    LabelColumn(label: "Decisions", labelTopPadding: Self.labelTop) { decisions }
                }
                if !bookmarks.isEmpty {
                    LabelColumn(label: "Bookmarks", labelTopPadding: Self.labelTop) { bookmarkList }
                }
                // A meeting that only shared information has no action items at all.
                if record.summary != nil, record.hasOutcomes != false || !record.actionItems.isEmpty {
                    LabelColumn(label: "Action items", labelTopPadding: Self.labelTop) { actionItems }
                }
                if MeetingPointsGroup.hasContent(controller.series.book, callID: record.id) { MeetingPointsGroup(callID: record.id) }
                overview
                if !record.topics.isEmpty {
                    LabelColumn(label: "Topics", labelTopPadding: Self.labelTop) {
                        VStack(alignment: .leading, spacing: Rhythm.rowGap) {
                            ForEach(record.topics, id: \.self) { TopicRow(topic: $0) }
                        }
                    }
                }
                // Gemini's notes give words, not times: the share by words is on the Analytics tab.
                if !record.isNotesOnly, people.speakers.contains(where: { $0.seconds > 0 }) {
                    LabelColumn(label: "Talk share", labelTopPadding: 0) {
                        TalkShare(people: people).padding(.top, Self.barTop)
                    }
                }
                if !people.attendees.isEmpty {
                    LabelColumn(label: "Invited", labelTopPadding: Self.labelTop) { invited }
                }
            }
            .readingText()
            .foregroundStyle(Palette.ink)
            // The stack always exists, so the points book is read even when this meeting has no points yet.
            .loadsPoints()
        }
    }

    /// Moves each label down so its baseline meets the first line of its content.
    private static let labelTop = Rhythm.readingLabelOffset
    private static let leadLabelTop = Rhythm.labelOffset(toContent: Rhythm.leadSize, weight: .medium)
    /// The talk share's bar sits centered on the label's capitals.
    private static let barTop = max(0, Rhythm.capCenter(TextRole.label.size) - TalkShare.barHeight / 2)

    /// The summary's headline; an older meeting without one shows the overview's first sentence.
    private var oneLine: String? {
        record.headline?.nonEmpty ?? record.summary.flatMap { s in
            SummaryBlock.parse(s).lazy.compactMap { if case .paragraph(let p) = $0 { p } else { nil } }.first
        }.map(firstSentence)
    }

    /// The banner above says what failed and what to do; this only says what comes.
    private var failedMessage: String { "The transcript and the summary appear here after a retry works." }

    // MARK: Decisions and bookmarks

    private var decisions: some View {
        let current = player.time > 0
            ? record.decisions.indices.filter { (record.decisions[$0].at ?? .infinity) <= player.time }.max { record.decisions[$0].at! < record.decisions[$1].at! }
            : nil
        // Older meetings have no decision times: then the text starts at the column, with no empty gutter.
        let timed = record.decisions.contains { $0.at != nil }
        return VStack(alignment: .leading, spacing: Rhythm.rowGap) {
            ForEach(Array(record.decisions.enumerated()), id: \.offset) { i, d in
                TimedRow(at: d.at, strong: i == current, long: record.isLong, reserve: timed, player: player) {
                    Text(d.text).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .textSelection(.enabled)
    }

    private var bookmarks: [TranscriptMarker] { record.transcriptMarkers.filter(\.isBookmark) }

    private var bookmarkList: some View {
        VStack(alignment: .leading, spacing: Rhythm.rowGap) {
            ForEach(Array(bookmarks.enumerated()), id: \.offset) { _, b in
                TimedRow(at: b.offset, flag: true, long: record.isLong, player: player) {
                    if let note = b.note?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty {
                        Text(note).fixedSize(horizontal: false, vertical: true)
                    } else {
                        Text("Bookmark \(Text("· no note").font(Rhythm.secondary).foregroundStyle(Palette.tertiary))")
                            .foregroundStyle(Palette.secondary)
                    }
                }
            }
        }
    }

    // MARK: Action items

    @ViewBuilder
    private var actionItems: some View {
        if record.actionItems.isEmpty {
            Text("None.").foregroundStyle(Palette.secondary)
        } else {
            VStack(alignment: .leading, spacing: Rhythm.rowGap) {
                ForEach(record.actionItems, id: \.self) { item in
                    HStack(alignment: .firstTextBaseline, spacing: Space.m) {
                        // Centered on the first line's capitals.
                        Circle().strokeBorder(Palette.ring, lineWidth: 1.5).frame(width: 15, height: 15)
                            .alignmentGuide(.firstTextBaseline) { d in d[VerticalAlignment.center] + Rhythm.readingCapHalf }
                        ActionItemLine(item: item)
                    }
                }
            }
        }
    }

    // MARK: Overview

    @ViewBuilder
    private var overview: some View {
        if let summary = record.summary {
            LabelColumn(label: "Summary") {
                VStack(alignment: .leading, spacing: Rhythm.blockGap) {
                    ForEach(Array(SummaryBlock.parse(summary).enumerated()), id: \.offset) { _, block in
                        switch block {
                        case .paragraph(let text): inline(text)
                        case .heading(let text): Text(text).font(.system(size: Rhythm.readingSize, weight: .semibold))
                        case .bullets(let items):
                            VStack(alignment: .leading, spacing: Rhythm.rowGap) {
                                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                                    HStack(alignment: .firstTextBaseline, spacing: Space.s) {
                                        Text("•").foregroundStyle(Palette.tertiary)
                                        inline(item)
                                    }
                                }
                            }
                        }
                    }
                }
                .frame(maxWidth: Rhythm.measure, alignment: .leading)
                .textSelection(.enabled)
            }
        } else if record.status == .written {
            LabelColumn(label: "Summary") {
                HStack {
                    let model = controller.hasLanguageModel
                    Text(!model ? (controller.aiProvider.requiresKey ? "No summary for this meeting. Add the \(controller.aiProvider.displayName) key in Settings."
                                   : "No summary for this meeting. Choose a model in Settings.")
                         : record.summaryMissing == true ? "The summary failed" + (record.failureReason.map { ": \($0)." } ?? ".") + " Mossad tries again once a day."
                         : "No summary for this meeting.")
                        .foregroundStyle(Palette.secondary)
                    Spacer()
                    // `retry` does nothing for a written meeting; a new summary needs a model.
                    if model { Button("Retry summary") { controller.regenerateSummary(record.id) } }
                }
            }
        }
    }

    // MARK: Invited

    private var invited: some View {
        VStack(alignment: .leading, spacing: Rhythm.rowGap) {
            ForEach(Array(people.attendees.enumerated()), id: \.offset) { _, a in
                HStack(alignment: .firstTextBaseline, spacing: Space.s) {
                    PersonName(a.email ?? a.name, shown: a.name).lineLimit(1)
                    if let email = a.email { Text(email).font(Rhythm.secondary).foregroundStyle(Palette.secondary).lineLimit(1) }
                }
            }
        }
        .textSelection(.enabled)
    }
}

/// An action item with its owner after it. The owner is a link of its own when it stands for a saved person, on
/// the task's line when both fit and under the task when they do not.
private struct ActionItemLine: View {
    let item: ActionItem

    var body: some View {
        if let owner = item.owner {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline, spacing: Space.s) {
                    Text(item.task).lineLimit(1).textSelection(.enabled)
                    name(owner)
                }
                VStack(alignment: .leading, spacing: Rhythm.pairGap) {
                    Text(item.task).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                    name(owner, dot: false)
                }
            }
        } else {
            Text(item.task).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
        }
    }

    private func name(_ owner: String, dot: Bool = true) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Space.xs) {
            if dot { Text("·").accessibilityHidden(true) }
            PersonName(owner, shown: shortName(owner)).lineLimit(1)
        }
        .font(Rhythm.secondary)
        .foregroundStyle(Palette.secondary)
        .fixedSize()
    }
}

extension CallRecord {
    /// An hour or more: times read "1:42:33" and need a wider column.
    var isLong: Bool { end.timeIntervalSince(start) >= 3600 || (utterances.last?.end ?? 0) >= 3600 }
}

func inline(_ text: String) -> Text {
    let attributed = (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text)
    return Text(attributed).font(Rhythm.reading)
}

/// A time in a 44 pt column, then the text. The time plays from there; no time leaves the column empty.
struct TimedRow<Content: View>: View {
    let at: TimeInterval?
    var strong = false
    var flag = false
    /// Room for "1:42:33" in a meeting of an hour or more.
    var long = false
    /// Keeps the time column when this row has no time, so it lines up with rows that do.
    var reserve = true
    @ObservedObject var player: AudioPlayer
    @ViewBuilder let content: Content

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: at == nil && !reserve ? 0 : Space.m) {
            Group {
                if let at {
                    Button { player.play(from: at) } label: {
                        HStack(spacing: 5) {
                            if flag { BookmarkFlag().fill(Palette.accentFill).frame(width: 7, height: 9) }
                            Text(long ? longClock(at) : clock(at))
                        }
                        .font(.system(size: Rhythm.secondarySize, weight: strong ? .semibold : .regular)).monospacedDigit()
                        .foregroundStyle(strong ? Palette.ink : Palette.tertiary)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(!player.isAvailable)
                    .help(player.isAvailable ? "Play from \(clock(at))" : "The audio is not available")
                } else if reserve {
                    Text(" ").font(Rhythm.secondary)
                }
            }
            .frame(width: at == nil && !reserve ? 0 : (flag ? 14 : 0) + (long ? 54 : 44), alignment: .leading)
            content.frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// Everyone's share of the talk as one bar in their hues, then the few who talked most in words.
struct TalkShare: View {
    let people: MeetingPeople
    static let barHeight: CGFloat = 8

    var body: some View {
        let talkers = people.speakers.filter { $0.seconds > 0 }
        let total = max(talkers.reduce(0) { $0 + $1.seconds }, 1)
        VStack(alignment: .leading, spacing: Rhythm.readingLineGap) {
            GeometryReader { g in
                let gaps = CGFloat(max(talkers.count - 1, 0))
                let width = max(g.size.width - gaps, 0)
                HStack(spacing: 1) {
                    ForEach(talkers, id: \.key) { s in
                        Rectangle().fill(s.color).frame(width: width * s.seconds / total)
                    }
                }
            }
            .frame(height: Self.barHeight)
            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
            .frame(maxWidth: 520)
            .accessibilityHidden(true)
            caption(talkers, total: total).font(Rhythm.secondary).foregroundStyle(Palette.secondary)
        }
    }

    /// "You 36% · Sam 16% · Dana 13% · nine others share the rest". Each name opens its person.
    private func caption(_ talkers: [MeetingPeople.Speaker], total: TimeInterval) -> some View {
        func percent(_ s: MeetingPeople.Speaker) -> String { "\(Int((s.seconds / total * 100).rounded()))%" }
        let owner = talkers.first(where: \.isOwner)
        let others = talkers.filter { !$0.isOwner }.sorted { $0.seconds > $1.seconds }
        let named = (owner.map { [$0] } ?? []) + others.prefix(owner == nil ? 3 : 2)
        let rest = others.count - (named.count - (owner == nil ? 0 : 1))
        let word = rest <= 12 ? (NumberFormatter.localizedString(from: rest as NSNumber, number: .spellOut)) : "\(rest)"
        return FlowLayout(spacing: 4) {
            ForEach(Array(named.enumerated()), id: \.element.key) { i, s in
                HStack(spacing: 4) {
                    if i > 0 { Text("·").accessibilityHidden(true) }
                    PersonName(s.name, shown: s.isOwner ? "You" : firstName(s.name), person: .some(s.person))
                    Text(percent(s)).monospacedDigit()
                }
            }
            if rest > 0 { Text(rest == 1 ? "· one other has the rest" : "· \(word) others share the rest") }
        }
    }
}

/// One topic of the summary, collapsed until clicked.
private struct TopicRow: View {
    let topic: SummaryTopic
    @State private var open = false

    var body: some View {
        VStack(alignment: .leading, spacing: Rhythm.readingLineGap) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) { open.toggle() }
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: Space.s - 2) {
                    Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold))
                        .rotationEffect(.degrees(open ? 90 : 0)).foregroundStyle(Palette.tertiaryMark).frame(width: 12)
                        .alignmentGuide(.firstTextBaseline) { d in d[VerticalAlignment.center] + Rhythm.readingCapHalf }
                    Text(topic.title).font(.system(size: Rhythm.readingSize, weight: .medium)).foregroundStyle(Palette.ink)
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if open {
                VStack(alignment: .leading, spacing: Rhythm.rowGap) {
                    ForEach(Array(SummaryBlock.parse(topic.summary).enumerated()), id: \.offset) { _, block in
                        switch block {
                        case .paragraph(let text), .heading(let text): inline(text)
                        case .bullets(let items):
                            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                                HStack(alignment: .firstTextBaseline, spacing: Space.s) {
                                    Text("•").foregroundStyle(Palette.tertiary)
                                    inline(item)
                                }
                            }
                        }
                    }
                }
                .padding(.leading, Self.indent)
                .frame(maxWidth: Rhythm.measure, alignment: .leading)
                .textSelection(.enabled)
            }
        }
    }

    /// The chevron's column and its gap, so the topic's text lines up under its title.
    private static let indent: CGFloat = 12 + Space.s - 2
}

private struct Skeleton: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 10) {
            card(header: 60, lines: [0.96, 0.88, 0.92, 0.6])
            HStack(alignment: .top, spacing: 10) {
                card(header: 80, lines: [0.9, 0.8, 0.7])
                card(header: 70, lines: [0.85, 0.75, 0.6])
            }
        }
        .padding(.top, 6)
        .phaseAnimator(reduceMotion ? [0.7] : [0.5, 1.0]) { view, phase in
            view.opacity(phase)
        } animation: { _ in .easeInOut(duration: 0.8) }
    }

    private func card(header: CGFloat, lines: [CGFloat]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            RoundedRectangle(cornerRadius: 3).fill(Palette.fill).frame(width: header, height: 9)
            GeometryReader { g in
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(lines.enumerated()), id: \.offset) { _, w in
                        RoundedRectangle(cornerRadius: 3).fill(Palette.fill).frame(width: g.size.width * w, height: 10)
                    }
                }
            }
            .frame(height: CGFloat(lines.count) * 18)
        }
        .padding(.horizontal, 16).padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}
