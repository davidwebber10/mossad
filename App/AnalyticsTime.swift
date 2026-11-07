import Charts
import MossadCore
import SwiftUI

private enum Measure: String, CaseIterable { case hours = "Hours", calls = "Calls" }

// MARK: Your time

struct YourTimeSection: View {
    let report: AnalyticsReport
    @State private var measure = Measure.hours

    var body: some View {
        SideBySide {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .center) {
                    Finding(AnalyticsFindings.time(report))
                    Spacer(minLength: 12)
                    FillSegmented(selection: $measure, choices: Measure.allCases.map { ($0, $0.rawValue) })
                }
                TimeChart(report: report, measure: measure)
                HStack(spacing: 14) {
                    LegendKey(title: "Scheduled", color: Palette.accentFill)
                    LegendKey(title: "Unscheduled", color: Palette.bar)
                }
            }
        } side: {
            ScheduledSide(report: report)
        }
    }
}

/// Scheduled over unscheduled bars per bucket. Point or drag across it: a glass label follows with the bucket's
/// numbers.
private struct TimeChart: View {
    let report: AnalyticsReport
    let measure: Measure
    @State private var selected: Date?

    var body: some View {
        let bars = report.days
        let picked = selected.flatMap { s in bars.last { $0.date <= s } }
        let unit = report.calendarUnit
        Chart {
            ForEach(bars) { bar in
                // Unscheduled first, so it sits at the bottom of the stack as in the canvas.
                BarMark(x: .value("Date", bar.date, unit: unit), y: .value(measure.rawValue, total(bar) - scheduled(bar)))
                    .foregroundStyle(by: .value("Kind", "Unscheduled"))
                    .cornerRadius(2)
                    .opacity(picked == nil || picked?.date == bar.date ? 1 : 0.45)
                BarMark(x: .value("Date", bar.date, unit: unit), y: .value(measure.rawValue, scheduled(bar)))
                    .foregroundStyle(by: .value("Kind", "Scheduled"))
                    .cornerRadius(2)
                    .opacity(picked == nil || picked?.date == bar.date ? 1 : 0.45)
            }
            if let picked {
                RuleMark(x: .value("Date", picked.date, unit: unit))
                    .foregroundStyle(Palette.hairline)
                    .annotation(position: .top, spacing: 4, overflowResolution: .init(x: .fit(to: .chart), y: .disabled)) {
                        ScrubLabel(text: "\(label(picked.date)) · \(hours(picked.seconds)) · \(picked.calls) \(picked.calls == 1 ? "call" : "calls")")
                    }
            }
        }
        .chartForegroundStyleScale(domain: ["Scheduled", "Unscheduled"], range: [Palette.accentFill, Palette.bar])
        .chartLegend(.hidden)
        .chartXSelection(value: $selected)
        .chartXAxis { quietDateAxis(report) }
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { v in
                AxisValueLabel {
                    if let n = v.as(Double.self) {
                        Text(measure == .calls ? "\(Int(n))" : n == 0 ? "0" : n >= 60 ? "\(Int(n / 60))h" : "\(Int(n))m")
                            .font(.system(size: 10.5)).foregroundStyle(Palette.tertiary)
                    }
                }
            }
        }
        .chartPlotStyle { $0.overlay(alignment: .bottom) { Hairline() } }
        .frame(height: 150)
        .animation(.snappy, value: picked?.date)
        .animation(.smooth, value: measure)
        .accessibilityLabel("Time in calls, \(hours(report.callSeconds)) in \(report.calls) calls")
        .accessibilityChartDescriptor(DateSeriesDescriptor(title: "Time in calls", unit: measure == .hours ? "minutes" : "calls",
                                                           points: report.days.map { ($0.date, total($0)) }))
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

/// Dates under a bar chart, in the tertiary color, about five of them.
func quietDateAxis(_ report: AnalyticsReport) -> some AxisContent {
    AxisMarks(values: .automatic(desiredCount: 5)) { v in
        AxisValueLabel {
            if let d = v.as(Date.self) {
                Text(report.bucket == .month ? d.formatted(.dateTime.month(.abbreviated)) : d.formatted(.dateTime.month(.abbreviated).day()))
                    .font(.system(size: 10.5)).foregroundStyle(Palette.tertiary)
            }
        }
    }
}

/// The value under the pointer on a chart, on a small piece of glass.
struct ScrubLabel: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 11.5, weight: .medium)).monospacedDigit()
            .padding(.horizontal, 10).padding(.vertical, 5)
            .glassEffect(.regular, in: .capsule)
            .fixedSize()
    }
}

