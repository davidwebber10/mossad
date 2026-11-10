import MossadCore
import SwiftUI

/// The numbers of one call, in the Analytics page's look: what stood out against the owner's other meetings, four
/// figures, then one group per question. The numbers are made off the main thread, once per change of the record
/// (`MeetingAnalyticsStore`); this view only shows them.
struct MeetingAnalyticsTab: View {
    @EnvironmentObject var controller: AppController
    let record: CallRecord
    let people: MeetingPeople
    /// Not observed: the tab does not draw again on each tick of the playback.
    let player: AudioPlayer
    /// `MeetingAnalytics.stamp` of the record, worked out by the page.
    let stamp: Int
    var top: CGFloat = 32
    /// Opens the meeting's Coach tab, for the coach's part.
    var openCoach: () -> Void = {}
    @State private var data: MeetingAnalytics?
    @State private var audio = false
    @State private var wide = true

    /// The tab's content column is this wide with the label column beside it; narrower, the labels go above.
    private static let wideWidth: CGFloat = 840

    private var key: MeetingAnalyticsStore.Key {
        var people = Hasher()
        for p in controller.library.profiles { people.combine(p.name); people.combine(p.email) }
        return MeetingAnalyticsStore.Key(record: stamp, owner: controller.ownerName, people: people.finalize(), coach: controller.coachVersion,
                                         commitments: controller.commitmentsVersion, meetings: controller.meetingsVersion)
    }

    var body: some View {
        let key = key
        // The numbers made last stay while new ones are made, but never another meeting's.
        let shown = MeetingAnalyticsStore.shared.cached(record.id, key: key) ?? (data?.facts.id == record.id ? data : nil)
        ScrollViewReader { proxy in
            ScrollView {
                Group {
                    if let shown {
                        if shown.isEmpty {
                            EmptyState(symbol: "chart.bar.xaxis", title: "No numbers for this call",
                                       message: record.status == .written ? "Nobody spoke, and nothing came out of it."
                                           : "The numbers show here when the transcript is done.")
                        } else {
                            MeetingAnalyticsPage(analytics: shown, record: record, people: people, openCoach: openCoach)
                        }
                    } else {
                        Color.clear.frame(height: 320)
                    }
                }
                .detailColumn(top: top)
            }
            // Development hook for screenshots: MOSSAD_SCROLL_TO names a group's label, such as "Conversation flow".
            .onChange(of: shown?.facts.id) { _, _ in
                guard CommandLine.arguments.contains("--ui-preview"), let target = ProcessInfo.processInfo.environment["MOSSAD_SCROLL_TO"] else { return }
                // A little under the top: the tabs float over the first 30 points.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { proxy.scrollTo(target, anchor: UnitPoint(x: 0, y: 0.1)) }
            }
        }
        .onGeometryChange(for: Bool.self) { $0.size.width >= Self.wideWidth } action: { wide = $0 }
        .environment(\.analyticsWide, wide)
        .environment(\.momentPlayer, audio ? MomentPlayer { [player] at in player.play(from: at) } : nil)
        .onReceive(player.$isAvailable.removeDuplicates()) { audio = $0 }
        .task(id: key) {
            let made = await MeetingAnalyticsStore.shared.analytics(for: record, key: key, controller: controller)
            guard !Task.isCancelled else { return }
            withAnimation(.smooth) { data = made }
        }
    }
}

/// The meeting page draws again on each tick of the playback. The tab does not: it is the same until the record,
/// the people, or its place change.
extension MeetingAnalyticsTab: Equatable {
    nonisolated static func == (a: MeetingAnalyticsTab, b: MeetingAnalyticsTab) -> Bool {
        a.stamp == b.stamp && a.people.stamp == b.people.stamp && a.top == b.top && a.player === b.player
    }
}

/// The page: what stood out, the figures, then the groups. A group with nothing to show is left out.
private struct MeetingAnalyticsPage: View {
    let analytics: MeetingAnalytics
    let record: CallRecord
    let people: MeetingPeople
    let openCoach: () -> Void

