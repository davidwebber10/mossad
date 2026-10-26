import Charts
import MossadCore
import SwiftUI

/// One story for a period, against the period before: how much time, where it went, with whom, how you
/// communicated, what came out of it, and what it cost (docs/superpowers/specs/2026-10-26-design-overhaul.md).
struct AnalyticsView: View {
    @EnvironmentObject var controller: AppController
    @AppStorage("analyticsPreset") private var presetRaw = PeriodChoice.Preset.last30Days.rawValue
    @AppStorage("analyticsStart") private var startStamp = Date().addingTimeInterval(-13 * 86_400).timeIntervalSince1970
    @AppStorage("analyticsEnd") private var endStamp = Date().timeIntervalSince1970
    @State private var data: (now: AnalyticsReport, before: AnalyticsReport)?

    private var choice: Binding<PeriodChoice> {
        Binding {
            PeriodChoice(preset: PeriodChoice.Preset(rawValue: presetRaw) ?? .last30Days,
                         start: Date(timeIntervalSince1970: startStamp), end: Date(timeIntervalSince1970: endStamp))
        } set: {
            presetRaw = $0.preset.rawValue
            startStamp = $0.start.timeIntervalSince1970
            endStamp = $0.end.timeIntervalSince1970
        }
    }

    private var earliest: Date? { controller.meetings.map(\.start).min() }
    private var interval: DateInterval { choice.wrappedValue.range.interval(earliest: earliest) }

    var body: some View {
        ScrollViewReader { proxy in
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let data {
                    if data.now.calls == 0 {
                        ContentUnavailableView("No calls in this period", systemImage: "chart.bar.xaxis",
                                               description: Text("Pick a longer period, or wait for your next call."))
                            .padding(.top, 80)
                    } else {
                        content(data.now, data.before)
                    }
                } else {
                    ProgressView().frame(maxWidth: .infinity).padding(.vertical, 80)
                }
            }
            .padding(24)
            .frame(maxWidth: 1180)
            .frame(maxWidth: .infinity)
        }
        // Development hook for screenshots: MOSSAD_SCROLL_TO names a section heading.
        .onChange(of: data?.now.calls) { _, _ in
            if let target = ProcessInfo.processInfo.environment["MOSSAD_SCROLL_TO"] {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { proxy.scrollTo(target, anchor: .top) }
            }
        }
        }
        .background(Theme.background)
        .navigationTitle("Analytics")
        .navigationSubtitle(data.map { "Compared with \(periodText($0.before.interval))" } ?? "")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                DateRangeButton(choice: choice, interval: data?.now.interval ?? interval, earliest: earliest)
            }
        }
        .task(id: TaskKey(range: choice.wrappedValue.range, meetings: controller.meetings.count, coach: controller.coachVersion,
                          commitments: controller.commitmentsVersion)) { await load() }
    }

    private struct TaskKey: Equatable {
        let range: AnalyticsRange
        let meetings: Int
        let coach: Int
        let commitments: Int
    }

    /// Reads the usage log, the coach reviews, and the commitments off the main actor; all are files on disk.
    private func load() async {
        let records = controller.meetings, owner = controller.ownerName, usage = controller.usage, paths = controller.paths
        let range = choice.wrappedValue.range
        let commitments = controller.commitmentBook.visible
        let result = await Task.detached(priority: .userInitiated) {
            let events = usage.all()
            let interval = range.interval(earliest: records.map(\.start).min())
            let before = AnalyticsRange.previous(interval)
            let reviews = Dictionary(uniqueKeysWithValues: records.filter { interval.contains($0.start) }.compactMap { r in
                CoachReview.load(in: paths.callDirectory(r.id)).map { (r.id, $0) }
            })
            return (AnalyticsReport(records: records, usage: events, owner: owner, interval: interval, reviews: reviews, commitments: commitments),
                    AnalyticsReport(records: records, usage: events, owner: owner, interval: before, commitments: commitments))
        }.value
        withAnimation(.smooth) { data = result }
    }

    // MARK: Content

    @ViewBuilder
    private func content(_ r: AnalyticsReport, _ b: AnalyticsReport) -> some View {
        let weeks = max(1, r.interval.duration / (7 * 86_400))
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 4), spacing: 12) {
            Metric(title: "Time in calls", value: hours(r.callSeconds), change: .percent(r.callSeconds, b.callSeconds),
                   detail: "\(hours(r.callSeconds / weeks)) a week")
            Metric(title: "Calls", value: "\(r.calls)", change: .percent(Double(r.calls), Double(b.calls)),
                   detail: "\(Int((Double(r.calls) / weeks).rounded())) a week")
            Metric(title: "Scheduled", value: percent(share(r.scheduled.calls, r.calls)),
                   change: .points(share(r.scheduled.calls, r.calls), b.calls > 0 ? share(b.scheduled.calls, b.calls) : nil),
                   detail: "\(percent(r.scheduled.seconds / max(r.callSeconds, 1))) of call time")
            Metric(title: "Your talk share", value: r.talkShare.map(percent) ?? "–", change: .points(r.talkShare, b.talkShare),
                   detail: [r.communication.oneOnOneShare.map { "1:1 \(percent($0))" }, r.communication.groupShare.map { "groups \(percent($0))" }]
                    .compactMap { $0 }.joined(separator: " · "))
        }

        SectionHeading(title: "Your time")
        WeightedColumns(weights: [2, 1]) {
            TimeCard(report: r)
            Card("Scheduled and unscheduled") { ScheduledCard(report: r, before: b) }
        }

        SectionHeading(title: "Your week")
        WeightedColumns(weights: [2, 1]) {
            Card("When you meet") { HeatChart(cells: r.heat) }
            Card("Work days") { WorkdayCard(workday: r.workday) }
        }

        SectionHeading(title: "What you meet about")
        WeightedColumns(weights: [2, 1]) {
            Card("Topics") { TopicsChart(slices: r.tags) }
            Card("Meeting value") { ValueCard(report: r) }
        }

        SectionHeading(title: "Who you meet with")
        Card("People", accessory: {
            Button("See all") { controller.open(.people) }.buttonStyle(.link).font(.subheadline)
        }) { PeopleTable(report: r) }

        SectionHeading(title: "How you communicate")
        CommunicationRow(report: r)

        SectionHeading(title: "Outcomes")
        OutcomesCard(outcomes: r.outcomes, before: b.outcomes)

        CostsDisclosure(report: r)
    }
}

