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
    var top: CGFloat = 32
    /// Opens the meeting's Coach tab, for the coach's part.
    var openCoach: () -> Void = {}
    @State private var data: MeetingAnalytics?
    @State private var audio = false
    @State private var wide = true
    /// True when the numbers take longer than a moment: then the empty tab says that it is working.
    @State private var slow = false

    /// With the label column beside it, the content must still hold the widest table. Narrower, the labels go above.
    private static let wideWidth: CGFloat = 960

    /// Made here, not by the page: this body runs when something changed, the page's on each tick of the playback.
    private var key: MeetingAnalyticsStore.Key {
        var people = Hasher()
        for p in controller.library.profiles { people.combine(p.name); people.combine(p.email) }
        return MeetingAnalyticsStore.Key(record: MeetingAnalytics.stamp(record), owner: controller.ownerName, people: people.finalize(),
                                         coach: controller.coachVersion, commitments: controller.commitmentsVersion, meetings: controller.meetingsVersion)
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
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("Reading your earlier meetings…").font(.system(size: 12.5)).foregroundStyle(Palette.secondary)
                        }
                        .opacity(slow ? 1 : 0)
                        .frame(maxWidth: .infinity, minHeight: 320, alignment: .topLeading)
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
            slow = false
            let waiting = Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(300))
                if !Task.isCancelled { slow = true }
            }
            let made = await MeetingAnalyticsStore.shared.analytics(for: record, key: key, controller: controller)
            waiting.cancel()
            guard !Task.isCancelled else { return }
            withAnimation(.smooth) { data = made }
        }
    }
}

