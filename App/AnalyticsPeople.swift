import Charts
import MossadCore
import SwiftUI

// MARK: Who you meet with

/// The top people by time together: calls, time, share of your call time, talk balance, trend, and last met.
struct PeopleSection: View {
    @EnvironmentObject var controller: AppController
    let report: AnalyticsReport

    var body: some View {
        VStack(alignment: .leading, spacing: Rhythm.rowGap) {
            HStack(alignment: .firstTextBaseline) {
                Finding(AnalyticsFindings.people(report) ?? "No named people in this period")
                Spacer(minLength: 12)
                if !report.people.isEmpty {
                    Button("See all \(report.people.count)") { controller.open(.people) }
                        .buttonStyle(.plain)
                        .font(.system(size: Rhythm.secondarySize, weight: .semibold))
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
                .font(.system(size: Rhythm.noteSize))
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
                        .font(.system(size: Rhythm.bodySize)).monospacedDigit()
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
        HStack(spacing: Space.l) {
            HStack(spacing: Space.s) {
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
        HStack(spacing: Space.s) {
            Capsule().fill(Palette.bar)
                .overlay(alignment: .leading) {
                    GeometryReader { g in Rectangle().fill(Palette.accentFill).frame(width: g.size.width * share) }
                }
                .clipShape(Capsule())
                .frame(height: 6)
            if showsShare {
                Text(total > 0 ? percentText(share) : "–").font(.system(size: Rhythm.secondarySize)).foregroundStyle(Palette.secondary).monospacedDigit()
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

/// The finding, then one full-width chart per number: talk share, questions, cut-ins, and pace across the period.
struct CommunicationSection: View {
    @EnvironmentObject var controller: AppController
    let report: AnalyticsReport
    /// Nil while the meetings' numbers are read.
    let trends: CommunicationTrends?
    @AppStorage("analyticsTrendSplit") private var splitRaw = CommunicationTrends.Split.all.rawValue

    /// The size the owner picked, while the period has both sizes to pick from.
    private var split: CommunicationTrends.Split {
        guard let trends, !trends.splits.isEmpty else { return .all }
        return CommunicationTrends.Split(rawValue: splitRaw) ?? .all
    }

    var body: some View {
        let finding = AnalyticsFindings.communication(report.communication, talkShare: report.talkShare)
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center) {
                if let finding { Finding(finding) }
                Spacer(minLength: 12)
                if let trends, !trends.splits.isEmpty {
                    FillSegmented(selection: Binding { split } set: { splitRaw = $0.rawValue }, choices: trends.splits.map { ($0, $0.title) })
                        .help("A talk share, questions, and cut-ins follow the size of the meeting. Pick one size to read its own trend.")
                        .accessibilityLabel("Meetings in the charts")
                }
            }
            .padding(.bottom, 14)
            if let trends {
                ForEach(trends.series(split)) { series in
                    TrendPanel(series: series, interval: trends.interval) { controller.openMeeting($0) }
                        .padding(.top, 14)
                        .padding(.bottom, 22)
                        .hairline(.top)
                        // MOSSAD_SCROLL_TO takes a chart's title too, such as "Pace".
                        .id(CommunicationTrends.title(series.metric))
                }
            } else {
                // The space the charts take, so the groups below do not jump when they come, with a mark that
                // says they are on the way: the first load after a launch reads every meeting.
                ProgressView().controlSize(.small)
                    .frame(maxWidth: .infinity, alignment: .top)
                    .padding(.top, 40)
                    .frame(height: CGFloat(CommunicationTrends.metrics.count) * (TrendPanel.chartHeight + TrendPanel.chrome + 36), alignment: .top)
                    .accessibilityLabel("Loading the charts")
            }
        }
    }
}

// MARK: Outcomes

struct OutcomesSection: View {
    let report: AnalyticsReport

    var body: some View {
        let o = report.outcomes
        VStack(alignment: .leading, spacing: Rhythm.rowGap) {
            if let finding = AnalyticsFindings.outcomes(o) { Finding(finding) }
            HStack(alignment: .top, spacing: Space.l) {
                SmallFigure(value: String(format: "%.1f", o.itemsPerHour), label: "action items an hour")
                SmallFigure(value: String(format: "%.1f", o.decisionsPerHour), label: "decisions an hour")
                SmallFigure(value: o.withOutcomesShare.map(percentText) ?? "–", label: "of calls with an item or a decision")
                SmallFigure(value: "\(o.mine) · \(o.others)", label: "items yours · others’")
                SmallFigure(value: o.commitmentsMade > 0 ? "\(o.commitmentsDone) of \(o.commitmentsMade)" : "–", label: "of your tasks done")
            }
            .padding(.top, 12)
            .hairline(.top)
        }
    }
}