func hours(_ seconds: TimeInterval) -> String {
    let m = Int(seconds / 60)
    return m >= 60 ? "\(m / 60)h \(m % 60)m" : "\(m)m"
}

func money(_ dollars: Double) -> String {
    dollars.formatted(.currency(code: "USD").precision(.fractionLength(dollars < 10 ? 2 : 0)))
}

private func percent(_ share: Double) -> String { "\(Int((share * 100).rounded()))%" }
private func share(_ part: Int, _ whole: Int) -> Double { whole > 0 ? Double(part) / Double(whole) : 0 }

private enum Measure: String, CaseIterable { case hours = "Hours", calls = "Calls" }

private let scheduledColor = Color.accentColor
private let unscheduledColor = Color(nsColor: .systemGray)

// MARK: Tiles

private struct Metric: View {
    enum Change {
        case percent(Double, Double)
        /// Percentage points, for shares; nil when either side is unknown.
        case points(Double?, Double?)

        var value: (Double, String)? {
            switch self {
            case .percent(let now, let before): before > 0 ? ((now - before) / before * 100, "%") : nil
            case .points(let now, let before): now.flatMap { n in before.map { ((n - $0) * 100, " pt") } }
            }
        }
    }

    let title: String
    let value: String
    let change: Change?
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.subheadline).foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(value)
                    .font(.system(.title, design: .rounded, weight: .semibold)).monospacedDigit()
                    .contentTransition(.numericText())
                    .lineLimit(1).minimumScaleFactor(0.7)
                if let c = change?.value { chip(c.0, c.1) }
            }
            Text(detail.isEmpty ? " " : detail).font(.footnote).foregroundStyle(.secondary).lineLimit(1)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.separator.opacity(0.6), lineWidth: 0.5))
        .accessibilityElement(children: .combine)
    }

    private func chip(_ n: Double, _ unit: String) -> some View {
        let flat = abs(n) < 0.5
        return HStack(spacing: 2) {
            Image(systemName: flat ? "equal" : n > 0 ? "arrow.up" : "arrow.down").font(.caption2.weight(.bold))
            Text("\(Int(abs(n).rounded()))\(unit)").font(.caption.weight(.semibold)).monospacedDigit()
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 6).padding(.vertical, 2)
        .background(Theme.field, in: Capsule())
        .help("Compared with the period before")
    }
}

