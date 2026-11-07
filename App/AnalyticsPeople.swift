import Charts
import MossadCore
import SwiftUI

// MARK: Who you meet with

/// The top people by time together: calls, time, share of your call time, talk balance, trend, and last met.
struct PeopleSection: View {
    @EnvironmentObject var controller: AppController
    let report: AnalyticsReport

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Finding(AnalyticsFindings.people(report) ?? "No named people in this period")
                Spacer(minLength: 12)
                if !report.people.isEmpty {
                    Button("See all \(report.people.count)") { controller.open(.people) }
                        .buttonStyle(.plain)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Palette.accent)
                }
            }
            if !report.people.isEmpty {
                // Narrow windows drop the trend and the last meeting before the table would squeeze its names.
                ViewThatFits(in: .horizontal) {
                    PeopleTable(report: report, full: true)
                    PeopleTable(report: report, full: false)
                }
            }
        }
    }
}

private struct PeopleTable: View {
    @EnvironmentObject var controller: AppController
    let report: AnalyticsReport
    let full: Bool
    @State private var hovered: String?

    var body: some View {
        VStack(spacing: 0) {
            row(name: Text("Name"), calls: Text("Calls"), time: Text("Time"), share: Text("Of your time"),
                balance: AnyView(Text("Talk balance")), trend: AnyView(Text("Trend")), last: Text("Last met"))
                .font(.system(size: 11))
                .foregroundStyle(Palette.tertiary)
                .padding(.bottom, 6)
                .hairline()
                .accessibilityHidden(true)
            ForEach(report.people.prefix(8)) { p in
                Button { controller.openPerson(p.name) } label: {
                    row(name: Text(p.name).fontWeight(.medium), dot: PersonMark.color(for: p.name),
                        calls: Text("\(p.calls)").foregroundStyle(Palette.secondary),
                        time: Text(hours(p.seconds)).foregroundStyle(Palette.secondary),
                        share: Text(percentText(p.seconds / max(report.callSeconds, 1))),
                        balance: AnyView(BalanceBar(mine: p.mySpeech, theirs: p.theirSpeech)),
                        trend: AnyView(TrendBars(values: p.trend)),
                        last: Text(p.lastMet.map { $0.formatted(.relative(presentation: .named)) } ?? "–").foregroundStyle(Palette.secondary))
                        .font(.system(size: 12.5)).monospacedDigit()
                        .padding(.vertical, 8)
                        .background(hovered == p.name ? Palette.fill : .clear)
                        .hairline()
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .onHover { hovered = $0 ? p.name : (hovered == p.name ? nil : hovered) }
                .help("Open \(p.name)")
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(spoken(p))
            }
        }
    }

    private func spoken(_ p: AnalyticsReport.PersonTime) -> String {
        let total = p.mySpeech + p.theirSpeech
        var parts = ["\(p.name), \(p.calls) \(p.calls == 1 ? "call" : "calls")", hours(p.seconds),
                     "\(percentText(p.seconds / max(report.callSeconds, 1))) of your call time"]
        if total > 0 { parts.append("you talk \(percentText(p.mySpeech / total)) of the time together") }
        if let last = p.lastMet { parts.append("last met \(last.formatted(.relative(presentation: .named)))") }
        return parts.joined(separator: ", ")
    }

    private func row(name: Text, dot: Color? = nil, calls: Text, time: Text, share: Text, balance: AnyView, trend: AnyView, last: Text) -> some View {
        HStack(spacing: 14) {
            HStack(spacing: 8) {
                if let dot { Circle().fill(dot).frame(width: 8, height: 8) }
                name.lineLimit(1)
            }
            .frame(minWidth: 120, maxWidth: .infinity, alignment: .leading)
            calls.frame(width: 48, alignment: .trailing)
            time.lineLimit(1).frame(width: 72, alignment: .trailing)
            share.frame(width: 80, alignment: .trailing)
            balance.frame(width: 150, alignment: .leading)
            if full {
                trend.frame(width: 64, alignment: .leading)
                last.lineLimit(1).frame(width: 92, alignment: .trailing)
            }
        }
    }
}

/// You against them in the calls you shared: your part in the accent on the bar color.
struct BalanceBar: View {
    let mine: TimeInterval
    let theirs: TimeInterval
    var showsShare = true

    var body: some View {
        let total = mine + theirs
        let share = total > 0 ? mine / total : 0
        HStack(spacing: 8) {
            Capsule().fill(Palette.bar)
                .overlay(alignment: .leading) {
                    GeometryReader { g in Rectangle().fill(Palette.accentFill).frame(width: g.size.width * share) }
                }
                .clipShape(Capsule())
                .frame(height: 6)
            if showsShare {
                Text(total > 0 ? percentText(share) : "–").font(.system(size: 11.5)).foregroundStyle(Palette.secondary).monospacedDigit()
                    .frame(width: 30, alignment: .leading)
            }
        }
        .help("Your share of the talking when you are both in the call")
        .accessibilityLabel(total > 0 ? "You talk \(percentText(share)) of the time together" : "No speech together")
    }
}

/// Calls together across the period in five bars: enough to see a rise or a fade, small enough for a table cell.
private struct TrendBars: View {
    let values: [Int]

    private var bars: [Int] {
        guard values.count > 5 else { return values }
        return (0..<5).map { i in
            let lo = values.count * i / 5, hi = values.count * (i + 1) / 5
            return values[lo..<hi].reduce(0, +)
        }
    }