/// Two split bars: the share of calls that were scheduled, and the share of call time.
private struct ScheduledSide: View {
    let report: AnalyticsReport

    var body: some View {
        let r = report
        VStack(alignment: .leading, spacing: 0) {
            if let finding = AnalyticsFindings.scheduled(r) { Finding(finding) }
            share("Calls", "\(r.scheduled.calls) scheduled of \(r.calls)", fraction(r.scheduled.calls, r.calls))
                .padding(.top, 14)
            share("Time", "\(hours(r.scheduled.seconds)) of \(hours(r.callSeconds))", r.callSeconds > 0 ? r.scheduled.seconds / r.callSeconds : 0)
                .padding(.top, 14)
            Text(averages)
                .font(.system(size: 12)).foregroundStyle(Palette.secondary)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 12)
        }
        .help("Scheduled means Mossad matched the call to a calendar invite.")
    }

    private func share(_ title: String, _ detail: String, _ part: Double) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title).fontWeight(.semibold)
                Spacer()
                Text(detail).foregroundStyle(Palette.secondary).monospacedDigit()
            }
            .font(.system(size: 12))
            SplitBar(parts: [(part, Palette.accentFill), (1 - part, Palette.bar)])
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title): \(percentText(part)) scheduled, \(detail)")
    }

    private var averages: String {
        func avg(_ s: AnalyticsReport.Slice) -> String { s.calls > 0 ? hours(s.seconds / Double(s.calls)) : "–" }
        return "Scheduled calls average \(avg(report.scheduled)); unscheduled \(avg(report.unscheduled))."
    }
}

/// The canvas's small segmented control on the fill, not glass: it sits in content, beside a chart.
struct FillSegmented<Value: Hashable>: View {
    @Binding var selection: Value
    let choices: [(Value, String)]
    @Namespace private var on

    var body: some View {
        HStack(spacing: 0) {
            ForEach(choices, id: \.0) { value, title in
                let selected = value == selection
                Button { withAnimation(.snappy(duration: 0.2)) { selection = value } } label: {
                    Text(title)
                        .font(.system(size: 11.5, weight: selected ? .semibold : .medium))
                        .foregroundStyle(selected ? Palette.ink : Palette.secondary)
                        .padding(.horizontal, 10).padding(.vertical, 3)
                        .background {
                            if selected {
                                Capsule().fill(Palette.segmentOn)
                                    .shadow(color: .black.opacity(0.12), radius: 1, y: 1)
                                    .matchedGeometryEffect(id: "on", in: on)
                            }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected ? [.isSelected] : [])
            }
        }
        .padding(2)
        .background(Palette.fill, in: Capsule())
        .fixedSize()
    }
}

// MARK: Your week

struct YourWeekSection: View {
    let report: AnalyticsReport