    var body: some View {
        let a = analytics
        VStack(alignment: .leading, spacing: 0) {
            MeetingAnalyticsGroup("What stood out") { StandoutsSection(analytics: a, people: people, callID: record.id) }
                .padding(.bottom, 22)
            MeetingFigures(analytics: a, record: record)
                .padding(.vertical, 18)
                .hairline(.top)
                .hairline()
            VStack(alignment: .leading, spacing: 36) {
                // With no history at all, "What stood out" already says so; the group shows only when it has more.
                if a.baselines.hasHistory || a.baselines.schedule != nil || a.baselines.trends != nil {
                    MeetingAnalyticsGroup("Against the usual") { UsualSection(analytics: a, record: record) }
                }
                if !a.speakers.isEmpty {
                    MeetingAnalyticsGroup("Talk time") { TalkTimeSection(analytics: a, people: people, callID: record.id) }
                    MeetingAnalyticsGroup("Conversation flow") { FlowSection(analytics: a, people: people, callID: record.id, long: record.isLong) }
                    MeetingAnalyticsGroup("Delivery") { DeliverySection(analytics: a, people: people, callID: record.id) }
                }
                if let p = a.participation {
                    MeetingAnalyticsGroup("Participation") { ParticipationSection(participation: p, analytics: a, people: people, callID: record.id) }
                }
                if let o = a.outcomes {
                    MeetingAnalyticsGroup("Outcomes") { MeetingOutcomesSection(outcomes: o, analytics: a, people: people, callID: record.id) }
                }
                if let c = a.coach {
                    MeetingAnalyticsGroup("Coach") { MeetingCoachSection(coach: c, open: openCoach) }
                }
                if let s = a.screens {
                    MeetingAnalyticsGroup("Screens") { MeetingScreensSection(screens: s, long: record.isLong) }
                }
                if let c = a.cost {
                    MeetingAnalyticsGroup("Cost") { MeetingCostSection(cost: c) }
                }
            }
            .padding(.top, 24)
        }
    }
}

// MARK: What stood out

/// The few numbers furthest from what is usual for this meeting and its people, each with where to check it.
private struct StandoutsSection: View {
    @EnvironmentObject var controller: AppController
    let analytics: MeetingAnalytics
    let people: MeetingPeople
    let callID: String

    var body: some View {
        let b = analytics.baselines
        if b.standouts.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Finding(b.hasHistory ? "Nothing unusual" : "Not enough history yet")
                Text(b.hasHistory ? "Every number of this call is inside its usual range."
                     : "Mossad compares a call with at least 3 earlier meetings of the same series, the same setting, or the same people.")
                    .font(.system(size: 12.5)).foregroundStyle(Palette.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } else {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(b.standouts) { s in
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        SpeakerSentence(speaker: s.subject.flatMap(people.speaker(forKey:)), callID: callID, text: s.text)
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(Palette.ink)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        evidence(s.evidence)
                            .font(.system(size: 12, weight: .semibold))
                    }
                    .padding(.vertical, 8)
                    .hairline()
                }
            }
        }
    }

    @ViewBuilder
    private func evidence(_ evidence: MeetingAnalytics.Evidence?) -> some View {
        switch evidence {
        case .moment(let at):
            PlayAt(at: at, icon: true)
        case .person(let id):
            if let person = people.speaker(forKey: id)?.person {
                Button { controller.openPerson(person) } label: {
                    HStack(spacing: 3) {
                        Text("Profile")
                        IconImage(.chevronRight, size: 9)
                    }
                    .foregroundStyle(Palette.accent)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Open \(person)\u{2019}s profile")
                .accessibilityLabel("Open \(person)\u{2019}s profile")
                .accessibilityAddTraits(.isLink)
                .accessibilityRemoveTraits(.isButton)
            }
        case nil:
            EmptyView()
        }
    }
}

// MARK: Figures

/// Four numbers of the call, each with what is usual for it.
private struct MeetingFigures: View {
    let analytics: MeetingAnalytics
    let record: CallRecord

    var body: some View {
        let a = analytics, m = a.baselines.meeting
        let length = max(0, record.end.timeIntervalSince(record.start))
        HStack(alignment: .top, spacing: 24) {
            Figure(title: "Length", value: hours(length), detail: lengthDetail, change: nil,
                   mark: mark(m[.length], .length, m.context, above: "longer", below: "shorter"))
            Figure(title: "People who spoke", value: "\(a.speakers.count)", detail: peopleDetail, change: nil,
                   mark: mark(m[.voices], .voices, m.context, above: "more", below: "fewer"))
            Figure(title: "Your talk share", value: a.ownerShare.map(percentText) ?? "–", detail: shareDetail, change: nil, mark: shareMark)
            Figure(title: "Decisions · action items", value: "\(a.outcomes?.decisions ?? 0) · \(a.outcomes?.actionItems ?? 0)",
                   detail: outcomesDetail, change: nil, mark: nil)
        }
    }