/// Numbers in a row inside one card: the value large, a label under it.
private struct StatCell: View {
    let value: String
    let label: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.system(.title3, design: .rounded, weight: .semibold)).monospacedDigit().contentTransition(.numericText())
            Text(label).font(.footnote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

// MARK: Time

private struct TimeCard: View {
    let report: AnalyticsReport
    @State private var measure = Measure.hours

    var body: some View {
        Card("Time in calls", accessory: {
            Picker("Measure", selection: $measure) { ForEach(Measure.allCases, id: \.self) { Text($0.rawValue) } }
                .pickerStyle(.segmented).labelsHidden().fixedSize().controlSize(.small)
        }) {
            TimeChart(report: report, measure: measure)
        }
    }
}

/// Scheduled over unscheduled bars per bucket. Drag or point across it: a glass label follows the pointer
/// with the bucket's numbers, and the chart lifts slightly while it does.
private struct TimeChart: View {
    let report: AnalyticsReport
    let measure: Measure
    @State private var selected: Date?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var unit: Calendar.Component {
        switch report.bucket { case .day: .day; case .week: .weekOfYear; case .month: .month }
    }

    var body: some View {
        let bars = report.days
        let picked = selected.flatMap { s in bars.last { $0.date <= s } }
        Chart {
            ForEach(bars) { bar in
                BarMark(x: .value("Date", bar.date, unit: unit), y: .value(measure.rawValue, scheduled(bar)))
                    .foregroundStyle(by: .value("Kind", "Scheduled"))
                    .cornerRadius(3)
                    .opacity(picked == nil || picked?.date == bar.date ? 1 : 0.4)
                BarMark(x: .value("Date", bar.date, unit: unit), y: .value(measure.rawValue, total(bar) - scheduled(bar)))
                    .foregroundStyle(by: .value("Kind", "Unscheduled"))
                    .cornerRadius(3)
                    .opacity(picked == nil || picked?.date == bar.date ? 1 : 0.4)
            }
            if let picked {
                RuleMark(x: .value("Date", picked.date, unit: unit))
                    .foregroundStyle(.secondary.opacity(0.25))
                    .lineStyle(StrokeStyle(lineWidth: 1))
                    .annotation(position: .top, spacing: 4, overflowResolution: .init(x: .fit(to: .chart), y: .disabled)) {
                        ScrubLabel(text: "\(label(picked.date)) · \(hours(picked.seconds)) · \(picked.calls) \(picked.calls == 1 ? "call" : "calls")")
                    }
            }
        }
        .chartForegroundStyleScale(domain: ["Scheduled", "Unscheduled"], range: [scheduledColor, unscheduledColor])
        .chartLegend(position: .bottom, alignment: .leading)
        .chartXSelection(value: $selected)
        .chartYAxis {
            AxisMarks(position: .leading) { v in
                AxisGridLine().foregroundStyle(.primary.opacity(0.08))
                AxisValueLabel {
                    if let n = v.as(Double.self) {
                        Text(measure == .calls ? "\(Int(n))" : n >= 60 ? "\(Int(n / 60))h" : "\(Int(n))m")
                    }
                }
            }
        }
        .frame(height: 220)
        .scaleEffect(picked != nil && !reduceMotion ? 1.004 : 1)
        .animation(.snappy, value: picked?.date)
        .animation(.smooth, value: measure)
        .accessibilityLabel("Time in calls, \(hours(report.callSeconds)) in \(report.calls) calls")
    }

    private func total(_ bar: AnalyticsReport.Bar) -> Double { measure == .hours ? bar.seconds / 60 : Double(bar.calls) }
    private func scheduled(_ bar: AnalyticsReport.Bar) -> Double { measure == .hours ? bar.scheduledSeconds / 60 : Double(bar.scheduledCalls) }

    private func label(_ d: Date) -> String {
        switch report.bucket {
        case .day: d.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
        case .week: "Week of " + d.formatted(.dateTime.month(.abbreviated).day())
        case .month: d.formatted(.dateTime.month(.wide).year())
        }
    }
}

/// The value under the pointer on a chart, on a small piece of glass.
private struct ScrubLabel: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.caption.weight(.medium)).monospacedDigit()
            .padding(.horizontal, 10).padding(.vertical, 5)
            .glassEffect(.regular.interactive(), in: .capsule)
            .fixedSize()
    }
}

