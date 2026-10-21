import Charts
import MossadCore
import SwiftUI

/// Time in calls, who and when you meet, delivery trends, and what AssemblyAI and Claude cost, for a chosen period
/// compared with the period before it.
struct AnalyticsView: View {
    @EnvironmentObject var controller: AppController
    @AppStorage("analyticsRange") private var preset = Preset.last30Days
    @State private var customStart = Calendar.current.date(byAdding: .day, value: -13, to: Date()) ?? Date()
    @State private var customEnd = Date()
    @State private var showCustom = false
    @State private var data: (now: AnalyticsReport, before: AnalyticsReport)?

    enum Preset: String, CaseIterable, Identifiable {
        case last7Days = "7D", last30Days = "30D", last90Days = "90D", thisMonth = "Month", yearToDate = "YTD", all = "All", custom = "Custom"
        var id: String { rawValue }
        var help: String {
            switch self {
            case .last7Days: "The last 7 days"
            case .last30Days: "The last 30 days"
            case .last90Days: "The last 90 days"
            case .thisMonth: "This month"
            case .yearToDate: "This year"
            case .all: "All calls"
            case .custom: "Pick the dates"
            }
        }
    }

    private var range: AnalyticsRange {
        switch preset {
        case .last7Days: .last7Days
        case .last30Days: .last30Days
        case .last90Days: .last90Days
        case .thisMonth: .thisMonth
        case .yearToDate: .yearToDate
        case .all: .all
        case .custom: .custom(min(customStart, customEnd), max(customStart, customEnd))
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                header
                if let data {
                    if data.now.calls == 0 {
                        DetailEmptyState(symbol: "chart.bar.xaxis", title: "No calls in this period", message: "Pick a longer period, or wait for your next call.")
                    } else {
                        content(data.now, data.before)
                    }
                } else {
                    ProgressView().frame(maxWidth: .infinity).padding(.vertical, 80)
                }
            }
            .padding(EdgeInsets(top: 12, leading: 24, bottom: 24, trailing: 24))
            .frame(maxWidth: 1180)
            .frame(maxWidth: .infinity)
        }
        .background(Theme.background)
        .task(id: TaskKey(range: range, meetings: controller.meetings.count, coach: controller.coachVersion)) { await load() }
    }

    private struct TaskKey: Equatable {
        let range: AnalyticsRange
        let meetings: Int
        let coach: Int
    }

    /// Reads the usage log and the coach reviews off the main actor; both are files on disk.
    private func load() async {
        let records = controller.meetings, owner = controller.ownerName, usage = controller.usage, paths = controller.paths
        let range = range
        data = await Task.detached(priority: .userInitiated) {
            let events = usage.all()
            let interval = range.interval(earliest: records.map(\.start).min())
            let before = AnalyticsRange.previous(interval)
            let reviews = Dictionary(uniqueKeysWithValues: records.filter { interval.contains($0.start) }.compactMap { r in
                CoachReview.load(in: paths.callDirectory(r.id)).map { (r.id, $0) }
            })
            return (AnalyticsReport(records: records, usage: events, owner: owner, interval: interval, reviews: reviews),
                    AnalyticsReport(records: records, usage: events, owner: owner, interval: before))
        }.value
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Analytics").font(.system(size: 18, weight: .bold)).kerning(-0.3)
                if let data {
                    Text("\(period(data.now.interval)) · compared with \(period(data.before.interval))")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }
            }
            Spacer()
            Picker("Period", selection: $preset) {
                ForEach(Preset.allCases) { Text($0.rawValue).help($0.help).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .onChange(of: preset) { _, p in if p == .custom { showCustom = true } }
            .popover(isPresented: $showCustom, arrowEdge: .bottom) { customPicker }
        }
        .padding(.top, 8)
    }

    private var customPicker: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Custom period").font(.system(size: 13, weight: .semibold))
            DatePicker("From", selection: $customStart, in: ...Date(), displayedComponents: .date)
            DatePicker("To", selection: $customEnd, in: ...Date(), displayedComponents: .date)
            HStack {
                Spacer()
                Button("Done") { showCustom = false }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 260)
    }

    private func period(_ i: DateInterval) -> String {
        let end = i.end.addingTimeInterval(-1)
        let sameYear = Calendar.current.isDate(i.start, equalTo: end, toGranularity: .year)
        let start = sameYear ? i.start.formatted(.dateTime.month(.abbreviated).day()) : i.start.formatted(.dateTime.month(.abbreviated).day().year())
        return "\(start) – \(end.formatted(.dateTime.month(.abbreviated).day().year()))"
    }

    // MARK: Content

    @ViewBuilder
    private func content(_ r: AnalyticsReport, _ before: AnalyticsReport) -> some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 5), spacing: 12) {
            Metric(title: "Time in calls", value: hours(r.callSeconds), change: change(r.callSeconds, before.callSeconds),
                   detail: "\(hours(r.callSeconds / max(1, r.interval.duration / (7 * 86_400)))) a week")
            Metric(title: "Calls", value: "\(r.calls)", change: change(Double(r.calls), Double(before.calls)),
                   detail: "\(r.actionItems) action items")
            Metric(title: "Average length", value: "\(Int(r.averageSeconds / 60)) min", change: change(r.averageSeconds, before.averageSeconds),
                   detail: r.longest.map { "Longest: \(Int($0.end.timeIntervalSince($0.start) / 60)) min" } ?? "")
            Metric(title: "Your talk share", value: r.talkShare.map { "\(Int(($0 * 100).rounded()))%" } ?? "–",
                   change: r.talkShare.flatMap { now in before.talkShare.map { (now - $0) * 100 } }.map { .points($0) },
                   detail: "of all speech")
            Metric(title: "API cost", value: money(r.cost.total), change: change(r.cost.total, before.cost.total), lowerIsBetter: true,
                   detail: r.cost.estimatedShare > 0.01 ? "\(Int((r.cost.estimatedShare * 100).rounded()))% estimated" : "\(money(r.cost.perCall)) per call")
        }
        HStack(alignment: .top, spacing: 12) {
            Card("Time in calls") { TimeChart(report: r) }
                .frame(maxWidth: .infinity)
            Card("Platforms") { PlatformChart(slices: r.platforms) }
                .frame(width: 300)
        }
        HStack(alignment: .top, spacing: 12) {
            Card("When you meet") { HeatChart(cells: r.heat) }
                .frame(maxWidth: .infinity)
            Card("Who you meet with") { PeopleList(people: r.people, total: r.callSeconds) }
                .frame(width: 300)
        }
        Card("API costs") { CostSection(report: r) }
        Card("Topics") { TopicsChart(slices: r.tags) }
        if !r.valueSeconds.isEmpty { Card("Meeting value") { ValueSection(report: r) } }
        HStack(alignment: .top, spacing: 12) {
            Card("Meeting kinds") { KindsChart(slices: r.kinds) }
                .frame(width: 380)
            Card("Your delivery") { DeliveryChart(points: r.delivery) }
                .frame(maxWidth: .infinity)
        }
    }

    private func change(_ now: Double, _ before: Double) -> Metric.Change? {
        before > 0 ? .percent((now - before) / before * 100) : nil
    }
}