    var body: some View {
        let bars = self.bars
        Chart(Array(bars.enumerated()), id: \.offset) { i, v in
            BarMark(x: .value("Part", i), y: .value("Calls", v), width: .fixed(5))
                .foregroundStyle(Palette.accentFill.opacity(0.85))
                .cornerRadius(1)
        }
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .chartXScale(domain: -0.5...Double(bars.count) - 0.5)
        .chartYScale(domain: 0...max(1, bars.max() ?? 1))
        .frame(width: 5 * 5 + 4 * 2 + 6, height: 14)
        .accessibilityHidden(true)
    }
}

// MARK: How you communicate

struct CommunicationSection: View {
    let report: AnalyticsReport
    let before: AnalyticsReport?

    var body: some View {
        let c = report.communication
        let days = before.map { max(1, Int(($0.interval.duration / 86_400).rounded())) } ?? 0
        let pace = report.delivery.isEmpty ? nil : report.delivery.map(\.wordsPerMinute).reduce(0, +) / Double(report.delivery.count)
        VStack(alignment: .leading, spacing: 12) {
            if let finding = AnalyticsFindings.communication(c, talkShare: report.talkShare, before: before?.communication, beforeDays: days) {
                Finding(finding)
            }
            HStack(alignment: .top, spacing: 24) {
                TrendFigure(title: "Talk share", value: report.talkShare.map(percentText) ?? "–",
                            detail: [c.oneOnOneShare.map { "1:1 \(percentText($0))" }, c.groupShare.map { "groups \(percentText($0))" }]
                                .compactMap { $0 }.joined(separator: " · "),
                            points: c.points.compactMap { p in p.talkShare.map { (p.date, $0 * 100) } })
                TrendFigure(title: "Questions you ask", value: rate(c.questionsPerHour), detail: "an hour of calls",
                            points: c.points.map { ($0.date, $0.questionsPerHour) })
                TrendFigure(title: "You cut in", value: rate(c.interruptionsMadePerHour),
                            detail: "an hour · others \(rate(c.interruptionsReceivedPerHour))",
                            points: c.points.map { ($0.date, $0.interruptionsPerHour) })
                TrendFigure(title: "Pace", value: pace.map { "\(Int($0.rounded()))" } ?? "–", detail: "words a minute",
                            points: report.delivery.map { ($0.date, $0.wordsPerMinute) })
            }
        }
    }

    private func rate(_ v: Double?) -> String { v.map { String(format: "%.1f", $0) } ?? "–" }
}

/// One number with its line across the period's calls, and a hairline at the median.
private struct TrendFigure: View {
    let title: String
    let value: String
    let detail: String
    let points: [(Date, Double)]

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.system(size: 12)).foregroundStyle(Palette.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(value).font(.system(size: 20, weight: .semibold)).tracking(-0.4).monospacedDigit().contentTransition(.numericText())
                Text(detail).font(.system(size: 11.5)).foregroundStyle(Palette.secondary).lineLimit(2)
            }
            .accessibilityElement(children: .combine)
            Group {
                if points.count >= 2 {
                    // The median, not the mean: one long monologue or a burst of questions would pull a mean away.
                    let median = points.map(\.1).sorted()[points.count / 2]
                    Chart {
                        RuleMark(y: .value("Median", median))
                            .foregroundStyle(Palette.hairline)
                            .lineStyle(StrokeStyle(lineWidth: 1))
                        // One step per call, in order: calls hours apart would bunch up on a time axis.
                        ForEach(Array(points.enumerated()), id: \.offset) { i, p in
                            LineMark(x: .value("Call", i), y: .value(title, p.1))
                                .foregroundStyle(Palette.accentFill)
                                .lineStyle(StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
                        }
                    }
                    .chartXAxis(.hidden)
                    .chartYAxis(.hidden)
                    .chartXScale(domain: 0...(points.count - 1))
                    .accessibilityChartDescriptor(DateSeriesDescriptor(title: title, unit: detail, points: points))
                    .accessibilityLabel("\(title) over the period's calls")
                } else {
                    Text("Shows after a few calls.").font(.system(size: 11.5)).foregroundStyle(Palette.tertiary)
                        .frame(maxHeight: .infinity, alignment: .top)
                }
            }
            .frame(height: 34)
            .padding(.top, 8)
        }
        .padding(.top, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .hairline(.top)
    }
}

// MARK: Outcomes

struct OutcomesSection: View {
    let report: AnalyticsReport

    var body: some View {
        let o = report.outcomes
        VStack(alignment: .leading, spacing: 12) {
            if let finding = AnalyticsFindings.outcomes(o) { Finding(finding) }
            HStack(alignment: .top, spacing: 16) {
                SmallFigure(value: String(format: "%.1f", o.itemsPerHour), label: "action items an hour")
                SmallFigure(value: String(format: "%.1f", o.decisionsPerHour), label: "decisions an hour")
                SmallFigure(value: o.withOutcomesShare.map(percentText) ?? "–", label: "of calls with an item or a decision")
                SmallFigure(value: "\(o.mine) · \(o.others)", label: "items yours · others’")
                SmallFigure(value: o.commitmentsMade > 0 ? "\(o.commitmentsDone) of \(o.commitmentsMade)" : "–", label: "of your commitments done")
            }
            .padding(.top, 12)
            .hairline(.top)
        }
    }
}