/// Two bars: the share of calls that were scheduled, and the share of call time.
private struct ScheduledCard: View {
    let report: AnalyticsReport
    let before: AnalyticsReport

    var body: some View {
        let r = report
        VStack(alignment: .leading, spacing: 14) {
            ShareBar(label: "Calls", share: share(r.scheduled.calls, r.calls),
                     detail: "\(r.scheduled.calls) of \(r.calls)")
            ShareBar(label: "Time", share: r.callSeconds > 0 ? r.scheduled.seconds / r.callSeconds : 0,
                     detail: "\(hours(r.scheduled.seconds)) of \(hours(r.callSeconds))")
            HStack(spacing: 12) {
                legend("Scheduled", scheduledColor)
                legend("Unscheduled", unscheduledColor)
            }
            Text(averages).font(.footnote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .help("Scheduled means Mossad matched the call to a calendar invite.")
    }

    private var averages: String {
        func avg(_ s: AnalyticsReport.Slice) -> String { s.calls > 0 ? "\(Int(s.seconds / Double(s.calls) / 60)) min" : "–" }
        return "Scheduled calls average \(avg(report.scheduled)); unscheduled \(avg(report.unscheduled))."
    }

    private func legend(_ text: String, _ color: Color) -> some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(text)
        }
        .font(.footnote).foregroundStyle(.secondary)
    }
}

private struct ShareBar: View {
    let label: String
    let share: Double
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(label).font(.callout.weight(.medium))
                Spacer()
                Text(detail).font(.footnote).foregroundStyle(.secondary).monospacedDigit()
            }
            GeometryReader { g in
                HStack(spacing: 2) {
                    segment(share, scheduledColor, width: g.size.width)
                    segment(1 - share, unscheduledColor, width: g.size.width)
                }
            }
            .frame(height: 22)
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(label): \(percent(share)) scheduled, \(detail)")
    }

    @ViewBuilder
    private func segment(_ part: Double, _ color: Color, width: CGFloat) -> some View {
        let w = max(0, width * part - 1)
        Rectangle().fill(color)
            .frame(width: w)
            .overlay {
                if w > 34 { Text(percent(part)).font(.caption.weight(.semibold)).monospacedDigit().foregroundStyle(.white) }
            }
    }
}

// MARK: Week

private struct HeatChart: View {
    let cells: [AnalyticsReport.HeatCell]

    var body: some View {
        // Working hours always show; the grid grows to fit early or late calls.
        let hoursUsed = cells.filter { $0.seconds > 0 }.map(\.hour)
        let first = min(8, hoursUsed.min() ?? 8), last = max(18, hoursUsed.max() ?? 18)
        let peak = cells.map(\.seconds).max() ?? 1
        let days = [2, 3, 4, 5, 6, 7, 1]
        Chart {
            ForEach(days, id: \.self) { day in
                ForEach(first...last, id: \.self) { hour in
                    let s = cells.first { $0.weekday == day && $0.hour == hour }?.seconds ?? 0
                    RectangleMark(x: .value("Hour", hourLabel(hour)), y: .value("Day", dayLabel(day)), width: .ratio(0.9), height: .fixed(24))
                        .foregroundStyle(s == 0 ? Theme.field : Color.accentColor.opacity(0.25 + 0.75 * s / peak))
                        .cornerRadius(4)
                }
            }
        }
        .chartXScale(domain: (first...last).map(hourLabel))
        .chartYScale(domain: days.map(dayLabel))
        .chartXAxis { AxisMarks { _ in AxisValueLabel().font(.caption2) } }
        .chartYAxis { AxisMarks(position: .leading) { _ in AxisValueLabel().font(.caption) } }
        .frame(height: 7 * 30)
        .accessibilityLabel("Time in calls by weekday and hour")
    }