func hours(_ seconds: TimeInterval) -> String {
    let m = Int(seconds / 60)
    return m >= 60 ? "\(m / 60)h \(m % 60)m" : "\(m)m"
}

func money(_ dollars: Double) -> String {
    dollars.formatted(.currency(code: "USD").precision(.fractionLength(dollars < 10 ? 2 : 0)))
}

// MARK: Metric tile

private struct Metric: View {
    enum Change {
        case percent(Double)
        /// Percentage points, for shares.
        case points(Double)
    }

    let title: String
    let value: String
    let change: Change?
    var lowerIsBetter = false
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(value).font(.system(size: 24, weight: .semibold)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.7)
                if let change { chip(change) }
            }
            Text(detail.isEmpty ? " " : detail).font(.system(size: 11)).foregroundStyle(.tertiary).lineLimit(1)
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .shadow(color: .black.opacity(0.05), radius: 1, y: 1)
        .accessibilityElement(children: .combine)
    }

    private func chip(_ c: Change) -> some View {
        let (n, unit): (Double, String) = switch c {
        case .percent(let p): (p, "%")
        case .points(let p): (p, " pt")
        }
        let flat = abs(n) < 0.5
        // More time in calls is neither good nor bad; only cost has a direction worth a color.
        let tint: Color = flat || !lowerIsBetter ? .secondary : (n < 0 ? .green : Theme.recording)
        return HStack(spacing: 2) {
            Image(systemName: flat ? "equal" : n > 0 ? "arrow.up" : "arrow.down").font(.system(size: 9, weight: .bold))
            Text("\(Int(abs(n).rounded()))\(unit)").font(.system(size: 11, weight: .semibold)).monospacedDigit()
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 6).padding(.vertical, 2)
        .background(tint.opacity(0.12), in: Capsule())
        .help("Compared with the period before")
    }
}

