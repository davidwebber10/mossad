import MossadCore
import SwiftUI

// MARK: Shared parts

/// A moment of an earlier meeting: it opens that meeting and plays from there, as the Analytics tab's moments do.
private struct PrepMoment: View {
    @EnvironmentObject var controller: AppController
    let callID: String
    let at: TimeInterval

    var body: some View {
        Button { controller.openMeeting(callID, at: at) } label: {
            HStack(spacing: 5) {
                IconImage(.play, size: 8)
                Text(clock(at)).monospacedDigit()
            }
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(Palette.accent)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .fixedSize()
        .help("Open the meeting and play from \(clock(at))")
        .accessibilityLabel("Play from \(clock(at))")
    }
}

/// "and 3 more" with where they are, in the accent with a chevron, as the Analytics tab's "Profile".
private struct PrepMore: View {
    let text: String
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 3) {
                Text(text)
                IconImage(.chevronRight, size: 9)
            }
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(Palette.accent)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityAddTraits(.isLink)
        .accessibilityRemoveTraits(.isButton)
    }
}

/// One open item or task: a mark, what it is with who it is for or whose it is, where it comes from, when it is
/// due, and its moment. A task of the owner's has the ring that marks it done; an action item has no state to
/// change, so its mark is a quiet dot.
private struct PrepRow<Who: View>: View {
    @EnvironmentObject var controller: AppController
    let text: String
    var commitment: Commitment?
    /// Under the text: "Dana / Sam, Oct 13".
    var source: String?
    var moment: (callID: String, at: TimeInterval)?
    /// After the text: "· Sam C.", "· for Jo". On a line of its own, when both do not fit, it has no dot.
    @ViewBuilder var who: (_ dot: Bool) -> Who

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            mark
            VStack(alignment: .leading, spacing: 1) {
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .firstTextBaseline, spacing: 5) {
                        Text(text).lineLimit(1).textSelection(.enabled)
                        who(true).foregroundStyle(Palette.secondary).fixedSize()
                    }
                    VStack(alignment: .leading, spacing: 1) {
                        Text(text).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                        who(false).font(.system(size: 12)).foregroundStyle(Palette.secondary)
                    }
                }
                if let source { Text(source).font(.system(size: 12)).foregroundStyle(Palette.tertiary).lineLimit(1) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            HStack(alignment: .firstTextBaseline, spacing: Space.m) {
                if let commitment { CommitmentDue(commitment: commitment) }
                if let moment { PrepMoment(callID: moment.callID, at: moment.at).padding(.top, 1) }
            }
        }
    }

    @ViewBuilder
    private var mark: some View {
        if let commitment {
            CommitmentRing(commitment: commitment) { controller.toggleDone(commitment.id) }
                .help("Mark this task done")
        } else {
            Circle().strokeBorder(Palette.ring, lineWidth: 1.5).frame(width: 8, height: 8)
                .frame(width: 16, height: 16).padding(.top, 1)
                .help("An action item has no state of its own: Mossad cannot know whether this one is done.")
                .accessibilityHidden(true)
        }
    }
}

// MARK: Last time

/// The last meeting of the series (or, with no series, with these people): its one line, its decisions, and the
/// action items that are still open, each with its owner and its moment.
struct PrepLastTime: View {
    @EnvironmentObject var controller: AppController
    let last: MeetingPrep.LastTime

    var body: some View {
        MeetingAnalyticsGroup("Last time") {
            VStack(alignment: .leading, spacing: 5) {
                if let headline = last.headline {
                    Text(headline).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                }
                FlowLayout(spacing: 6) {
                    Text(last.inSeries ? dayWord(last.meeting.start) : "\(last.meeting.title) · \(dayWord(last.meeting.start))")
                        .font(.system(size: 12)).foregroundStyle(Palette.secondary).lineLimit(1)
                    PrepMore(text: "Open the meeting", help: "Open \(last.meeting.title)") { controller.openMeeting(last.meeting.id) }
                }
            }
        }
        if !last.decisions.isEmpty {
            MeetingAnalyticsGroup("Decisions") {
                VStack(alignment: .leading, spacing: 7) {
                    let timed = last.decisions.contains { $0.at != nil }
                    ForEach(Array(last.decisions.enumerated()), id: \.offset) { _, d in
                        HStack(alignment: .firstTextBaseline, spacing: timed ? 10 : 0) {
                            Group {
                                if let at = d.at {
                                    Button { controller.openMeeting(last.meeting.id, at: at) } label: {
                                        Text(clock(at)).font(.system(size: 12)).monospacedDigit().foregroundStyle(Palette.tertiary).contentShape(Rectangle())
                                    }
                                    .buttonStyle(.plain)
                                    .help("Open the meeting and play from \(clock(at))")
                                    .accessibilityLabel("Play from \(clock(at))")
                                }
                            }
                            .frame(width: timed ? 44 : 0, alignment: .leading)
                            Text(d.text).fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    if last.moreDecisions > 0 {
                        PrepMore(text: "and \(last.moreDecisions) more", help: "Open \(last.meeting.title)") { controller.openMeeting(last.meeting.id) }
                            .padding(.leading, timed ? 54 : 0)
                    }
                }
                .textSelection(.enabled)
            }
        }
        if !last.items.isEmpty {
            MeetingAnalyticsGroup("Open items") {
                VStack(alignment: .leading, spacing: 7) {
                    ForEach(last.items) { item in
                        PrepRow(text: item.task, commitment: item.commitment, moment: item.at.map { (item.callID, $0) }) { dot in
                            if item.isOwners {
                                Text(dot ? "· You" : "You")
                            } else if let owner = item.owner {
                                HStack(spacing: 5) {
                                    if dot { Text("·").accessibilityHidden(true) }
                                    PersonName(owner, shown: shortName(owner), person: .some(item.person)).lineLimit(1)
                                }
                            }
                        }
                    }
                    if last.moreItems > 0 {
                        PrepMore(text: "and \(last.moreItems) more", help: "Open \(last.meeting.title)") { controller.openMeeting(last.meeting.id) }
                            .padding(.leading, 26)
                    }
                }
            }
        }
    }
}

// MARK: Promises

/// The owner's open tasks for the people of this meeting, oldest first.
struct PrepPromises: View {
    @EnvironmentObject var controller: AppController
    let promises: [MeetingPrep.Promise]
    let more: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            ForEach(promises) { p in
                let c = p.commitment
                PrepRow(text: c.text, commitment: c, source: c.sourceText, moment: c.callID.flatMap { id in c.at.map { (id, $0) } }) { dot in
                    if let to = c.to {
                        HStack(spacing: 5) {
                            Text(dot ? "· for" : "For")
                            PersonName(to, shown: shortName(to), person: .some(p.person)).lineLimit(1)
                        }
                    }
                }
            }
            if more > 0 {
                PrepMore(text: "and \(more) more", help: "Open Tasks") { controller.open(.commitments) }
                    .padding(.leading, 26)
            }
        }
    }
}

