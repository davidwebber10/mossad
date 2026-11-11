import Charts
import MossadCore
import SwiftUI

/// The Mac's Analytics story on the phone: how much time, where it went, with whom, how you communicated,
/// and what came out of it, for a period against the one before. People, the list and the profiles, opens from here.
struct AnalyticsScreen: View {
    @Environment(PhoneStore.self) private var store
    @AppStorage("analyticsPreset") private var presetRaw = PeriodChoice.Preset.last30Days.rawValue
    @AppStorage("analyticsStart") private var startStamp = Date().addingTimeInterval(-13 * 86_400).timeIntervalSince1970
    @AppStorage("analyticsEnd") private var endStamp = Date().timeIntervalSince1970
    @State private var data: (now: AnalyticsReport, before: AnalyticsReport)?
    @State private var scores: [(date: Date, score: Int)] = []
    @State private var stats: [String: PersonStats] = [:]
    /// The charts of "How you communicate". They come after the page: the first time, every meeting is read.
    @State private var trends: CommunicationTrends?
    @AppStorage("analyticsTrendSplit") private var splitRaw = CommunicationTrends.Split.all.rawValue
    @State private var customizing = false

    /// Each meeting's numbers, kept while the app runs: only a new or changed meeting is read again.
    /// Shared with Coach › Goals, so a meeting is read for its facts one time.
    static let facts = MeetingFactsCache()

    private var choice: PeriodChoice {
        PeriodChoice(preset: PeriodChoice.Preset(rawValue: presetRaw) ?? .last30Days,
                     start: Date(timeIntervalSince1970: startStamp), end: Date(timeIntervalSince1970: endStamp))
    }

