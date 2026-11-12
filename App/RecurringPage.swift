import AppKit
import MossadCore
import SwiftUI

/// One recurring meeting, laid out as a meeting's page: the band (cadence, title, what is useful to know, the usual
/// people, the key numbers, and the next meeting with its record choice and Join), then the tabs.
struct RecurringPage: View {
    enum Tab: String, CaseIterable {
        case nextTime = "Next time", history = "History", people = "People", stats = "Stats", open = "Open items"
    }

    @EnvironmentObject var controller: AppController
    let series: MeetingSeries
    @AppStorage("recurringTab") private var savedTab = Tab.nextTime
    @State private var previewTab: Tab?
    @State private var data: (key: Int, report: SeriesReport, suggestions: [SeriesSuggestion])?
    @State private var wide = true

    private var tab: Tab { previewTab ?? savedTab }
    private var tabBinding: Binding<Tab> { Binding(get: { tab }, set: { previewTab = nil; savedTab = $0 }) }

    /// What the numbers and the suggestions read, as cheap counters.
    private var key: Int {
        var h = Hasher()
        h.combine(series)
        h.combine(series.meetings)
        h.combine(controller.meetingsVersion)
        h.combine(controller.commitmentsVersion)
        h.combine(controller.coachVersion)
        h.combine(controller.series.book.answers)
        h.combine(controller.series.book.points(of: series).open.map(\.text))
        return h.finalize()
    }

    var body: some View {
        VStack(spacing: 0) {
            RecurringHeader(series: series, report: data?.report, wide: wide)
                .overlay(alignment: .bottom) { DetailTabs(tab: tabBinding, tabs: Tab.allCases).offset(y: Detail.underTabs) }
                .zIndex(1)
            ScrollView {
                content.detailColumn(top: 44)
            }
        }
        .background(Palette.window)
        .environment(\.personOpener, controller.personOpener)
        .environment(\.analyticsWide, wide)
        .onGeometryChange(for: Bool.self) { $0.size.width >= 600 } action: { wide = $0 }
        .onAppear {
            // Development hook for screenshots: MOSSAD_RECURRING_TAB names the tab.
            if DevHooks.preview, let name = ProcessInfo.processInfo.environment["MOSSAD_RECURRING_TAB"] { previewTab = Tab(rawValue: name) }
        }
        .task(id: key) { await load() }
    }

    private func load() async {
        let series = series, records = controller.meetings, owner = controller.ownerName, key = key
        let commitments = CommitmentBook.peek(in: controller.paths.commitments)?.items
        let book = controller.series.book
        let focus = controller.shownCoachProfile.activeFocus
        let goal = focus.map { (plan: $0.plan, oneOnOne: $0.goal?.measure == .oneOnOneTalkShare) }
        let profiles = controller.library.profiles
        let identity = OwnerIdentity.read(name: owner, paths: controller.paths)
        let made = await Task.detached(priority: .userInitiated) {
            (SeriesReport(series: series, records: records, commitments: commitments, owner: identity, directory: PersonDirectory(profiles: profiles)),
             SeriesSuggestion.make(for: series, records: records, commitments: commitments, owner: identity, points: book.points(of: series).open,
                                   answers: book.answers, goal: goal))
        }.value
        guard !Task.isCancelled else { return }
        data = (key, made.0, made.1)
    }

    @ViewBuilder
    private var content: some View {
        VStack(alignment: .leading, spacing: 26) {
            switch tab {
            case .nextTime: NextTimeTab(series: series, suggestions: data?.suggestions ?? [])
            case .history: SeriesHistoryTab(series: series, report: data?.report)
            case .people: SeriesPeopleTab(report: data?.report)
            case .stats: SeriesStatsTab(series: series, report: data?.report)
            case .open: SeriesOpenTab(report: data?.report)
            }
        }
        .font(.system(size: 13))
        .foregroundStyle(Palette.ink)
    }
}

// MARK: The band