// MARK: Charts

private struct TimeChart: View {
    let report: AnalyticsReport
    @State private var selected: Date?

    private var unit: Calendar.Component {
        switch report.bucket { case .day: .day; case .week: .weekOfYear; case .month: .month }
    }

    var body: some View {
        let bars = report.days
        let picked = selected.flatMap { s in bars.last { $0.date <= s } }
        VStack(alignment: .leading, spacing: 6) {
            Text(picked.map { "\(label($0.date)): \(hours($0.seconds)), \($0.calls) \($0.calls == 1 ? "call" : "calls")" }
                 ?? "\(hours(report.callSeconds)) in \(report.calls) calls")
                .font(.system(size: 12)).foregroundStyle(.secondary).monospacedDigit()
            Chart(bars) { bar in
                BarMark(x: .value("Date", bar.date, unit: unit), y: .value("Minutes", bar.seconds / 60))
                    .foregroundStyle(Color.accentColor.gradient)
                    .cornerRadius(3)
                    .opacity(picked == nil || picked?.date == bar.date ? 1 : 0.35)
            }
            .chartXSelection(value: $selected)
            .chartYAxis {
                AxisMarks(position: .leading) { v in
                    AxisGridLine()
                    AxisValueLabel { if let m = v.as(Double.self) { Text(m >= 60 ? "\(Int(m / 60))h" : "\(Int(m))m") } }
                }
            }
            .frame(height: 190)
        }
    }

    private func label(_ d: Date) -> String {
        switch report.bucket {
        case .day: d.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
        case .week: "Week of " + d.formatted(.dateTime.month(.abbreviated).day())
        case .month: d.formatted(.dateTime.month(.wide).year())
        }
    }
}

private struct PlatformChart: View {
    let slices: [AnalyticsReport.Slice]

    var body: some View {
        let total = slices.map(\.seconds).reduce(0, +)
        VStack(alignment: .leading, spacing: 12) {
            Chart(slices) { s in
                SectorMark(angle: .value("Time", s.seconds), innerRadius: .ratio(0.62), angularInset: 1.5)
                    .foregroundStyle(color(s.name))
                    .cornerRadius(3)
            }
            .frame(height: 130)
            ForEach(slices) { s in
                HStack(spacing: 8) {
                    Circle().fill(color(s.name)).frame(width: 8, height: 8)
                    Text(s.name)
                    Spacer()
                    Text("\(Int((s.seconds / max(total, 1) * 100).rounded()))%").foregroundStyle(.secondary).monospacedDigit()
                    Text(hours(s.seconds)).monospacedDigit().frame(width: 60, alignment: .trailing)
                }
                .font(.system(size: 12))
            }
        }
    }

    private func color(_ name: String) -> Color {
        Platform.allCases.first { $0.displayName == name }?.color ?? Theme.unknown
    }
}

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
                    RectangleMark(x: .value("Hour", hourLabel(hour)), y: .value("Day", dayLabel(day)), width: .ratio(0.92), height: .fixed(22))
                        .foregroundStyle(s == 0 ? Theme.field : Color.accentColor.opacity(0.2 + 0.8 * s / peak))
                        .cornerRadius(3)
                }
            }
        }
        .chartXScale(domain: (first...last).map(hourLabel))
        .chartYScale(domain: days.map(dayLabel))
        .chartXAxis { AxisMarks { _ in AxisValueLabel() } }
        .chartYAxis { AxisMarks(position: .leading) { _ in AxisValueLabel() } }
        .frame(height: 210)
        .accessibilityLabel("Time in calls by weekday and hour")
    }

    private func hourLabel(_ h: Int) -> String { h == 0 ? "12a" : h < 12 ? "\(h)a" : h == 12 ? "12p" : "\(h - 12)p" }
    private func dayLabel(_ d: Int) -> String { Calendar.current.shortWeekdaySymbols[d - 1] }
}