    private func mark(_ reading: MeetingAnalytics.Reading?, _ metric: MeetingMetric, _ context: MeetingAnalytics.Context?,
                      above: String, below: String) -> Figure.Mark? {
        guard let reading, reading.stoodOut, let usual = reading.usual, let context else { return nil }
        let up = reading.standing == .above
        let usually = MeetingFindings.usually(metric, usual, context: context)
        return Figure.Mark(text: "\(up ? "↑" : "↓") \(up ? above : below)", help: usually.prefix(1).uppercased() + usually.dropFirst(),
                           spoken: "\(up ? above : below) than usual, \(usually)")
    }

    /// The planned length when the invite has one, else the usual range.
    private var lengthDetail: String {
        if let s = analytics.baselines.schedule {
            // One fact, so the line never cuts off: the overrun when there is one, else the plan.
            return s.ranOver ? "\(MeetingFindings.span(s.overrun)) over the planned \(hours(s.plannedLength))" : "planned \(hours(s.plannedLength))"
        }
        let m = analytics.baselines.meeting
        return m[.length]?.usual.map { "usually \(MeetingFindings.range(.length, $0))" } ?? ""
    }

    private var peopleDetail: String {
        guard let p = analytics.participation else { return analytics.speakers.contains(where: \.isUnknown) ? "some with no name yet" : "" }
        return "\(p.spoke.count) of \(p.invited.count) invited"
    }

    private var ownerBaseline: MeetingAnalytics.PersonBaseline? {
        analytics.owner.flatMap { analytics.baselines.person($0.id) }
    }

    private var shareDetail: String {
        guard let b = ownerBaseline, let usual = b[.talkShare]?.usual else { return analytics.ownerShare == nil ? "you did not speak" : "" }
        return "usually \(MeetingFindings.range(.talkShare, usual))"
    }

    private var shareMark: Figure.Mark? {
        guard let b = ownerBaseline, let context = b.context, let reading = b[.talkShare], reading.stoodOut, let usual = reading.usual else { return nil }
        let up = reading.standing == .above
        let usually = MeetingFindings.usually(.talkShare, usual, context: context)
        return Figure.Mark(text: up ? "↑ more" : "↓ less", help: usually.prefix(1).uppercased() + usually.dropFirst(),
                           spoken: "\(up ? "more" : "less") than usual, \(usually)")
    }

    private var outcomesDetail: String {
        guard let tasks = analytics.outcomes?.tasks, !tasks.isEmpty else { return "" }
        return "\(tasks.count) of them \(tasks.count == 1 ? "is your task" : "are your tasks")"
    }
}

// MARK: Against the usual

/// The meeting's own numbers next to their usual range, the call against its invite, and the lines over the last
/// meetings of the series.
private struct UsualSection: View {
    let analytics: MeetingAnalytics
    let record: CallRecord

    private static let metrics: [(MeetingMetric, String)] = [
        (.length, "Length"), (.voices, "People who spoke"), (.decisions, "Decisions"), (.actionItems, "Action items"),
        (.screens, "Screens shared"), (.silenceShare, "Silence"), (.wordsPerMinute, "Words a minute, everyone"), (.value, "The coach’s rating"),
    ]

