import Charts
import MossadCore
import SwiftUI

/// Where the time goes: calls, hours, talk share, the coach's scores, and meeting value for a period.
struct AnalyticsScreen: View {
    @EnvironmentObject var store: PhoneStore
    @State private var range = Range.month
    @State private var data: (now: AnalyticsReport, before: AnalyticsReport)?
    @State private var scores: [(date: Date, score: Int)] = []
    @State private var picked: Date?

    enum Range: String, CaseIterable {
        case week = "7D", month = "30D", quarter = "90D", all = "All"
        var analytics: AnalyticsRange {
            switch self { case .week: .last7Days; case .month: .last30Days; case .quarter: .last90Days; case .all: .all }
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Picker("Period", selection: $range) {
                        ForEach(Range.allCases, id: \.self) { Text($0.rawValue) }
                    }
                    .pickerStyle(.segmented)
                    if let data {
                        tiles(data.now, data.before)
                        timeChart(data.now)
                        if scores.count > 1 { scoreChart }
                        mix(data.now)
                        if data.now.valueSeconds.values.reduce(0, +) > 0 { value(data.now) }
                        if !data.now.people.isEmpty { people(data.now) }
                        if !data.now.tags.isEmpty { tags(data.now) }
                    } else {
                        ProgressView().frame(maxWidth: .infinity).padding(.top, 60)
                    }
                }
                .padding(.horizontal)
                .padding(.bottom, 24)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Analytics")
            .refreshable { await store.sync() }
            .task(id: "\(range.rawValue)-\(store.meetings.count)-\(store.coachVersion)") { await load() }
        }
    }

    private func load() async {
        let records = store.meetings, owner = store.owner, paths = store.paths, range = range.analytics
        let result = await Task.detached(priority: .userInitiated) {
            let interval = range.interval(earliest: records.map(\.start).min())
            let reviews = Dictionary(uniqueKeysWithValues: records.filter { interval.contains($0.start) }.compactMap { r in
                CoachReview.load(in: paths.callDirectory(r.id)).map { (r.id, $0) }
            })
            let scores = records.filter { interval.contains($0.start) }.compactMap { r in reviews[r.id]?.scorecard.map { (date: r.start, score: $0.score) } }
                .sorted { $0.date < $1.date }
            return (AnalyticsReport(records: records, usage: [], owner: owner, interval: interval, reviews: reviews),
                    AnalyticsReport(records: records, usage: [], owner: owner, interval: AnalyticsRange.previous(interval)), scores)
        }.value
        data = (result.0, result.1)
        scores = result.2
    }

    // MARK: Sections

    private func tiles(_ r: AnalyticsReport, _ before: AnalyticsReport) -> some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
            StatTile(value: "\(r.calls)", label: "Meetings", detail: change(Double(r.calls), Double(before.calls)))
            StatTile(value: duration(r.callSeconds), label: "In meetings", detail: change(r.callSeconds, before.callSeconds))
            StatTile(value: duration(r.averageSeconds), label: "Average length", detail: String(format: "%.1f a day", r.callsPerDay))
            StatTile(value: r.talkShare.map { "\(Int(($0 * 100).rounded()))%" } ?? "–", label: "You talked",
                     detail: before.talkShare.map { "\(Int(($0 * 100).rounded()))% before" })
        }
    }

    /// "+12% vs before", or nil when there is nothing to compare with.
    private func change(_ now: Double, _ before: Double) -> String? {
        guard before > 0 else { return nil }
        let pct = Int(((now - before) / before * 100).rounded())
        return pct == 0 ? "Same as before" : "\(pct > 0 ? "+" : "")\(pct)% vs before"
    }

    private var unit: Calendar.Component {
        switch data?.now.bucket { case .week: .weekOfYear; case .month: .month; default: .day }
    }

    private func timeChart(_ r: AnalyticsReport) -> some View {
        let selected = picked.flatMap { p in r.days.first { Calendar.current.isDate($0.date, equalTo: p, toGranularity: unit) } }
        return Card {
            CardTitle(text: "Time in meetings", symbol: "chart.bar")
            Text(selected.map { "\(duration($0.seconds)) in \($0.calls) on \($0.date.formatted(.dateTime.month(.abbreviated).day()))" }
                 ?? "\(duration(r.callSeconds)) in \(r.calls) meetings")
                .font(.headline).monospacedDigit()
            Chart(r.days) { bar in
                BarMark(x: .value("Date", bar.date, unit: unit), y: .value("Hours", bar.seconds / 3600))
                    .foregroundStyle(selected == nil || selected?.date == bar.date ? Color.accentColor : Color.accentColor.opacity(0.3))
                    .cornerRadius(3)
            }
            .chartXSelection(value: $picked)
            .chartYAxis { AxisMarks { v in AxisGridLine(); AxisValueLabel { if let h = v.as(Double.self) { Text("\(h, specifier: "%.0f") h") } } } }
            .frame(height: 180)
        }
    }

    private var scoreChart: some View {
        Card {
            CardTitle(text: "Coach score", symbol: "star")
            Text(String(format: "%.1f average", Double(scores.map(\.score).reduce(0, +)) / Double(scores.count))).font(.headline)
            Chart(Array(scores.enumerated()), id: \.offset) { _, s in
                LineMark(x: .value("Date", s.date), y: .value("Score", s.score)).interpolationMethod(.monotone)
                PointMark(x: .value("Date", s.date), y: .value("Score", s.score)).foregroundStyle(scoreColor(s.score))
            }
            .chartYScale(domain: 1...5)
            .chartYAxis { AxisMarks(values: [1, 2, 3, 4, 5]) }
            .frame(height: 150)
        }
    }

    private func mix(_ r: AnalyticsReport) -> some View {
        Card {
            CardTitle(text: "Scheduled or not", symbol: "calendar")
            let total = max(1, r.calls)
            GeometryReader { g in
                HStack(spacing: 2) {
                    Rectangle().fill(Color.accentColor).frame(width: g.size.width * Double(r.scheduled.calls) / Double(total))
                    Rectangle().fill(Color.orange)
                }
                .clipShape(.capsule)
            }
            .frame(height: 10)
            HStack {
                Label("\(r.scheduled.calls) scheduled", systemImage: "circle.fill").foregroundStyle(Color.accentColor)
                Spacer()
                Label("\(r.unscheduled.calls) unscheduled", systemImage: "circle.fill").foregroundStyle(.orange)
            }
            .font(.caption).labelStyle(DotLabel())
        }
    }

    private func value(_ r: AnalyticsReport) -> some View {
        Card {
            CardTitle(text: "Meeting value", symbol: "clock.badge.checkmark")
            Text("\(duration(r.valueSeconds[.low] ?? 0)) in low-value meetings").font(.headline)
            ForEach([(MeetingValue.Rating.high, Color.green), (.medium, .yellow), (.low, .orange)], id: \.0) { rating, tint in
                Gauge(value: r.valueSeconds[rating] ?? 0, in: 0...max(1, r.valueSeconds.values.reduce(0, +))) {
                    HStack {
                        Text(rating.rawValue.capitalized)
                        Spacer()
                        Text(duration(r.valueSeconds[rating] ?? 0)).monospacedDigit().foregroundStyle(.secondary)
                    }
                    .font(.subheadline)
                }
                .gaugeStyle(.linearCapacity).tint(tint)
            }
            if !r.lowValueRepeats.isEmpty {
                Text("Repeats rated low: " + r.lowValueRepeats.prefix(3).map(\.name).joined(separator: ", ")).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func people(_ r: AnalyticsReport) -> some View {
        Card {
            CardTitle(text: "Who you meet with most", symbol: "person.2")
            Chart(r.people.filter { $0.name != store.owner }.prefix(6)) { p in
                BarMark(x: .value("Hours", p.seconds / 3600), y: .value("Name", p.name))
                    .annotation(position: .trailing) { Text(duration(p.seconds)).font(.caption2).foregroundStyle(.secondary) }
                    .cornerRadius(3)
            }
            .chartXAxis(.hidden)
            .frame(height: CGFloat(min(6, r.people.count)) * 34)
        }
    }

    private func tags(_ r: AnalyticsReport) -> some View {
        Card {
            CardTitle(text: "Topics", symbol: "number")
            ForEach(r.tags.prefix(6)) { t in
                HStack {
                    Text("#\(t.name)").foregroundStyle(.tint)
                    Spacer()
                    Text("\(t.calls) · \(duration(t.seconds))").foregroundStyle(.secondary).monospacedDigit()
                }
                .font(.subheadline)
            }
        }
    }
}

private struct DotLabel: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 5) { configuration.icon.font(.system(size: 7)); configuration.title.foregroundStyle(.secondary) }
    }
}
