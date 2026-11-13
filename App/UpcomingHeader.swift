import AppKit
import MossadCore
import SwiftUI

/// The band at the top of an upcoming meeting, laid out as `MeetingHeader`: where and when, the title, and the
/// time until the start where a recorded meeting has its length. The invited people stand where the lanes are,
/// each with what Mossad knows of them, and the record choice and Join where the player's controls are.
struct UpcomingHeader: View {
    @EnvironmentObject var controller: AppController
    let meeting: UpcomingMeeting
    let invited: [MeetingPrep.Invited]
    /// Nil until the page's numbers are made: the people then show with their names only.
    let prep: MeetingPrep?
    var wide = true
    var maxRows = 8
    @State private var showAll = false

    var body: some View {
        // Every 15 s, so the time until the start moves and Join comes within the last minute before it.
        TimelineView(.periodic(from: .now, by: 15)) { context in
            let left = meeting.start.timeIntervalSince(context.date)
            VStack(alignment: .leading, spacing: 0) {
                meta
                HStack(alignment: .lastTextBaseline, spacing: Space.xl) {
                    Text(meeting.title)
                        .font(.system(size: Detail.titleSize, weight: .semibold)).tracking(Detail.titleSize * -0.02)
                        .foregroundStyle(Palette.ink)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.vertical, 2)
                        .frame(maxWidth: Detail.titleMax, alignment: .leading)
                        .textSelection(.enabled)
                        .accessibilityAddTraits(.isHeader)
                    Spacer(minLength: 0)
                    Text(meeting.startsIn(now: context.date))
                        .font(.system(size: Detail.titleSize, weight: .semibold)).tracking(Detail.titleSize * -0.02).monospacedDigit()
                        .foregroundStyle(left < 600 ? Palette.accent : Palette.secondary)
                        .fixedSize()
                        .accessibilityLabel(left <= 0 ? "Started" : "Starts \(meeting.startsIn(now: context.date))")
                }
                .padding(.top, 6)
                if !invited.isEmpty { people.padding(.top, 30) }
                controls(joinable: left <= 60).padding(.top, invited.isEmpty ? 24 : 16)
            }
            .bandColumn()
            .padding(.vertical, Detail.bandPadding)
            .bandFrame()
            .background(Palette.band)
            .hairline(.bottom)
        }
    }

    // MARK: Where and when

    private var meta: some View {
        FlowLayout(spacing: Space.s) {
            HStack(spacing: Space.s) {
                if let p = meeting.platform {
                    PlatformDot(platform: p, hollow: true)
                } else {
                    Circle().strokeBorder(Palette.ring, lineWidth: 1.5).frame(width: 8, height: 8)
                }
                Text(when).font(.system(size: 12)).foregroundStyle(Palette.secondary).lineLimit(1)
            }
            .frame(minHeight: 20)
            if let kind = prep?.kind { TagChip(text: kind) }
            if let n = prep?.series?.meetings {
                TagChip(text: "Recorded \(n) times").help("Mossad recorded \(n) earlier meetings of this series")
            }
        }
    }

    /// "Google Meet · Today, 4:30 – 5:00 PM · 30 min".
    private var when: String {
        let range = (meeting.start..<max(meeting.end, meeting.start)).formatted(.interval.hour().minute())
        let parts = [meeting.platform?.displayName, "\(Self.day(meeting.start)), \(range)", durationLabel(meeting.end.timeIntervalSince(meeting.start))]
        return parts.compactMap { $0 }.joined(separator: " · ")
    }

    /// "Today", "Tomorrow", else the weekday with the date.
    static func day(_ date: Date) -> String { UpcomingMeeting.dayTitle(date) }

    // MARK: The people

    /// The first people that fit; "and N more invited" shows them all. The band does not scroll, so the whole
    /// list scrolls inside the room the first ones had, and the controls under it stay in the window.
    private var people: some View {
        let fits = invited.count > maxRows ? maxRows - 1 : maxRows
        let known = Dictionary((prep?.people ?? []).map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
        func rows(_ entries: [MeetingPrep.Invited]) -> some View {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(entries) { entry in
                    InvitedRow(entry: entry, person: entry.person.flatMap { known[$0] }, loaded: prep != nil, wide: wide)
                }
            }
        }
        return VStack(alignment: .leading, spacing: 6) {
            if showAll, invited.count > fits {
                ScrollView(.vertical) { rows(invited) }
                    .frame(height: CGFloat(maxRows) * UpcomingDetailView.personRow)
            } else {
                rows(Array(invited.prefix(fits)))
            }
            if invited.count > fits {
                Button { withAnimation(.snappy(duration: 0.2)) { showAll.toggle() } } label: {
                    Text(showAll ? "Show fewer" : "and \(invited.count - fits) more invited")
                        .font(.system(size: 12, weight: .semibold)).foregroundStyle(Palette.secondary)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.leading, wide ? Detail.labelGutter : 0)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Invited")
    }

    // MARK: Record and join

    /// Join only when the call is about to start or running; before that, the line says when it comes.
    private func controls(joinable: Bool) -> some View {
        HStack(spacing: Space.m) {
            if meeting.platform != nil { RecordChoiceControl(meeting: meeting, size: .regular) }
            if let link = meeting.link {
                if joinable {
                    Button { NSWorkspace.shared.open(link) } label: {
                        Text("Join \(meeting.platform?.displayName ?? "the call")")
                            .font(.system(size: 12.5, weight: .semibold))
                            .foregroundStyle(Palette.onAccent)
                            .padding(.horizontal, 14)
                            .frame(height: 28)
                            .background(Palette.accentFill, in: Capsule())
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .help("Open the call")
                } else {
                    Text("Join shows here a minute before the start.")
                        .font(.system(size: 12)).foregroundStyle(Palette.tertiary).lineLimit(1)
                }
            } else {
                Text("This invite has no call link.").font(.system(size: 12)).foregroundStyle(Palette.tertiary).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.leading, wide && !invited.isEmpty ? Detail.labelGutter : 0)
    }
}

/// One invited person as a lane of the band: the name in the label column (a link on a sure match), then when
/// the two were last recorded together, how often in the last 90 days, and one fact about the two. It says
/// "recorded": a meeting where the person was silent or their voice has no name is not in these numbers.
private struct InvitedRow: View {
    @EnvironmentObject var controller: AppController
    let entry: MeetingPrep.Invited
    let person: MeetingPrep.Person?
    let loaded: Bool
    let wide: Bool

    /// In a narrow window the names start at the gutter, as the page's labels do, in a column that leaves the
    /// facts their line.
    private static let narrowName: CGFloat = 112

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Detail.labelGap) {
            name.frame(width: wide ? Detail.labelColumn : Self.narrowName, alignment: wide ? .trailing : .leading)
            facts.frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var name: some View {
        PersonName(entry.name, person: .some(entry.person))
            .font(.system(size: 13))
            .foregroundStyle(entry.person == nil ? Palette.secondary : Palette.ink)
            .lineLimit(1)
            // A long address keeps its start, which names the person; the whole entry is the tooltip.
            .help(entry.person == nil ? entry.written : "")
    }

    /// One text, so it wraps at any width: when they were last recorded together (a link to that meeting), how
    /// often, and the fact.
    @ViewBuilder
    private var facts: some View {
        Group {
            if let person {
                if let last = person.lastMet {
                    Text(Self.line(person, last))
                        .tint(Palette.ink)
                        .fixedSize(horizontal: false, vertical: true)
                        .help("\(last.title), \(dayWord(last.start)). Mossad counts the recorded meetings in which this person\u{2019}s voice has their name."
                              + (person.fact.map { " The last number comes \($0.basis)." } ?? ""))
                        // The link is inside the text, where the keyboard and VoiceOver do not reach it.
                        .accessibilityAction(named: "Open \(last.title)") { controller.openMeeting(last.id) }
                } else {
                    Text("No recorded meeting together yet")
                }
            } else if loaded {
                Text("Not in People yet").foregroundStyle(Palette.tertiary)
            } else {
                Text(" ")
            }
        }
        .font(.system(size: 12)).monospacedDigit()
        .foregroundStyle(Palette.secondary)
    }

    private static func line(_ person: MeetingPrep.Person, _ last: MeetingPrep.Earlier) -> AttributedString {
        var met = AttributedString("Last recorded together \(day(last.start))")
        met.foregroundColor = Palette.ink
        met.link = URL(string: "mossad://call/\(last.id)")
        // The quiet dotted line of a name that is a link.
        met.underlineStyle = Text.LineStyle(pattern: .dot, color: Palette.tertiaryMark)
        // The dot stays with the words after it, so a line that wraps never ends in one.
        let dot = "  ·\u{00A0}\u{00A0}"
        var rest = dot + (person.recent == 0 ? "not in the last 90 days" : "\(person.recent) \(person.recent == 1 ? "time" : "times") in 90 days")
        if let fact = person.fact { rest += dot + fact.text }
        return met + AttributedString(rest)
    }

    /// "today", "yesterday", "Mon", "Oct 9": after "Last recorded together".
    private static func day(_ date: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(date) { return "today" }
        if cal.isDateInYesterday(date) { return "yesterday" }
        return dayWord(date)
    }
}