private struct RecurringHeader: View {
    @EnvironmentObject var controller: AppController
    let series: MeetingSeries
    let report: SeriesReport?
    let wide: Bool

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            VStack(alignment: .leading, spacing: 0) {
                FlowLayout(spacing: Space.s) {
                    HStack(spacing: Space.s) {
                        if let p = series.next?.platform { PlatformDot(platform: p, hollow: true) }
                        Text(series.cadence?.text ?? (series.recurringInCalendar ? "Repeats in your calendar" : "Recurring"))
                            .font(.system(size: 12)).foregroundStyle(Palette.secondary).lineLimit(1)
                    }
                    .frame(minHeight: 20)
                    if series.recurringInCalendar { TagChip(text: "In your calendar") }
                    if !series.meetings.isEmpty { TagChip(text: "Recorded \(series.meetings.count) \(series.meetings.count == 1 ? "time" : "times")") }
                }
                Text(series.title)
                    .font(.system(size: Detail.titleSize, weight: .semibold)).tracking(Detail.titleSize * -0.02)
                    .foregroundStyle(Palette.ink)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 6)
                    .frame(maxWidth: Detail.titleMax, alignment: .leading)
                    .textSelection(.enabled)
                    .accessibilityAddTraits(.isHeader)
                if let line = report?.line {
                    Text(line).font(.system(size: 15, weight: .medium)).foregroundStyle(Palette.secondary).padding(.top, 6)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if !series.usualPeople.isEmpty {
                    FlowLayout(spacing: 6) {
                        ForEach(series.usualPeople.prefix(12), id: \.self) { name in
                            PersonName(name)
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(Palette.ink)
                                .padding(.horizontal, 9).frame(minHeight: 24)
                                .background(Palette.fill, in: Capsule())
                        }
                    }
                    .padding(.top, 16)
                    .accessibilityElement(children: .contain)
                    .accessibilityLabel("Usual people")
                }
                numbers.padding(.top, 18)
                next(now: context.date).padding(.top, 16)
            }
            .frame(maxWidth: Detail.columnMax, alignment: .leading)
            .padding(.horizontal, Detail.gutter)
            .padding(.top, Detail.bandPadding)
            .padding(.bottom, Detail.bandPadding + 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Palette.band)
            .hairline(.bottom)
        }
    }

    /// Meetings so far, since when, the usual length, how often it runs over, and the meetings that did not happen.
    private var numbers: some View {
        let r = report
        var cells: [(String, String, String?)] = [("Meetings", "\(series.meetings.count)", nil)]
        if let since = r?.since { cells.append(("Since", since.formatted(.dateTime.month(.abbreviated).day().year()), nil)) }
        if let m = r?.medianMinutes {
            cells.append(("Usual length", "\(Int(m.rounded())) min", r?.medianPlannedMinutes.map { "of \(Int($0.rounded())) planned" }))
        }
        if let r, r.planned > 0 { cells.append(("Runs over", "\(r.ranOver) of \(r.planned)", "by 5 min or more")) }
        if let gaps = r?.gaps { cells.append(("Not recorded", "\(gaps)", gaps == 1 ? "week with no meeting" : "times with no meeting")) }
        return HStack(alignment: .top, spacing: 28) {
            ForEach(cells, id: \.0) { c in
                VStack(alignment: .leading, spacing: 2) {
                    Text(c.0).textRole(.label).foregroundStyle(Palette.secondary)
                    Text(c.1).font(.system(size: 17, weight: .semibold)).monospacedDigit().foregroundStyle(Palette.ink)
                    if let note = c.2 { Text(note).font(.system(size: 11)).foregroundStyle(Palette.tertiary) }
                }
                .accessibilityElement(children: .combine)
            }
        }
    }

    @ViewBuilder
    private func next(now: Date) -> some View {
        if let next = series.next {
            HStack(spacing: Space.m) {
                Text("Next: \(UpcomingHeader.day(next.start)), \(next.start.formatted(date: .omitted, time: .shortened))")
                    .font(.system(size: 13, weight: .semibold)).foregroundStyle(Palette.ink)
                Text(next.startsIn(now: now)).font(.system(size: 12)).foregroundStyle(Palette.secondary)
                if next.platform != nil { RecordChoiceControl(meeting: next, size: .regular) }
                if let link = next.link, next.start.timeIntervalSince(now) <= 60 {
                    Button { NSWorkspace.shared.open(link) } label: {
                        Text("Join \(next.platform?.displayName ?? "the call")")
                            .font(.system(size: 12.5, weight: .semibold)).foregroundStyle(Palette.onAccent)
                            .padding(.horizontal, 14).frame(height: 28)
                            .background(Palette.accentFill, in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
                Button("Prepare") {
                    controller.selectedMeetingID = next.id
                    controller.open(.meetings)
                }
                .buttonStyle(.plain).font(.system(size: 12, weight: .semibold)).foregroundStyle(Palette.accent)
                .help("Open the page of this meeting")
                Spacer(minLength: 0)
            }
        } else {
            Text(series.meetings.isEmpty ? "No date in your calendar." : "No meeting of this series in your calendar in the next \(UpcomingMeeting.days) days.")
                .font(.system(size: 12)).foregroundStyle(Palette.tertiary)
        }
    }
}

// MARK: Next time

/// The owner's points for the next meeting, the coach's suggestions apart from them, the points for each usual
/// person, and what the last meetings discussed.
struct NextTimeTab: View {
    @EnvironmentObject var controller: AppController
    let series: MeetingSeries
    let suggestions: [SeriesSuggestion]

    var body: some View {
        let lists = controller.series.book.points(of: series)
        MeetingAnalyticsGroup("Your points") {
            VStack(alignment: .leading, spacing: 6) {
                if !controller.series.bookReadable {
                    Text("Mossad could not read your points, so it does not change them now.").foregroundStyle(Palette.recording)
                }
                if lists.open.isEmpty {
                    Text("What do you want to raise \(series.next.map { "on \(UpcomingHeader.day($0.start))" } ?? "next time")? Your points show on the meeting's page and in the menu before it starts.")
                        .font(.system(size: 12.5)).foregroundStyle(Palette.tertiary).fixedSize(horizontal: false, vertical: true)
                }
                NextTimeList(points: lists.open, add: { text in controller.changeNextTime { $0.add(text, series: series) } })
            }
        }
        MeetingAnalyticsGroup("Suggested") {
            SuggestionList(series: series, suggestions: suggestions)
        }
        let people = personPoints
        if !people.isEmpty {
            MeetingAnalyticsGroup("For one person") {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(people, id: \.id) { p in PersonNextTimeSection(personID: p.id, name: p.name) }
                }
            }
        }
        if !lists.done.isEmpty {
            MeetingAnalyticsGroup("Discussed") {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(lists.done.prefix(10)) { DiscussedRow(point: $0) }
                }
            }
        }
    }

    /// The usual people who have points of their own.
    private var personPoints: [(id: String, name: String)] {
        let refs = PersonReferences(people: PeopleStore.peek(in: controller.paths.people) ?? [])
        return series.usualPeople.compactMap { name in
            guard let id = refs.id(for: name), !controller.series.book.points(forPerson: id).isEmpty else { return nil }
            return (id, name)
        }
    }
}