private struct PeopleList: View {
    @EnvironmentObject var controller: AppController
    let people: [AnalyticsReport.PersonTime]
    let total: TimeInterval

    var body: some View {
        if people.isEmpty {
            Text("No named people in this period.").font(.system(size: 12)).foregroundStyle(.secondary)
        } else {
            VStack(alignment: .leading, spacing: 9) {
                ForEach(people.prefix(8)) { p in
                    Button { controller.openPerson(p.name) } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(p.name).lineLimit(1)
                                Spacer()
                                Text("\(p.calls) · \(hours(p.seconds))").foregroundStyle(.secondary).monospacedDigit()
                            }
                            GeometryReader { g in
                                Capsule().fill(Theme.field)
                                    .overlay(alignment: .leading) {
                                        Capsule().fill(Color.accentColor).frame(width: g.size.width * p.seconds / max(people[0].seconds, 1))
                                    }
                            }
                            .frame(height: 5)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 12))
                }
            }
        }
    }
}

private struct KindsChart: View {
    let slices: [AnalyticsReport.Slice]

    var body: some View {
        if slices.isEmpty {
            Text("Meeting kinds come from the summary. Older calls have none.").font(.system(size: 12)).foregroundStyle(.secondary)
        } else {
            Chart(slices.prefix(8)) { s in
                BarMark(x: .value("Minutes", s.seconds / 60), y: .value("Kind", s.name))
                    .foregroundStyle(Color.accentColor.gradient)
                    .cornerRadius(3)
                    .annotation(position: .trailing) {
                        Text(hours(s.seconds)).font(.system(size: 11)).foregroundStyle(.secondary)
                    }
            }
            .chartXAxis(.hidden)
            .frame(height: CGFloat(min(slices.count, 8)) * 30 + 10)
        }
    }
}

/// How much of your coached call time the coach rated worth it, and the meetings to change first.
private struct ValueSection: View {
    @EnvironmentObject var controller: AppController
    let report: AnalyticsReport

    private static let ratings: [(MeetingValue.Rating, String, Color)] = [(.high, "High", .green), (.medium, "Medium", .gray), (.low, "Low", Theme.warning)]

    var body: some View {
        let total = max(report.valueSeconds.values.reduce(0, +), 1)
        HStack(alignment: .top, spacing: 24) {
            VStack(alignment: .leading, spacing: 10) {
                Text("\(hours(report.valueSeconds[.low] ?? 0)) in low-value meetings")
                    .font(.system(size: 20, weight: .semibold)).monospacedDigit()
                GeometryReader { g in
                    HStack(spacing: 2) {
                        ForEach(Self.ratings, id: \.1) { r in
                            Rectangle().fill(r.2).frame(width: max(0, g.size.width * (report.valueSeconds[r.0] ?? 0) / total - 2))
                        }
                    }
                    .clipShape(Capsule())
                }
                .frame(height: 10)
                HStack(spacing: 14) {
                    ForEach(Self.ratings, id: \.1) { r in
                        HStack(spacing: 5) {
                            Circle().fill(r.2).frame(width: 8, height: 8)
                            Text("\(r.1) \(hours(report.valueSeconds[r.0] ?? 0))").foregroundStyle(.secondary).monospacedDigit()
                        }
                    }
                }
                .font(.system(size: 12))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            VStack(alignment: .leading, spacing: 8) {
                Text("Rated low more than once").font(.system(size: 12, weight: .medium))
                if report.lowValueRepeats.isEmpty {
                    Text("None in this period.").font(.system(size: 12)).foregroundStyle(.secondary)
                }
                ForEach(report.lowValueRepeats.prefix(6)) { s in
                    Button { controller.meetingQuery = s.name; controller.open(.meetings) } label: {
                        HStack {
                            Text(s.name).lineLimit(1)
                            Spacer()
                            Text("\(s.calls)× · \(hours(s.seconds))").foregroundStyle(.secondary).monospacedDigit()
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 12))
                }
            }
            .frame(width: 340)
        }
    }
}

/// Time per tag. Click a topic to see its meetings.
private struct TopicsChart: View {
    @EnvironmentObject var controller: AppController
    let slices: [AnalyticsReport.Slice]