// MARK: The series

/// The earlier meetings with this title in numbers: how often, how long, against the invite, and the owner's
/// part of the talk. A number the history cannot give has no tile.
struct PrepSeries: View {
    @EnvironmentObject var controller: AppController
    @Environment(\.analyticsWide) private var wide
    let series: MeetingPrep.Series
    /// The planned length of this invite.
    let planned: TimeInterval

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Finding("Met \(series.meetings) times since \(series.since.formatted(.dateTime.month(.abbreviated).day())); this one is planned for \(durationLabel(planned)).")
            let tiles = self.tiles
            if !tiles.isEmpty {
                Grid(alignment: .topLeading, horizontalSpacing: 24, verticalSpacing: 18) {
                    let perRow = wide ? 4 : 2
                    ForEach(Array(stride(from: 0, to: tiles.count, by: perRow)), id: \.self) { start in
                        GridRow {
                            ForEach(start..<min(start + perRow, tiles.count), id: \.self) { tiles[$0] }
                        }
                    }
                }
            }
            if !series.earlier.isEmpty { earlier.padding(.top, 4) }
        }
    }

    /// The meetings before the last one, each in one line that opens it.
    private var earlier: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(series.earlier) { m in
                Button { controller.openMeeting(m.id) } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text(shortDay(m.start)).font(.system(size: 12)).monospacedDigit().foregroundStyle(Palette.tertiary).frame(width: 64, alignment: .leading)
                        Text(m.line).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(.vertical, 6)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .hairline()
                .help("Open this meeting")
            }
            if series.moreEarlier > 0 {
                Text("and \(series.moreEarlier) earlier").font(.system(size: 12)).foregroundStyle(Palette.tertiary).padding(.top, 7)
            }
        }
        .hairline(.top)
    }

    private var tiles: [SeriesTile] {
        var out: [SeriesTile] = []
        if let u = series.length {
            out.append(SeriesTile(title: "Usual length", value: hours(u.median), detail: usual(MeetingFindings.range(.length, u), u),
                                  line: series.lengths, span: nil))
        }
        if let u = series.ownerShare {
            out.append(SeriesTile(title: "Your talk share", value: percentText(u.median), detail: usual(MeetingFindings.range(.talkShare, u), u), line: series.shares, span: 0.2))
        }
        if series.planned > 0 {
            // The recording begins when the owner joins and ends when the owner leaves.
            out.append(SeriesTile(title: "Ran past the plan", value: "\(series.ranOver) of \(series.planned)", detail: "by 5 min or more", line: [], span: nil))
            out.append(SeriesTile(title: "You joined late", value: "\(series.joinedLate) of \(series.planned)", detail: "by 5 min or more", line: [], span: nil))
        }
        return out
    }

    /// "Usually" needs five meetings; fewer are "so far".
    private func usual(_ range: String, _ u: MeetingAnalytics.Usual) -> String {
        u.isFirm ? "usually \(range)" : "\(range) in \(u.samples) meetings so far"
    }
}

/// One number of the series with its line over the last meetings, as the Analytics tab's trend figures.
private struct SeriesTile: View {
    let title: String
    let value: String
    let detail: String
    let line: [Double]
    let span: Double?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.system(size: 12)).foregroundStyle(Palette.secondary).lineLimit(1)
            Text(value).font(.system(size: 20, weight: .semibold)).tracking(-0.4).monospacedDigit().lineLimit(1)
            Text(detail).font(.system(size: 11.5)).foregroundStyle(Palette.tertiary).fixedSize(horizontal: false, vertical: true)
            if line.count >= MeetingAnalytics.Trends.minimumPoints {
                Sparkline(values: line, median: true, minimumSpan: span)
                    .frame(height: 30)
                    .padding(.top, 6)
                    .help("The last \(line.count) meetings, oldest first. The dot is the last one.")
            }
        }
        .padding(.top, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .hairline(.top)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title), \(value), \(detail)")
    }
}