    private func hourLabel(_ h: Int) -> String { h == 0 ? "12a" : h < 12 ? "\(h)a" : h == 12 ? "12p" : "\(h - 12)p" }
    private func dayLabel(_ d: Int) -> String { Calendar.current.shortWeekdaySymbols[d - 1] }
}

private struct WorkdayCard: View {
    let workday: AnalyticsReport.Workday

    var body: some View {
        let w = workday
        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 18) {
            GridRow {
                StatCell(value: hours(w.hoursPerWorkday * 3600), label: "in calls per work day")
                StatCell(value: percent(w.coreHoursShare), label: "of 8 to 6 in calls")
            }
            GridRow {
                StatCell(value: w.backToBackShare.map(percent) ?? "–", label: "calls back to back")
                StatCell(value: "\(w.callFreeDays) of \(w.workdays)", label: "work days with no calls")
            }
        }
    }
}

// MARK: Topics and value

private struct TopicsChart: View {
    @EnvironmentObject var controller: AppController
    let slices: [AnalyticsReport.Slice]

    var body: some View {
        if slices.isEmpty {
            Text("Topics come with each summary. Older calls get theirs when Mossad summarizes them again.")
                .font(.callout).foregroundStyle(.secondary)
        } else {
            let top = Array(slices.prefix(10))
            let peak = max(top.first?.seconds ?? 1, 1)
            VStack(alignment: .leading, spacing: 4) {
                ForEach(top) { s in
                    Button { controller.showTag(s.name) } label: {
                        HStack(spacing: 12) {
                            Text(s.name).lineLimit(1).frame(width: 170, alignment: .leading)
                            GeometryReader { g in
                                Capsule().fill(Color.accentColor.opacity(0.85))
                                    .frame(width: max(4, g.size.width * s.seconds / peak), height: 8)
                                    .frame(maxHeight: .infinity)
                            }
                            Text(hours(s.seconds)).foregroundStyle(.secondary).monospacedDigit().frame(width: 60, alignment: .trailing)
                        }
                        .font(.callout)
                        .frame(height: 26)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("\(s.calls) \(s.calls == 1 ? "meeting" : "meetings") tagged \(s.name). Click to see them.")
                }
            }
        }
    }
}

/// How much of the coached call time the coach rated worth it, and the meetings to change first.
private struct ValueCard: View {
    @EnvironmentObject var controller: AppController
    let report: AnalyticsReport

    private static let ratings: [(MeetingValue.Rating, String, Color)] = [(.high, "High", .green), (.medium, "Medium", .gray), (.low, "Low", Theme.warning)]