    var body: some View {
        if slices.isEmpty {
            Text("Tags come with each new summary. Regenerate an older meeting's summary to tag it.").font(.system(size: 12)).foregroundStyle(.secondary)
        } else {
            let top = slices.prefix(12)
            let peak = max(top.first?.seconds ?? 1, 1)
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 24), GridItem(.flexible(), spacing: 24)], alignment: .leading, spacing: 10) {
                ForEach(Array(top)) { s in
                    Button { controller.showTag(s.name) } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text("#\(s.name)").foregroundStyle(Color.accentColor).lineLimit(1)
                                Spacer()
                                Text("\(s.calls) · \(hours(s.seconds))").foregroundStyle(.secondary).monospacedDigit()
                            }
                            GeometryReader { g in
                                Capsule().fill(Theme.field).overlay(alignment: .leading) {
                                    Capsule().fill(Color.accentColor.opacity(0.8)).frame(width: g.size.width * s.seconds / peak)
                                }
                            }
                            .frame(height: 5)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 12))
                    .help("Show the meetings tagged \(s.name)")
                }
            }
        }
    }
}

private struct DeliveryChart: View {
    let points: [AnalyticsReport.DeliveryPoint]

    var body: some View {
        if points.count < 2 {
            Text("Turn on the communication coach in Settings. Your pace and filler words show here after a few reviewed calls.")
                .font(.system(size: 12)).foregroundStyle(.secondary)
        } else {
            HStack(spacing: 16) {
                line("Pace", "wpm", points.map { ($0.date, $0.wordsPerMinute) }, .accentColor)
                line("Fillers", "per min", points.map { ($0.date, $0.fillersPerMinute) }, Theme.warning)
            }
        }
    }

    private func line(_ title: String, _ unit: String, _ values: [(Date, Double)], _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(title).font(.system(size: 12, weight: .medium))
                Text(String(format: "%.1f %@ average", values.map(\.1).reduce(0, +) / Double(values.count), unit))
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Chart(Array(values.enumerated()), id: \.offset) { _, v in
                LineMark(x: .value("Date", v.0), y: .value(title, v.1))
                    .interpolationMethod(.monotone)
                    .foregroundStyle(color)
                PointMark(x: .value("Date", v.0), y: .value(title, v.1))
                    .foregroundStyle(color).symbolSize(18)
            }
            .chartYScale(domain: .automatic(includesZero: false))
            .frame(height: 120)
        }
        .frame(maxWidth: .infinity)
    }
}

private struct CostSection: View {
    let report: AnalyticsReport

    private static let services: [(UsageEvent.Service, String, Color)] = [(.assemblyai, "AssemblyAI", Color(hex: 0x2545d3)), (.claude, "Claude", Color(hex: 0xd97757))]
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
                VStack(alignment: .leading, spacing: 2) {
                    Text(money(c.total)).font(.system(size: 28, weight: .semibold)).monospacedDigit()
                    Text("About \(money(c.total / days * 30)) a month at this rate").font(.system(size: 12)).foregroundStyle(.secondary)
                }
                VStack(alignment: .leading, spacing: 6) {
                    row("Per call", money(c.perCall))
                    row("Per hour of calls", money(c.perCallHour))
                    ForEach(Self.services, id: \.1) { s in
                        row(s.1, money(c.byService[s.0] ?? 0), dot: s.2)
                    }
                }
                Divider()
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Self.purposes.filter { (c.byPurpose[$0.0] ?? 0) > 0 }, id: \.1) { p in
                        row(p.1, money(c.byPurpose[p.0] ?? 0))
                    }
                }
                if c.estimatedShare > 0.01 {
                    Text("\(Int((c.estimatedShare * 100).rounded()))% is estimated from call length and transcript size, for calls from before Mossad logged usage.")
                        .font(.system(size: 11)).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(width: 260)
            Chart {
                ForEach(report.days) { bar in
                    ForEach(Self.services, id: \.1) { s in
                        BarMark(x: .value("Date", bar.date, unit: unit), y: .value("Cost", bar.cost[s.0] ?? 0))
                            .foregroundStyle(by: .value("Service", s.1))
                            .cornerRadius(2)
                    }
                }
            }
            .chartForegroundStyleScale(domain: Self.services.map(\.1), range: Self.services.map(\.2))
            .chartLegend(position: .top, alignment: .trailing)
            .chartYAxis {
                AxisMarks(position: .leading) { v in
                    AxisGridLine()
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
        .font(.system(size: 12))
    }
}