    var body: some View {
        SideBySide {
            VStack(alignment: .leading, spacing: 12) {
                Finding(AnalyticsFindings.busiestHours(report.heat) ?? "No calls at a regular time yet")
                HeatChart(cells: report.heat)
            }
        } side: {
            let w = report.workday
            VStack(alignment: .leading, spacing: 14) {
                if let finding = AnalyticsFindings.workdays(w) { Finding(finding) }
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 12) {
                    GridRow {
                        SmallFigure(value: hours(w.hoursPerWorkday * 3600), label: "in calls per work day")
                        SmallFigure(value: percentText(w.coreHoursShare), label: "of 8 to 6 in calls")
                    }
                    GridRow {
                        SmallFigure(value: w.backToBackShare.map(percentText) ?? "–", label: "calls back to back")
                        SmallFigure(value: "\(w.callFreeDays) of \(w.workdays)", label: "work days with no calls")
                    }
                }
            }
        }
    }
}

/// Weekdays down, hours across. Working hours always show; the grid grows to fit early or late calls. A plain
/// grid rather than a chart: the canvas's 16 pt cells with 3 pt gaps, and labels that sit on their rows.
private struct HeatChart: View {
    let cells: [AnalyticsReport.HeatCell]

    var body: some View {
        let hoursUsed = cells.filter { $0.seconds > 0 }.map(\.hour)
        let first = min(8, hoursUsed.min() ?? 8), last = max(18, hoursUsed.max() ?? 18)
        let peak = max(cells.map(\.seconds).max() ?? 1, 1)
        let days = [2, 3, 4, 5, 6, 7, 1]
        Grid(horizontalSpacing: 3, verticalSpacing: 3) {
            ForEach(days, id: \.self) { day in
                GridRow {
                    Text(dayLabel(day)).font(.system(size: 11)).foregroundStyle(Palette.tertiary)
                        .frame(width: 32, alignment: .leading)
                    ForEach(first...last, id: \.self) { hour in
                        let s = cells.first { $0.weekday == day && $0.hour == hour }?.seconds ?? 0
                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                            .fill(Palette.fill)
                            .overlay {
                                if s > 0 {
                                    RoundedRectangle(cornerRadius: 3, style: .continuous).fill(Palette.accentFill.opacity(0.2 + 0.8 * s / peak))
                                }
                            }
                            .frame(maxWidth: .infinity)
                            .frame(height: 16)
                    }
                }
            }
            GridRow {
                Color.clear.frame(width: 32, height: 1)
                ForEach(first...last, id: \.self) { hour in
                    Text(hourLabel(hour)).font(.system(size: 10.5)).foregroundStyle(Palette.tertiary).lineLimit(1).fixedSize()
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Time in calls by weekday and hour")
        .accessibilityChartDescriptor(HeatDescriptor(cells: cells))
    }

    private func hourLabel(_ h: Int) -> String { h == 0 ? "12a" : h < 12 ? "\(h)a" : h == 12 ? "12p" : "\(h - 12)p" }
    private func dayLabel(_ d: Int) -> String { Calendar.current.shortWeekdaySymbols[d - 1] }
}

/// VoiceOver's table for the heat map: each weekday hour with calls, and its minutes.
private struct HeatDescriptor: AXChartDescriptorRepresentable {
    let cells: [AnalyticsReport.HeatCell]

    func makeChartDescriptor() -> AXChartDescriptor {
        let busy = cells.filter { $0.seconds > 0 }.sorted { ($0.weekday + 5) % 7 * 100 + $0.hour < ($1.weekday + 5) % 7 * 100 + $1.hour }
        let names = busy.map { "\(Calendar.current.weekdaySymbols[$0.weekday - 1]) \($0.hour):00" }
        let x = AXCategoricalDataAxisDescriptor(title: "Weekday and hour", categoryOrder: names)
        let y = AXNumericDataAxisDescriptor(title: "Minutes", range: 0...60, gridlinePositions: []) { "\(Int($0)) minutes" }
        let series = AXDataSeriesDescriptor(name: "Time in calls", isContinuous: false,
                                            dataPoints: zip(names, busy).map { AXDataPoint(x: $0, y: $1.seconds / 60) })
        return AXChartDescriptor(title: "When you meet", summary: AnalyticsFindings.busiestHours(cells), xAxis: x, yAxis: y,
                                 additionalAxes: [], series: [series])
    }
}

// MARK: What you meet about

struct TopicsSection: View {
    @EnvironmentObject var controller: AppController
    let report: AnalyticsReport

    var body: some View {
        SideBySide {
            VStack(alignment: .leading, spacing: 12) {
                if let finding = AnalyticsFindings.topics(report) {
                    Finding(finding)
                    topics
                } else {
                    Finding("No topics yet")
                    Text("Topics come with each summary. Older calls get theirs when Mossad summarizes them again.")
                        .font(.system(size: 12.5)).foregroundStyle(Palette.secondary)
                }
            }
        } side: {
            ValueSide(report: report)
        }
    }

    private var topics: some View {
        let top = Array(report.tags.prefix(10))
        let peak = max(top.first?.seconds ?? 1, 1)
        return VStack(alignment: .leading, spacing: 0) {
            ForEach(top) { s in
                Button { controller.showTag(s.name) } label: {
                    HStack(spacing: 14) {
                        Text(s.name).lineLimit(1).frame(width: 150, alignment: .leading)
                        Capsule().fill(Palette.fill)
                            .overlay(alignment: .leading) {
                                GeometryReader { g in Capsule().fill(Palette.bar).frame(width: max(8, g.size.width * s.seconds / peak)) }
                            }
                            .frame(height: 8)
                        Text(hours(s.seconds)).foregroundStyle(Palette.secondary).monospacedDigit().lineLimit(1)
                            .frame(width: 72, alignment: .trailing)
                    }
                    .font(.system(size: 12.5))
                    .frame(height: 24)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("\(s.calls) \(s.calls == 1 ? "meeting" : "meetings") tagged \(s.name). Click to see them.")
                .accessibilityLabel("\(s.name), \(hours(s.seconds)) in \(s.calls) \(s.calls == 1 ? "meeting" : "meetings")")
            }
        }
    }
}

/// How much of the coached call time the coach rated worth it, and the meetings to change first.
private struct ValueSide: View {
    @EnvironmentObject var controller: AppController
    let report: AnalyticsReport

    private static let ratings: [(MeetingValue.Rating, String, Color)] = [
        (.high, "High", Palette.ink), (.medium, "Medium", Palette.bar), (.low, "Low", Palette.accentFill),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let finding = AnalyticsFindings.value(report) {
                let total = max(report.valueSeconds.values.reduce(0, +), 1)
                Finding(finding)
                SplitBar(parts: Self.ratings.map { ((report.valueSeconds[$0.0] ?? 0) / total, $0.2) })
                    .padding(.top, 14)
                HStack(spacing: 12) {
                    ForEach(Self.ratings, id: \.1) { r in
                        LegendKey(title: "\(r.1) \(percentText((report.valueSeconds[r.0] ?? 0) / total))", color: r.2)
                    }
                }
                .padding(.top, 8)
                .accessibilityElement(children: .combine)
                if !report.lowValueRepeats.isEmpty {
                    Text("Rated low more than once").font(.system(size: 12, weight: .semibold)).foregroundStyle(Palette.secondary)
                        .padding(.top, 14)
                    ForEach(report.lowValueRepeats.prefix(4)) { s in
                        Button { controller.meetingQuery = s.name; controller.open(.meetings) } label: {
                            HStack {
                                Text(s.name).lineLimit(1)
                                Spacer()
                                Text("\(s.calls)×").foregroundStyle(Palette.secondary).monospacedDigit()
                            }
                            .font(.system(size: 12.5))
                            .padding(.vertical, 3)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                Text("The coach rates each meeting's worth when it reviews the call.")
                    .font(.system(size: 12)).foregroundStyle(Palette.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 12)
            } else {
                Finding("No ratings yet")
                Text("The coach rates each meeting's worth. Ratings show here after a few coached calls.")
                    .font(.system(size: 12)).foregroundStyle(Palette.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 8)
            }
        }
    }
}