/// The meeting page draws again on each tick of the playback. The tab does not: it is the same until the record,
/// the people, or its place change. The comparison reads no words and hashes nothing (`sameInputs`).
extension MeetingAnalyticsTab: Equatable {
    nonisolated static func == (a: MeetingAnalyticsTab, b: MeetingAnalyticsTab) -> Bool {
        a.people.stamp == b.people.stamp && a.top == b.top && a.player === b.player && MeetingAnalytics.sameInputs(a.record, b.record)
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
                if a.baselines.meeting.context != nil || a.baselines.schedule != nil || a.baselines.trends != nil {
                    MeetingAnalyticsGroup("Against the usual") { UsualSection(analytics: a, record: record) }
                }
                if !a.speakers.isEmpty, a.byWords {
                    // Gemini's notes give the words, not when each was said: no talk time, pace, or flow.
                    MeetingAnalyticsGroup("Words") { WordsSection(analytics: a, people: people, callID: record.id) }
                } else if !a.speakers.isEmpty {
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

/// The numbers that stood out against what is usual for this meeting and its people, each with where to check
/// it. An ordinary call has one quiet line.
private struct StandoutsSection: View {
    @Environment(\.personOpener) private var opener
    let analytics: MeetingAnalytics
    let people: MeetingPeople
    let callID: String

    var body: some View {
        let b = analytics.baselines
        if b.standouts.isEmpty {
            Text(b.hasFirmHistory ? "Nothing unusual in this call."
                 : "Not enough history yet. Mossad calls a number unusual only against 5 or more earlier meetings like this one.")
                .font(.system(size: 13)).foregroundStyle(Palette.secondary)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(b.standouts) { s in
                    HStack(alignment: .top, spacing: 12) {
                        SpeakerSentence(speaker: s.subject.flatMap(people.speaker(forKey:)), callID: callID, text: s.text, size: 15)
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(Palette.ink)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        evidence(s.evidence)
                            .font(.system(size: 12, weight: .semibold))
                            .padding(.top, 2)
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
            if let opener, let person = people.speaker(forKey: id)?.person {
                Button { opener(person) } label: {
                    HStack(spacing: 3) {
                        Text("Profile")
                        IconImage(.chevronRight, size: 9)
                    }
                    .foregroundStyle(Palette.accent)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Open \(person)\u{2019}s profile")
                .accessibilityHint("Opens \(person)\u{2019}s profile")
                .accessibilityAddTraits(.isLink)
                .accessibilityRemoveTraits(.isButton)
            }
        case nil:
            EmptyView()
        }
    }
}

// MARK: Figures

/// Up to four numbers of the call, each with what is usual for it. A number the call does not have (no voice of
/// the owner's, no summary to count decisions in) has no tile: a dash or a zero would read as a fact.
private struct MeetingFigures: View {
    let analytics: MeetingAnalytics
    let record: CallRecord

    var body: some View {
        let a = analytics, m = a.baselines.meeting
        HStack(alignment: .top, spacing: 24) {
            Figure(title: "Length", value: hours(a.facts.values[.length] ?? 0), detail: lengthDetail, change: nil,
                   mark: mark(m[.length], .length, m.context, above: "longer", below: "shorter"))
            Figure(title: "People who spoke", value: "\(a.speakers.count)", detail: peopleDetail, change: nil,
                   mark: mark(m[.voices], .voices, m.context, above: "more", below: "fewer"))
            if let share = a.ownerShare {
                if a.byWords {
                    Figure(title: "Your share of the words", value: percentText(share), detail: "by words, from Gemini's notes", change: nil, mark: nil)
                } else {
                    Figure(title: "Your talk share", value: percentText(share), detail: shareDetail, change: nil, mark: shareMark)
                }
            }
            if let decisions = a.facts.values[.decisions], let items = a.facts.values[.actionItems] {
                Figure(title: "Decisions · action items", value: "\(Int(decisions)) · \(Int(items))", detail: outcomesDetail, change: nil, mark: nil)
            }
        }
    }

    private func mark(_ reading: MeetingAnalytics.Reading?, _ metric: MeetingMetric, _ context: MeetingAnalytics.Context?,
                      above: String, below: String) -> Figure.Mark? {
        guard let reading, reading.stoodOut, let usual = reading.usual, let context else { return nil }
        let up = reading.standing == .above
        let usually = MeetingFindings.usually(metric, usual, context: context)
        return Figure.Mark(text: "\(up ? "↑" : "↓") \(up ? above : below)", help: "\(sentenceCase(usually)) (\(MeetingFindings.basis(usual)))",
                           spoken: "\(up ? above : below) than usual, \(usually)")
    }

    /// One short fact, so the line is never cut off: the time past the plan when there is some, else the plan,
    /// else the usual range.
    private var lengthDetail: String {
        if let s = analytics.baselines.schedule {
            return s.ranOver ? "\(MeetingFindings.span(s.overrun)) past plan" : "planned \(hours(s.plannedLength))"
        }
        guard let usual = analytics.baselines.meeting[.length]?.usual, usual.isFirm else { return "" }
        return "usually \(MeetingFindings.range(.length, usual))"
    }

    /// "4 of 6 invited" only when every invited entry is matched and every voice has a name.
    private var peopleDetail: String {
        let unnamed = analytics.speakers.filter(\.isUnknown).count
        guard let p = analytics.participation else { return unnamed > 0 ? "\(unnamed) with no name yet" : "" }
        return p.isMatched && unnamed == 0 ? "\(p.spoke.count) of \(p.invited.count) invited" : "\(p.invited.count) invited"
    }

    private var ownerBaseline: MeetingAnalytics.PersonBaseline? {
        analytics.owner.flatMap { analytics.baselines.person($0.id) }
    }

    private var shareDetail: String {
        guard let usual = ownerBaseline?[.talkShare]?.usual, usual.isFirm else { return "" }
        return "usually \(MeetingFindings.range(.talkShare, usual))"
    }

    private var shareMark: Figure.Mark? {
        guard let b = ownerBaseline, let context = b.context, let reading = b[.talkShare], reading.stoodOut, let usual = reading.usual else { return nil }
        let up = reading.standing == .above
        let usually = MeetingFindings.usually(.talkShare, usual, context: context)
        return Figure.Mark(text: up ? "↑ more" : "↓ less", help: "\(sentenceCase(usually)) (\(MeetingFindings.basis(usual)))",
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
            }
            if let s = b.schedule { ScheduleLine(schedule: s) }
            if let t = b.trends { TrendsRow(trends: t) }
        }
    }

    /// A row needs a value of this call and a range. A row of nothing against nothing (no screens, usually none)
    /// is left out.
    private func rows(_ m: MeetingAnalytics.MeetingBaseline) -> [(MeetingMetric, String, MeetingAnalytics.Reading, MeetingAnalytics.Usual)] {
        Self.metrics.compactMap { metric, title in
            guard let reading = m[metric], let usual = reading.usual, !(reading.value == 0 && usual.low == 0 && usual.high == 0) else { return nil }
            return (metric, title, reading, usual)
        }
    }

    private func table(_ m: MeetingAnalytics.MeetingBaseline, _ context: MeetingAnalytics.Context) -> some View {
        VStack(spacing: 0) {
            ForEach(rows(m), id: \.1) { metric, title, reading, usual in
                HStack(spacing: 12) {
                    Text(title).foregroundStyle(Palette.secondary).lineLimit(1).frame(width: 170, alignment: .leading)
                    Marked(text: value(metric, reading.value), reading: reading,
                           tip: "\(sentenceCase(MeetingFindings.usually(metric, usual, context: context))) (\(MeetingFindings.basis(usual)))")
                        .frame(width: 110, alignment: .leading)
                    // "Usually" needs five meetings; fewer are "so far".
                    Text(usual.isFirm ? "usually \(MeetingFindings.range(metric, usual))" : "\(MeetingFindings.range(metric, usual)) in \(usual.samples) meetings so far")
                        .foregroundStyle(reading.stoodOut ? Palette.ink : Palette.tertiary)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
                .font(.system(size: 12.5)).monospacedDigit()
                .padding(.vertical, 6)
                .hairline()
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

/// "Planned 10:00 – 10:30 AM · you joined 6 min after the planned start · the recording ran 12 min past the planned
/// end". The recording begins when the owner joins, so the line is about the owner, not about the meeting.
private struct ScheduleLine: View {
    let schedule: MeetingAnalytics.Schedule

    var body: some View {
        let s = schedule
        let planned = (s.plannedStart..<s.plannedEnd).formatted(.interval.hour().minute())
        FlowLayout(spacing: 6) {
            Text("Planned \(planned)").foregroundStyle(Palette.secondary)
            Text("·").foregroundStyle(Palette.tertiary)
            Text(MeetingFindings.joined(s)).fontWeight(s.joinedLate ? .semibold : .regular).foregroundStyle(s.joinedLate ? Palette.ink : Palette.secondary)
            Text("·").foregroundStyle(Palette.tertiary)
            Text(MeetingFindings.ended(s)).fontWeight(s.ranOver ? .semibold : .regular).foregroundStyle(s.ranOver ? Palette.ink : Palette.secondary)
        }
        .font(.system(size: 12.5)).monospacedDigit()
        .accessibilityElement(children: .combine)
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
                    TrendLine(title: "Your talk share", value: percentText(last.value), points: t.talkShare.map(\.value), domain: nil, minimumSpan: 0.2)
                }
                if let last = t.value.last {
                    TrendLine(title: "The coach’s rating", value: MeetingValue.Rating(level: last.value)?.rawValue.capitalized ?? "–",
                              points: t.value.map(\.value), domain: 1...3)
                }
                if let last = t.length.last {
                    TrendLine(title: "Length", value: hours(last.value), points: t.length.map(\.value), domain: nil)
                }
            }
            Text("\(t.context.meetings) earlier \(t.context.meetings == 1 ? "meeting" : "meetings") \(t.context.label) and this call, oldest first. The dot is this call.")
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
    var minimumSpan: Double?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.system(size: 12)).foregroundStyle(Palette.secondary)
            Text(value).font(.system(size: 20, weight: .semibold)).tracking(-0.4).monospacedDigit()
            Sparkline(values: points, median: true, domain: domain, minimumSpan: minimumSpan)
                .frame(height: 34)
                .padding(.top, 8)
        }
        .padding(.top, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .hairline(.top)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title), \(value) in this call, over \(points.count - 1) earlier \(points.count == 2 ? "meeting" : "meetings") and this call")
    }
}

// MARK: Words

/// A meeting made from Gemini's notes: each person's words, their share by words, their questions, and their
/// turns. The times of the lines are placed, so nothing here is by time.
private struct WordsSection: View {
    let analytics: MeetingAnalytics
    let people: MeetingPeople
    let callID: String

    var body: some View {
        let a = analytics
        let peak = max(a.speakers.map(\.words).max() ?? 1, 1)
        VStack(alignment: .leading, spacing: 10) {
            Text("By words. This meeting was not recorded: its transcript is Gemini's, so there is no talk time, pace, or flow.")
                .font(.system(size: 12)).foregroundStyle(Palette.secondary)
                .fixedSize(horizontal: false, vertical: true)
            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    Spacer().frame(width: 150)
                    Spacer()
                    Text("Words").frame(width: 70, alignment: .trailing)
                    Text("Share").frame(width: 54, alignment: .trailing)
                    Text("Questions").frame(width: 70, alignment: .trailing)
                    Text("Turns").frame(width: 50, alignment: .trailing)
                }
                .font(.system(size: 11, weight: .medium)).foregroundStyle(Palette.tertiary)
                .padding(.bottom, 4)
                ForEach(a.speakers) { s in
                    let speaker = people.speaker(forKey: s.id)
                    HStack(spacing: 12) {
                        SpeakerCell(speaker: speaker, name: s.name, callID: callID).frame(width: 150, alignment: .leading)
                        Capsule().fill(Palette.fill)
                            .overlay(alignment: .leading) {
                                GeometryReader { g in Capsule().fill(speaker?.color ?? Palette.bar).frame(width: max(6, g.size.width * Double(s.words) / Double(peak))) }
                            }
                            .frame(height: 8)
                            .accessibilityHidden(true)
                        Text(s.words.formatted()).frame(width: 70, alignment: .trailing)
                        Text(percentText(s.share)).frame(width: 54, alignment: .trailing)
                        Text("\(s.questions)").frame(width: 70, alignment: .trailing)
                        Text("\(s.turns)").frame(width: 50, alignment: .trailing)
                    }
                    .font(.system(size: 12.5)).monospacedDigit().foregroundStyle(Palette.secondary)
                    .padding(.vertical, 7)
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("\(s.name): \(s.words) words, \(percentText(s.share)) of the words, \(s.questions) questions, \(s.turns) turns")
                }
            }
        }
    }
}