    var body: some View {
        if report.valueSeconds.isEmpty {
            Text("The coach rates each meeting's worth. Ratings show here after a few coached calls.")
                .font(.callout).foregroundStyle(.secondary)
        } else {
            let total = max(report.valueSeconds.values.reduce(0, +), 1)
            VStack(alignment: .leading, spacing: 12) {
                StatCell(value: hours(report.valueSeconds[.low] ?? 0), label: "in meetings rated low")
                GeometryReader { g in
                    HStack(spacing: 2) {
                        ForEach(Self.ratings, id: \.1) { r in
                            Rectangle().fill(r.2).frame(width: max(0, g.size.width * (report.valueSeconds[r.0] ?? 0) / total - 2))
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                }
                .frame(height: 10)
                HStack(spacing: 12) {
                    ForEach(Self.ratings, id: \.1) { r in
                        HStack(spacing: 5) {
                            Circle().fill(r.2).frame(width: 7, height: 7)
                            Text("\(r.1) \(percent((report.valueSeconds[r.0] ?? 0) / total))").monospacedDigit()
                        }
                    }
                }
                .font(.footnote).foregroundStyle(.secondary)
                if !report.lowValueRepeats.isEmpty {
                    Divider()
                    Text("Rated low more than once").font(.footnote.weight(.semibold)).foregroundStyle(.secondary)
                    ForEach(report.lowValueRepeats.prefix(4)) { s in
                        Button { controller.meetingQuery = s.name; controller.open(.meetings) } label: {
                            HStack {
                                Text(s.name).lineLimit(1)
                                Spacer()
                                Text("\(s.calls)×").foregroundStyle(.secondary).monospacedDigit()
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .font(.callout)
                    }
                }
            }
        }
    }
}

// MARK: People

/// The top people by time together: calls, time, share of your call time, talk balance, trend, and last met.
private struct PeopleTable: View {
    @EnvironmentObject var controller: AppController
    let report: AnalyticsReport
    @State private var hovered: String?

    var body: some View {
        let people = Array(report.people.prefix(8))
        if people.isEmpty {
            Text("No named people in this period.").font(.callout).foregroundStyle(.secondary)
        } else {
            VStack(spacing: 0) {
                row(name: Text("Name"), calls: Text("Calls"), time: Text("Time"), share: Text("Of your time"),
                    balance: AnyView(Text("Talk balance")), trend: AnyView(Text("Trend")), last: Text("Last met"))
                    .font(.footnote).foregroundStyle(.secondary)
                    .padding(.bottom, 6)
                Divider()
                ForEach(people) { p in
                    Button { controller.openPerson(p.name) } label: {
                        row(name: Text(p.name).fontWeight(.medium), calls: Text("\(p.calls)"), time: Text(hours(p.seconds)),
                            share: Text(percent(p.seconds / max(report.callSeconds, 1))),
                            balance: AnyView(BalanceBar(mine: p.mySpeech, theirs: p.theirSpeech)),
                            trend: AnyView(Sparkline(values: p.trend).frame(height: 18)),
                            last: Text(p.lastMet.map { $0.formatted(.relative(presentation: .named)) } ?? "–").foregroundStyle(.secondary))
                            .font(.callout).monospacedDigit()
                            .padding(.vertical, 8)
                            .background(hovered == p.name ? Theme.hover : .clear, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .onHover { hovered = $0 ? p.name : (hovered == p.name ? nil : hovered) }
                    .help("Open \(p.name)")
                }
            }
        }
    }

    private func row(name: Text, calls: Text, time: Text, share: Text, balance: AnyView, trend: AnyView, last: Text) -> some View {
        HStack(spacing: 16) {
            name.lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
            calls.frame(width: 44, alignment: .trailing)
            time.frame(width: 64, alignment: .trailing)
            share.frame(width: 84, alignment: .trailing)
            balance.frame(width: 150, alignment: .leading)
            trend.frame(width: 90, alignment: .leading)
            last.lineLimit(1).frame(width: 100, alignment: .leading)
        }
        .padding(.horizontal, 6)
    }
}

/// You against them in the calls you shared: your part in the accent color, theirs in gray.
struct BalanceBar: View {
    let mine: TimeInterval
    let theirs: TimeInterval
    var showsShare = true

    var body: some View {
        let total = mine + theirs
        let share = total > 0 ? mine / total : 0.5
        HStack(spacing: 6) {
            GeometryReader { g in
                HStack(spacing: 1) {
                    Rectangle().fill(Color.accentColor).frame(width: g.size.width * share)
                    Rectangle().fill(unscheduledColor.opacity(0.5))
                }
                .clipShape(Capsule())
            }
            .frame(height: 6)
            if showsShare {
                Text(total > 0 ? percent(share) : "–").font(.caption).foregroundStyle(.secondary).monospacedDigit().frame(width: 32, alignment: .trailing)
            }
        }
        .help("Your share of the talking when you are both in the call")
        .accessibilityLabel(total > 0 ? "You talk \(percent(share)) of the time together" : "No speech together")
    }
}

private struct Sparkline: View {
    let values: [Int]

    /// At most 12 bars: 30 daily buckets would be thin and mostly empty.
    private var bars: [Int] {
        guard values.count > 12 else { return values }
        let size = Int((Double(values.count) / 12).rounded(.up))
        return stride(from: 0, to: values.count, by: size).map { values[$0..<min($0 + size, values.count)].reduce(0, +) }
    }

    var body: some View {
        Chart(Array(bars.enumerated()), id: \.offset) { i, v in
            BarMark(x: .value("Bucket", String(i)), y: .value("Calls", v), width: .ratio(0.6))
                .foregroundStyle(v > 0 ? Color.accentColor.opacity(0.8) : Theme.field)
                .cornerRadius(1)
        }
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .chartYScale(domain: 0...max(1, bars.max() ?? 1))
        .accessibilityHidden(true)
    }
}

// MARK: Communication

private struct CommunicationRow: View {
    let report: AnalyticsReport

    var body: some View {
        let c = report.communication
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 4), spacing: 12) {
            MiniTrend(title: "Talk share", value: report.talkShare.map(percent) ?? "–",
                      detail: [c.oneOnOneShare.map { "1:1 \(percent($0))" }, c.groupShare.map { "groups \(percent($0))" }].compactMap { $0 }.joined(separator: " · "),
                      points: c.points.compactMap { p in p.talkShare.map { (p.date, $0 * 100) } })
            MiniTrend(title: "Questions you ask", value: rate(c.questionsPerHour), detail: "an hour of calls",
                      points: c.points.map { ($0.date, $0.questionsPerHour) })
            MiniTrend(title: "You cut in", value: rate(c.interruptionsMadePerHour),
                      detail: "an hour · others cut in \(rate(c.interruptionsReceivedPerHour))",
                      points: c.points.map { ($0.date, $0.interruptionsPerHour) })
            MiniTrend(title: "Pace", value: report.delivery.isEmpty ? "–" : "\(Int(report.delivery.map(\.wordsPerMinute).reduce(0, +) / Double(report.delivery.count)))",
                      detail: "words a minute", points: report.delivery.map { ($0.date, $0.wordsPerMinute) })
        }
    }

    private func rate(_ v: Double?) -> String { v.map { String(format: "%.1f", $0) } ?? "–" }
}

/// One number with its trend across the period's calls, and a dashed line at the median.
private struct MiniTrend: View {
    let title: String
    let value: String
    let detail: String
    let points: [(Date, Double)]

    var body: some View {
        Card(title) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(value).font(.system(.title2, design: .rounded, weight: .semibold)).monospacedDigit().contentTransition(.numericText())
                    Text(detail).font(.footnote).foregroundStyle(.secondary).lineLimit(2)
                }
                if points.count >= 2 {
                    let mid = points.map(\.1).sorted()[points.count / 2]
                    Chart {
                        // One step per call, in order: calls hours apart would bunch up on a time axis.
                        ForEach(Array(points.enumerated()), id: \.offset) { i, p in
                            AreaMark(x: .value("Call", i), y: .value(title, p.1))
                                .foregroundStyle(LinearGradient(colors: [Color.accentColor.opacity(0.22), Color.accentColor.opacity(0)],
                                                                startPoint: .top, endPoint: .bottom))
                            LineMark(x: .value("Call", i), y: .value(title, p.1))
                                .foregroundStyle(Color.accentColor)
                                .lineStyle(StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
                        }
                        RuleMark(y: .value("Median", mid))
                            .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                            .foregroundStyle(.secondary.opacity(0.6))
                    }
                    .chartXAxis(.hidden)
                    .chartYAxis(.hidden)
                    .chartYScale(domain: .automatic(includesZero: true))
                    .frame(height: 56)
                    .accessibilityHidden(true)
                } else {
                    Text("Shows after a few calls.").font(.footnote).foregroundStyle(.tertiary).frame(height: 56, alignment: .top)
                }
            }
        }
    }
}

// MARK: Outcomes

private struct OutcomesCard: View {
    let outcomes: AnalyticsReport.Outcomes
    let before: AnalyticsReport.Outcomes

    var body: some View {
        let o = outcomes
        Card("What came out of your calls") {
            HStack(alignment: .top, spacing: 16) {
                StatCell(value: String(format: "%.1f", o.itemsPerHour), label: "action items an hour")
                StatCell(value: String(format: "%.1f", o.decisionsPerHour), label: "decisions an hour")
                StatCell(value: o.withOutcomesShare.map(percent) ?? "–", label: "of calls with an item or a decision")
                StatCell(value: "\(o.mine) · \(o.others)", label: "items yours · others'")
                StatCell(value: o.commitmentsMade > 0 ? "\(o.commitmentsDone) of \(o.commitmentsMade)" : "–", label: "of your commitments done")
            }
        }
    }
}

// MARK: Costs

private struct CostsDisclosure: View {
    let report: AnalyticsReport
    @AppStorage("analyticsCostsOpen") private var open = false

    var body: some View {
        DisclosureGroup(isExpanded: $open) {
            Card("API costs") { CostSection(report: report) }.padding(.top, 8)
        } label: {
            SectionHeading(title: "Costs", detail: "\(money(report.cost.total)) · \(money(report.cost.perCall)) a call")
        }
    }
}

private struct CostSection: View {
    let report: AnalyticsReport

    private static let allServices: [(UsageEvent.Service, String, Color)] = [
        (.assemblyai, "AssemblyAI", Color(hex: 0x2545d3)), (.deepgram, "Deepgram", Color(hex: 0x13ef93)), (.elevenlabs, "ElevenLabs", Color(hex: 0x8e8e93)),
        (.claude, "Claude", Color(hex: 0xd97757)), (.openai, "OpenAI", Color(hex: 0x10a37f)), (.openrouter, "OpenRouter", Color(hex: 0x6467f2)),
    ]

    /// Only the services that cost something in this period, so the legend stays short.
    private var services: [(UsageEvent.Service, String, Color)] {
        Self.allServices.filter { (report.cost.byService[$0.0] ?? 0) > 0 }
    }
    private static let purposes: [(UsageEvent.Purpose, String)] = [
        (.transcription, "Transcription"), (.live, "Live transcript"), (.summary, "Summaries"), (.coach, "Coach reviews"), (.weeklyEmail, "Weekly email"), (.question, "Questions"),
    ]

    private var unit: Calendar.Component {
        switch report.bucket { case .day: .day; case .week: .weekOfYear; case .month: .month }
    }

    var body: some View {
        let c = report.cost
        let days = max(1, report.interval.duration / 86_400)
        HStack(alignment: .top, spacing: 24) {
            VStack(alignment: .leading, spacing: 14) {
                StatCell(value: money(c.total), label: "About \(money(c.total / days * 30)) a month at this rate")
                VStack(alignment: .leading, spacing: 6) {
                    row("Per call", money(c.perCall))
                    row("Per hour of calls", money(c.perCallHour))
                    ForEach(services, id: \.1) { s in row(s.1, money(c.byService[s.0] ?? 0), dot: s.2) }
                }
                Divider()
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Self.purposes.filter { (c.byPurpose[$0.0] ?? 0) > 0 }, id: \.1) { p in row(p.1, money(c.byPurpose[p.0] ?? 0)) }
                }
                if c.estimatedShare > 0.01 {
                    Text("\(percent(c.estimatedShare)) is estimated from call length and transcript size, for calls from before Mossad logged usage.")
                        .font(.footnote).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(width: 260)
            Chart {
                ForEach(report.days) { bar in
                    ForEach(services, id: \.1) { s in
                        BarMark(x: .value("Date", bar.date, unit: unit), y: .value("Cost", bar.cost[s.0] ?? 0))
                            .foregroundStyle(by: .value("Service", s.1))
                            .cornerRadius(2)
                    }
                }
            }
            .chartForegroundStyleScale(domain: services.map(\.1), range: services.map(\.2))
            .chartLegend(position: .top, alignment: .trailing)
            .chartYAxis {
                AxisMarks(position: .leading) { v in
                    AxisGridLine().foregroundStyle(.primary.opacity(0.08))
                    AxisValueLabel { if let d = v.as(Double.self) { Text(money(d)) } }
                }
            }
            .frame(height: 240)
        }
    }

    private func row(_ title: String, _ value: String, dot: Color? = nil) -> some View {
        HStack(spacing: 8) {
            if let dot { Circle().fill(dot).frame(width: 8, height: 8) }
            Text(title).foregroundStyle(.secondary)
            Spacer()
            Text(value).monospacedDigit()
        }
        .font(.callout)
    }
}