    var body: some View {
        @Bindable var store = store
        NavigationStack(path: $store.analyticsPath) {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        periodMenu.frame(maxWidth: .infinity)
                        peopleLink
                        if let data {
                            if data.now.calls == 0 {
                                EmptyState(symbol: "chart.bar.xaxis", title: "No calls in this period",
                                           message: "Pick a longer period, or wait for your next call.")
                            } else {
                                content(data.now, data.before)
                            }
                        } else {
                            PhoneProcessingMark().frame(maxWidth: .infinity).padding(.top, 60)
                        }
                    }
                    .padding(.horizontal)
                    .padding(.bottom, 24)
                }
                // Development hook for screenshots: MOSSAD_SCROLL_TO names a section, such as "How you communicate".
                .onChange(of: trends?.interval) { _, _ in
                    if let target = PhoneStore.hook("MOSSAD_SCROLL_TO") {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { proxy.scrollTo(target, anchor: .top) }
                    }
                }
            }
            .phonePage()
            .navigationTitle("Analytics")
            .sheet(isPresented: $customizing) { CustomRangeSheet(start: choice.start, end: choice.end, apply: applyCustom) }
            .navigationDestination(for: AnalyticsRoute.self) { _ in PeopleScreen(path: $store.analyticsPath) }
            .navigationDestination(for: PersonLink.self) { link in PersonView(name: link.name, stats: stats[link.name] ?? PersonStats()) }
            .navigationDestination(for: String.self) { id in MeetingPage(id: id) }
            .refreshable { await store.sync() }
            .task(id: "\(presetRaw)-\(startStamp)-\(endStamp)-\(store.meetingsVersion)-\(store.coachVersion)") { await load() }
        }
    }

    /// Everyone you meet with, all time: the People list and each person's profile.
    private var peopleLink: some View {
        NavigationLink(value: AnalyticsRoute.people) {
            HStack(spacing: Space.m) {
                Image(systemName: "person.2")
                    .font(.body)
                    .foregroundStyle(Palette.accent)
                    .frame(width: 28)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text("People").textRole(.headline).foregroundStyle(Palette.ink)
                    Text(peopleCount).textRole(.secondary).foregroundStyle(Palette.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Palette.tertiary)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, Space.l).padding(.vertical, Space.m)
            .mossadGlass(in: RoundedRectangle(cornerRadius: 18, style: .continuous), interactive: true)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityHint("Opens everyone you meet with and their profiles")
    }

    /// "14 people · profiles and time together"
    private var peopleCount: String {
        let n = store.personStats.keys.filter { $0 != store.owner && !$0.hasPrefix("Speaker ") }.count
        return n == 0 ? "Profiles and time together" : "\(n) \(n == 1 ? "person" : "people") · profiles and time together"
    }

    private var periodMenu: some View {
        Menu {
            Picker("Period", selection: $presetRaw) {
                ForEach(PeriodChoice.Preset.allCases.filter { $0 != .custom }) { p in
                    Button {} label: {
                        Text(p.title)
                        Text(periodText(p.range!.interval(earliest: store.meetings.map(\.start).min())))
                    }
                    .tag(p.rawValue)
                }
            }
            Divider()
            Button("Custom range…", systemImage: "calendar") { customizing = true }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "calendar").accessibilityHidden(true)
                Text(data.map { shortPeriodText($0.now.interval) } ?? choice.preset.title)
                Image(systemName: "chevron.down").font(.caption2.weight(.semibold)).accessibilityHidden(true)
            }
            .textRole(.secondary)
            .fontWeight(.medium)
            .foregroundStyle(Palette.ink)
            .padding(.horizontal, 14).padding(.vertical, 8)
            .mossadGlass(in: Capsule(), interactive: true)
        }
        .accessibilityLabel("Period, \(data.map { periodText($0.now.interval) } ?? choice.preset.title)")
    }

    private func applyCustom(_ start: Date, _ end: Date) {
        startStamp = start.timeIntervalSince1970
        endStamp = end.timeIntervalSince1970
        presetRaw = PeriodChoice.Preset.custom.rawValue
        customizing = false
    }

    private func load() async {
        let records = store.meetings, owner = store.owner, paths = store.paths, range = choice.range
        let commitments = store.commitments.visible
        let result = await Task.detached(priority: .userInitiated) {
            let interval = range.interval(earliest: records.map(\.start).min())
            let reviews = Dictionary(uniqueKeysWithValues: records.filter { interval.contains($0.start) }.compactMap { r in
                CoachReview.load(in: paths.callDirectory(r.id)).map { (r.id, $0) }
            })
            let scores = records.filter { interval.contains($0.start) }.compactMap { r in reviews[r.id]?.scorecard.map { (date: r.start, score: $0.score) } }
                .sorted { $0.date < $1.date }
            return (AnalyticsReport(records: records, usage: [], owner: owner, interval: interval, reviews: reviews, commitments: commitments),
                    AnalyticsReport(records: records, usage: [], owner: owner, interval: AnalyticsRange.previous(interval), commitments: commitments),
                    scores, PersonStatistics.compute(records))
        }.value
        // A load that was replaced must not put its older period under the newer load's charts: the two can
        // end in either order, and the charts show only with the report of their own period.
        guard !Task.isCancelled else { return }
        withAnimation(.smooth) {
            data = (result.0, result.1)
            scores = result.2
            stats = result.3
        }

        let facts = Self.facts, interval = result.0.interval
        let made = await Task.detached(priority: .userInitiated) {
            CommunicationTrends(facts: facts.facts(for: records, owner: owner), interval: interval)
        }.value
        guard !Task.isCancelled else { return }
        withAnimation(.smooth) { trends = made }
    }

    // MARK: Content

    @ViewBuilder
    private func content(_ r: AnalyticsReport, _ b: AnalyticsReport) -> some View {
        let weeks = max(1, r.interval.duration / (7 * 86_400))
        HStack(alignment: .top, spacing: Space.l) {
            StatTile(value: duration(r.callSeconds), label: "Time in calls", detail: "\(duration(r.callSeconds / weeks)) a week")
            StatTile(value: "\(r.calls)", label: "Calls", detail: change(Double(r.calls), Double(b.calls)) ?? "\(Int((Double(r.calls) / weeks).rounded())) a week")
        }
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 0) {
            StatTile(value: pct(share(r.scheduled.calls, r.calls)), label: "Scheduled",
                     detail: "\(pct(r.scheduled.seconds / max(r.callSeconds, 1))) of the time")
            StatTile(value: r.talkShare.map(pct) ?? "–", label: "You talked",
                     detail: [r.communication.oneOnOneShare.map { "1:1 \(pct($0))" }, r.communication.groupShare.map { "groups \(pct($0))" }]
                        .compactMap { $0 }.joined(separator: " · "))
        }

        heading("Your time", AnalyticsFindings.scheduled(r) ?? AnalyticsFindings.time(r))
        PhoneTimeChart(report: r)
        Card {
            CardTitle(text: "Scheduled and unscheduled", symbol: "calendar")
            PhoneShareBar(label: "Meetings", share: share(r.scheduled.calls, r.calls), detail: "\(r.scheduled.calls) of \(r.calls)")
            PhoneShareBar(label: "Time", share: r.scheduled.seconds / max(r.callSeconds, 1), detail: "\(duration(r.scheduled.seconds)) of \(duration(r.callSeconds))")
            Text(averages(r)).font(.caption).foregroundStyle(.secondary)
        }

        heading("Your week", AnalyticsFindings.workdays(r.workday))
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
            StatTile(value: duration(r.workday.hoursPerWorkday * 3600), label: "Per work day")
            StatTile(value: pct(r.workday.coreHoursShare), label: "Of 8 to 6 in meetings")
            StatTile(value: r.workday.backToBackShare.map(pct) ?? "–", label: "Back to back")
            StatTile(value: "\(r.workday.callFreeDays) of \(r.workday.workdays)", label: "Days with no meetings")
        }

        heading("What you meet about", AnalyticsFindings.topics(r))
        if !r.tags.isEmpty { topics(r) }
        if r.valueSeconds.values.reduce(0, +) > 0 { value(r) }

        heading("Who you meet with", AnalyticsFindings.people(r))
        people(r)

        heading("How you communicate", AnalyticsFindings.communication(r.communication, talkShare: r.talkShare))
        if let trends, trends.interval == r.interval {
            communication(trends)
        } else {
            PhoneProcessingMark().frame(maxWidth: .infinity).padding(.vertical, Space.xl)
        }
        if scores.count > 1 { scoreChart }

        heading("Outcomes", AnalyticsFindings.outcomes(r.outcomes))
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
            StatTile(value: String(format: "%.1f", r.outcomes.itemsPerHour), label: "Action items an hour")
            StatTile(value: String(format: "%.1f", r.outcomes.decisionsPerHour), label: "Decisions an hour")
            StatTile(value: "\(r.outcomes.mine) · \(r.outcomes.others)", label: "Items yours · others'")
            StatTile(value: r.outcomes.commitmentsMade > 0 ? "\(r.outcomes.commitmentsDone) of \(r.outcomes.commitmentsMade)" : "–",
                     label: "Tasks done")
        }
    }

    /// A section's label in caps, then its finding: the sentence first, the chart under it as the evidence.
    private func heading(_ label: String, _ finding: String?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            PhoneLabel(label)
            if let finding {
                Text(finding).textRole(.lede).foregroundStyle(Palette.ink).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.top, Space.xl)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
        .id(label)
    }

    /// One full-width chart per number, and the choice of size over them when the period has 1:1s and groups.
    @ViewBuilder
    private func communication(_ trends: CommunicationTrends) -> some View {
        let split = trends.splits.isEmpty ? .all : CommunicationTrends.Split(rawValue: splitRaw) ?? .all
        if !trends.splits.isEmpty {
            Picker("Meetings in the charts", selection: $splitRaw) {
                ForEach(trends.splits) { Text($0.title).tag($0.rawValue) }
            }
            .pickerStyle(.segmented)
        }
        ForEach(trends.series(split)) { series in
            Card {
                TrendPanel(series: series, interval: trends.interval) { store.analyticsPath.append($0) }
            }
        }
    }

    private func topics(_ r: AnalyticsReport) -> some View {
        let top = Array(r.tags.prefix(8))
        let peak = max(top.first?.seconds ?? 1, 1)
        return Card {
            CardTitle(text: "Topics", symbol: "number")
            ForEach(top) { t in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(t.name).lineLimit(1)
                        Spacer()
                        Text(duration(t.seconds)).foregroundStyle(.secondary).monospacedDigit()
                    }
                    .font(.subheadline)
                    GeometryReader { g in
                        Capsule().fill(Palette.accentFill).frame(width: max(4, g.size.width * t.seconds / peak))
                    }
                    .frame(height: 6)
                }
            }
        }
    }

    private func value(_ r: AnalyticsReport) -> some View {
        let total = max(1, r.valueSeconds.values.reduce(0, +))
        let ratings: [(MeetingValue.Rating, String, Color)] = [(.high, "High", Palette.ok), (.medium, "Medium", Palette.bar), (.low, "Low", Palette.accentFill)]
        return Card {
            CardTitle(text: "Meeting value", symbol: "clock.badge.checkmark")
            Text("\(duration(r.valueSeconds[.low] ?? 0)) in meetings rated low").font(.headline)
            GeometryReader { g in
                HStack(spacing: 2) {
                    ForEach(ratings, id: \.1) { rating in
                        Rectangle().fill(rating.2).frame(width: max(0, g.size.width * (r.valueSeconds[rating.0] ?? 0) / total - 2))
                    }
                }
                .clipShape(.capsule)
            }
            .frame(height: 10)
            HStack(spacing: 12) {
                ForEach(ratings, id: \.1) { rating in
                    Text("\(rating.1) \(pct((r.valueSeconds[rating.0] ?? 0) / total))").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func people(_ r: AnalyticsReport) -> some View {
        Card {
            CardTitle(text: "People", symbol: "person.2")
            if r.people.isEmpty {
                Text("No named people in this period.").font(.subheadline).foregroundStyle(.secondary)
            }
            ForEach(r.people.prefix(8)) { p in
                NavigationLink(value: PersonLink(name: p.name)) {
                    HStack(spacing: 12) {
                        PersonMark(name: p.name, size: 34)
                        VStack(alignment: .leading, spacing: 5) {
                            HStack {
                                Text(p.name).font(.subheadline.weight(.medium)).foregroundStyle(.primary).lineLimit(1)
                                Spacer()
                                Text("\(p.calls) · \(duration(p.seconds))").font(.caption).foregroundStyle(.secondary).monospacedDigit()
                            }
                            PhoneBalance(mine: p.mySpeech, theirs: p.theirSpeech)
                        }
                        Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                    }
                }
            }
            Text("The bar is your share of the talking when you are both in the meeting.").font(.caption2).foregroundStyle(.tertiary)
        }
    }

    private var scoreChart: some View {
        Card {
            CardTitle(text: "Coach score", symbol: "star")
            Text(String(format: "%.1f average", Double(scores.map(\.score).reduce(0, +)) / Double(scores.count))).font(.headline)
            Chart(Array(scores.enumerated()), id: \.offset) { i, s in
                LineMark(x: .value("Meeting", i), y: .value("Score", s.score))
                PointMark(x: .value("Meeting", i), y: .value("Score", s.score)).foregroundStyle(scoreColor(s.score))
            }
            .chartYScale(domain: 1...5)
            .chartXAxis(.hidden)
            .frame(height: 120)
        }
    }

    private func averages(_ r: AnalyticsReport) -> String {
        func avg(_ s: AnalyticsReport.Slice) -> String { s.calls > 0 ? "\(Int(s.seconds / Double(s.calls) / 60)) min" : "–" }
        return "Scheduled meetings average \(avg(r.scheduled)); unscheduled \(avg(r.unscheduled))."
    }

    /// "+12% vs before", or nil when there is nothing to compare with.
    private func change(_ now: Double, _ before: Double) -> String? {
        guard before > 0 else { return nil }
        let p = Int(((now - before) / before * 100).rounded())
        return p == 0 ? "Same as before" : "\(p > 0 ? "+" : "")\(p)% vs before"
    }

    private func share(_ part: Int, _ whole: Int) -> Double { whole > 0 ? Double(part) / Double(whole) : 0 }
    private func pct(_ v: Double) -> String { "\(Int((v * 100).rounded()))%" }
    private func rate(_ v: Double?) -> String { v.map { String(format: "%.1f", $0) } ?? "–" }
}

private struct PersonLink: Hashable { let name: String }

/// Scheduled over unscheduled bars; drag across to read a day on a piece of glass.
private struct PhoneTimeChart: View {
    let report: AnalyticsReport
    @State private var hours = true
    @State private var selected: Date?

    private var unit: Calendar.Component {
        switch report.bucket { case .day: .day; case .week: .weekOfYear; case .month: .month }
    }

    var body: some View {
        let picked = selected.flatMap { s in report.days.last { $0.date <= s } }
        Card {
            HStack {
                CardTitle(text: "Time in meetings", symbol: "chart.bar")
                Spacer()
                Picker("Measure", selection: $hours) {
                    Text("Hours").tag(true)
                    Text("Meetings").tag(false)
                }
                .pickerStyle(.segmented).fixedSize()
            }
            Chart {
                ForEach(report.days) { bar in
                    BarMark(x: .value("Date", bar.date, unit: unit), y: .value("Amount", hours ? bar.scheduledSeconds / 3600 : Double(bar.scheduledCalls)))
                        .foregroundStyle(by: .value("Kind", "Scheduled"))
                        .opacity(picked == nil || picked?.date == bar.date ? 1 : 0.4)
                    BarMark(x: .value("Date", bar.date, unit: unit),
                            y: .value("Amount", hours ? (bar.seconds - bar.scheduledSeconds) / 3600 : Double(bar.calls - bar.scheduledCalls)))
                        .foregroundStyle(by: .value("Kind", "Unscheduled"))
                        .opacity(picked == nil || picked?.date == bar.date ? 1 : 0.4)
                }
                if let picked {
                    RuleMark(x: .value("Date", picked.date, unit: unit))
                        .foregroundStyle(.secondary.opacity(0.25))
                        .annotation(position: .top, spacing: 4, overflowResolution: .init(x: .fit(to: .chart), y: .disabled)) {
                            Text("\(picked.date.formatted(.dateTime.month(.abbreviated).day())) · \(duration(picked.seconds)) · \(picked.calls)")
                                .font(.caption.weight(.medium)).monospacedDigit()
                                .padding(.horizontal, 10).padding(.vertical, 5)
                                .glassEffect(.regular.interactive(), in: .capsule)
                                .fixedSize()
                        }
                }
            }
            .chartForegroundStyleScale(domain: ["Scheduled", "Unscheduled"], range: [Palette.accentFill, Palette.bar])
            .chartLegend(position: .bottom, alignment: .leading)
            .chartXSelection(value: $selected)
            .sensoryFeedback(.selection, trigger: picked?.date)
            .frame(height: 200)
            .animation(.smooth, value: hours)
        }
    }
}

private struct PhoneShareBar: View {
    let label: String
    let share: Double
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(label).font(.subheadline.weight(.medium))
                Spacer()
                Text(detail).font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
            GeometryReader { g in
                HStack(spacing: 2) {
                    Rectangle().fill(Palette.accentFill).frame(width: max(0, g.size.width * share - 1))
                        .overlay { if g.size.width * share > 40 { Text("\(Int((share * 100).rounded()))%").font(.caption2.weight(.semibold)).foregroundStyle(Palette.onAccent) } }
                    Rectangle().fill(Palette.bar)
                        .overlay { if g.size.width * (1 - share) > 40 { Text("\(Int(((1 - share) * 100).rounded()))%").font(.caption2.weight(.semibold)).foregroundStyle(Palette.ink) } }
                }
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            }
            .frame(height: 20)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(label): \(Int((share * 100).rounded())) percent scheduled, \(detail)")
    }
}

private struct PhoneBalance: View {
    let mine: TimeInterval
    let theirs: TimeInterval

    var body: some View {
        let total = mine + theirs
        let share = total > 0 ? mine / total : 0.5
        HStack(spacing: 6) {
            GeometryReader { g in
                HStack(spacing: 1) {
                    Rectangle().fill(Palette.accentFill).frame(width: g.size.width * share)
                    Rectangle().fill(Palette.bar)
                }
                .clipShape(.capsule)
            }
            .frame(height: 5)
            Text(total > 0 ? "You \(Int((share * 100).rounded()))%" : "–").font(.caption2).foregroundStyle(.secondary).monospacedDigit()
        }
    }
}

/// The phone's custom period: a start and an end on the system's calendars.
private struct CustomRangeSheet: View {
    @State var start: Date
    @State var end: Date
    let apply: (Date, Date) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                DatePicker("From", selection: $start, in: ...end, displayedComponents: .date).datePickerStyle(.graphical)
                DatePicker("To", selection: $end, in: start...Date(), displayedComponents: .date)
            }
            .navigationTitle("Custom range")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Apply") { apply(start, end) } }
            }
        }
        .presentationDetents([.large])
    }
}