    var body: some View {
        let b = analytics.baselines
        VStack(alignment: .leading, spacing: 12) {
            if let context = b.meeting.context {
                Finding(MeetingFindings.compared(context))
                table(b.meeting, context)
            } else if b.hasHistory {
                Text("The meeting has fewer than 3 earlier meetings of its series or its setting, so only its people have a usual range.")
                    .font(.system(size: 12.5)).foregroundStyle(Palette.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let s = b.schedule { ScheduleLine(schedule: s) }
            if let t = b.trends { TrendsRow(trends: t) }
        }
    }

    private func table(_ m: MeetingAnalytics.MeetingBaseline, _ context: MeetingAnalytics.Context) -> some View {
        VStack(spacing: 0) {
            ForEach(Self.metrics.filter { m[$0.0]?.usual != nil }, id: \.1) { metric, title in
                if let reading = m[metric], let usual = reading.usual {
                    HStack(spacing: 12) {
                        Text(title).foregroundStyle(Palette.secondary).lineLimit(1).frame(width: 170, alignment: .leading)
                        Marked(text: value(metric, reading.value), reading: reading, usually: MeetingFindings.usually(metric, usual, context: context))
                            .frame(width: 110, alignment: .leading)
                        Text("usually \(MeetingFindings.range(metric, usual))")
                            .foregroundStyle(reading.stoodOut ? Palette.ink : Palette.tertiary)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    .font(.system(size: 12.5)).monospacedDigit()
                    .padding(.vertical, 6)
                    .hairline()
                }
            }
        }
        .hairline(.top)
    }

    private func value(_ metric: MeetingMetric, _ v: Double) -> String {
        switch metric {
        case .length: hours(v)
        case .voices, .decisions, .actionItems, .screens: "\(Int(v.rounded()))"
        case .silenceShare: percentText(v)
        case .wordsPerMinute: "\(Int(v.rounded()))"
        case .value: MeetingValue.Rating(level: v)?.rawValue.capitalized ?? "–"
        }
    }
}

/// "Planned 10:00 – 10:30 AM · began 6 min late · ran 12 min over".
private struct ScheduleLine: View {
    let schedule: MeetingAnalytics.Schedule

    var body: some View {
        let s = schedule
        let planned = (s.plannedStart..<s.plannedEnd).formatted(.interval.hour().minute())
        HStack(spacing: 6) {
            Text("Planned \(planned)").foregroundStyle(Palette.secondary)
            Text("·").foregroundStyle(Palette.tertiary)
            Text(start).fontWeight(s.startedLate ? .semibold : .regular).foregroundStyle(s.startedLate ? Palette.ink : Palette.secondary)
            Text("·").foregroundStyle(Palette.tertiary)
            Text(end).fontWeight(s.ranOver ? .semibold : .regular).foregroundStyle(s.ranOver ? Palette.ink : Palette.secondary)
        }
        .font(.system(size: 12.5)).monospacedDigit()
        .accessibilityElement(children: .combine)
    }

    private var start: String {
        let d = schedule.startDelay
        return abs(d) < 60 ? "began on time" : d > 0 ? "began \(MeetingFindings.span(d)) late" : "began \(MeetingFindings.span(-d)) early"
    }

    private var end: String {
        let o = schedule.overrun
        return abs(o) < 60 ? "ended on time" : o > 0 ? "ran \(MeetingFindings.span(o)) over" : "ended \(MeetingFindings.span(-o)) early"
    }
}

/// Your talk share, the coach's rating, and the length over the last meetings, with this call as the dot.
private struct TrendsRow: View {
    let trends: MeetingAnalytics.Trends

    var body: some View {
        let t = trends
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .top, spacing: 24) {
                if let last = t.talkShare.last {
                    TrendLine(title: "Your talk share", value: percentText(last.value), points: t.talkShare.map(\.value), domain: nil)
                }
                if let last = t.value.last {
                    TrendLine(title: "The coach’s rating", value: MeetingValue.Rating(level: last.value)?.rawValue.capitalized ?? "–",
                              points: t.value.map(\.value), domain: 1...3)
                }
                if let last = t.length.last {
                    TrendLine(title: "Length", value: hours(last.value), points: t.length.map(\.value), domain: nil)
                }
            }
            Text("The last \(t.context.meetings) \(t.context.meetings == 1 ? "meeting" : "meetings") \(t.context.label), oldest first; the dot is this call.")
                .font(.system(size: 11.5)).foregroundStyle(Palette.tertiary)
        }
        .padding(.top, 4)
    }
}

/// One number with its line over the last meetings, as the Analytics page's trend figures.
private struct TrendLine: View {
    let title: String
    let value: String
    let points: [Double]
    let domain: ClosedRange<Double>?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.system(size: 12)).foregroundStyle(Palette.secondary)
            Text(value).font(.system(size: 20, weight: .semibold)).tracking(-0.4).monospacedDigit()
            Sparkline(values: points, median: true, domain: domain)
                .frame(height: 34)
                .padding(.top, 8)
        }
        .padding(.top, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .hairline(.top)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title), \(value) in this call, over the last \(points.count) meetings")
    }
}
