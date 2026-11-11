import Charts
import MossadCore
import SwiftUI

/// One story for a period: four figures, then one label column group per question (your time, your week, what
/// you meet about, who with, how you communicate, outcomes, costs). Each group opens with a sentence that
/// states its finding; the chart or table under it is the evidence.
struct AnalyticsView: View {
    @EnvironmentObject var controller: AppController
    @AppStorage("analyticsPreset") private var presetRaw = PeriodChoice.Preset.last30Days.rawValue
    @AppStorage("analyticsStart") private var startStamp = Date().addingTimeInterval(-13 * 86_400).timeIntervalSince1970
    @AppStorage("analyticsEnd") private var endStamp = Date().timeIntervalSince1970
    @AppStorage("analyticsCompare") private var compare = true
    @State private var data: (now: AnalyticsReport, before: AnalyticsReport)?
    /// The charts of "How you communicate". They come after the page: the first time, every meeting is read.
    @State private var trends: CommunicationTrends?

    private static let preview = CommandLine.arguments.contains("--ui-preview")
    /// Development hook for screenshots: MOSSAD_DATE_PICKER=1 shows the period panel on the page, where a window
    /// capture sees it (a popover is a window of its own).
    private static let pickerPreview = preview && ProcessInfo.processInfo.environment["MOSSAD_DATE_PICKER"] != nil

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
        DetailColumn {
            PageToolbar(title: "Analytics", subtitle: subtitle) {
                DateRangeButton(choice: choice, compare: $compare, interval: data?.now.interval ?? interval, earliest: earliest)
            }
        } content: {
            page
        }
        .task(id: TaskKey(range: choice.wrappedValue.range, meetings: controller.meetings.count, coach: controller.coachVersion,
                          commitments: controller.commitmentsVersion)) { await load() }
    }

    /// Uses the pane's width up to a wide cap, so a large window has no empty band on the right.
    private static let maxContentWidth: CGFloat = 1320

    private var page: some View {
        ScrollViewReader { proxy in
            ScrollView {
                Group {
                    if let data {
                        if data.now.calls == 0 {
                            EmptyState(symbol: "chart.bar.xaxis", title: "No calls in this period",
                                       message: "Pick a longer period, or wait for your next call.")
                                .padding(.top, 60)
                        } else {
                            AnalyticsPage(report: data.now, before: compare ? data.before : nil,
                                          trends: trends?.interval == data.now.interval ? trends : nil)
                        }
                    } else {
                        Color.clear.frame(height: 400)
                    }
                }
                .padding(.horizontal, 36)
                .padding(.top, 10)
                .padding(.bottom, 40)
                .frame(maxWidth: Self.maxContentWidth + 72, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            // Development hook for screenshots: MOSSAD_SCROLL_TO names a section label, such as "Who you meet with",
            // or a chart of "How you communicate", such as "Pace". The charts come after the page.
            .onChange(of: data?.now.calls) { _, _ in scrollToHook(proxy) }
            .onChange(of: trends?.interval) { _, _ in scrollToHook(proxy) }
        }
        .overlay(alignment: .topTrailing) {
            if Self.pickerPreview, let data {
                PeriodPanel(choice: choice, compare: $compare, interval: data.now.interval, earliest: earliest) {}
                    .fixedSize()
                    .mossadGlass(in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .shadow(color: .black.opacity(0.22), radius: 20, y: 16)
                    .padding(.top, 2).padding(.trailing, 16)
            }
        }
    }

    private func scrollToHook(_ proxy: ScrollViewProxy) {
        guard let target = ProcessInfo.processInfo.environment["MOSSAD_SCROLL_TO"] else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { proxy.scrollTo(target, anchor: .top) }
    }

    /// Says so when the period before is empty, because then no figure shows a change.
    private var subtitle: String {
        guard compare, let data else { return "" }
        return data.before.calls == 0 ? "No calls in the period before" : "Compared with \(periodText(data.before.interval))"
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
        // A load that was replaced must not put its older period under the newer load's charts: the two can
        // end in either order, and the charts show only with the report of their own period.
        guard !Task.isCancelled else { return }
        withAnimation(.smooth) { data = result }

        // The second step: the meetings as facts, from the cache that the meeting pages fill.
        let facts = MeetingAnalyticsStore.shared.facts, interval = result.0.interval
        let made = await Task.detached(priority: .userInitiated) {
            CommunicationTrends(facts: facts.facts(for: records, owner: owner), interval: interval)
        }.value
        guard !Task.isCancelled else { return }
        withAnimation(.smooth) { trends = made }
    }
}

/// The page under the toolbar. `before` is nil when the owner turned the comparison off.
private struct AnalyticsPage: View {
    let report: AnalyticsReport
    let before: AnalyticsReport?
    let trends: CommunicationTrends?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HeadlineFigures(report: report, before: before)
                .padding(.bottom, 18)
                .hairline()
            VStack(alignment: .leading, spacing: 36) {
                AnalyticsGroup("Your time") { YourTimeSection(report: report) }
                AnalyticsGroup("Your week") { YourWeekSection(report: report) }
                AnalyticsGroup("What you meet about") { TopicsSection(report: report) }
                AnalyticsGroup("Who you meet with") { PeopleSection(report: report) }
                AnalyticsGroup("How you communicate") { CommunicationSection(report: report, trends: trends) }
                AnalyticsGroup("Outcomes") { OutcomesSection(report: report) }
                AnalyticsGroup("Costs") { CostsSection(report: report) }
            }
            .padding(.top, 24)
        }
    }
}

/// A label column group with an id for MOSSAD_SCROLL_TO.
struct AnalyticsGroup<Content: View>: View {
    let label: String
    @ViewBuilder let content: Content

    init(_ label: String, @ViewBuilder content: () -> Content) {
        self.label = label
        self.content = content()
    }

    var body: some View {
        LabelColumn(label: label, labelTopPadding: 4) { content }
            .id(label)
    }
}

// MARK: Figures

/// The four numbers across the top of the page, each with its change against the period before.
private struct HeadlineFigures: View {
    let report: AnalyticsReport
    let before: AnalyticsReport?

    var body: some View {
        let r = report, b = before
        // Whole days, as the finding counts them, so the figure and the sentence give the same weekly time.
        let weeks = max(1, (r.interval.duration / 86_400).rounded() / 7)
        let c = r.communication
        HStack(alignment: .top, spacing: 24) {
            Figure(title: "Time in calls", value: hours(r.callSeconds), detail: "\(hours(r.callSeconds / weeks)) a week",
                   change: b.map { .percent(r.callSeconds, $0.callSeconds) })
            Figure(title: "Calls", value: "\(r.calls)", detail: "\(Int((Double(r.calls) / weeks).rounded())) a week",
                   change: b.map { .percent(Double(r.calls), Double($0.calls)) })
            Figure(title: "Scheduled", value: percentText(fraction(r.scheduled.calls, r.calls)),
                   detail: "\(percentText(r.scheduled.seconds / max(r.callSeconds, 1))) of call time",
                   change: b.map { .points(fraction(r.scheduled.calls, r.calls), $0.calls > 0 ? fraction($0.scheduled.calls, $0.calls) : nil) })
            Figure(title: "Your talk share", value: r.talkShare.map(percentText) ?? "–",
                   detail: [c.oneOnOneShare.map { "1:1 \(percentText($0))" }, c.groupShare.map { "groups \(percentText($0))" }]
                    .compactMap { $0 }.joined(separator: " · "),
                   change: b.map { .points(r.talkShare, $0.talkShare) })
        }
    }
}

/// One of the large numbers across the top of an Analytics page, with what it is measured against.
struct Figure: View {
    /// A short mark beside the number in place of a change: "↑ more than usual".
    struct Mark {
        let text: String
        let help: String
        let spoken: String
    }

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
    let detail: String
    let change: Change?
    var mark: Mark?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.system(size: 12)).foregroundStyle(Palette.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(value)
                    .font(.system(size: 28, weight: .semibold)).tracking(-0.56).monospacedDigit()
                    .contentTransition(.numericText())
                    .lineLimit(1).minimumScaleFactor(0.7)
                if let c = change?.value { changeText(c.0, c.1) }
                if let mark {
                    Text(mark.text)
                        .font(.system(size: 12, weight: .medium)).monospacedDigit()
                        .foregroundStyle(Palette.accent)
                        .lineLimit(1)
                        .help(mark.help)
                        .accessibilityLabel(mark.spoken)
                }
            }
            Text(detail.isEmpty ? " " : detail).font(.system(size: 12)).foregroundStyle(Palette.secondary).lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    /// Quiet: a change is context, not news. Its direction is an arrow, never a color.
    private func changeText(_ n: Double, _ unit: String) -> some View {
        let flat = abs(n) < 0.5
        let amount = "\(Int(abs(n).rounded()))\(unit)"
        return Text(flat ? "no change" : "\(n > 0 ? "↑" : "↓") \(amount)")
            .font(.system(size: 12, weight: .medium)).monospacedDigit()
            .foregroundStyle(Palette.secondary)
            .help("Compared with the period before")
            .accessibilityLabel(flat ? "No change from the period before" : "\(n > 0 ? "Up" : "Down") \(amount) from the period before")
    }
}

// MARK: Shared parts

/// The sentence that opens a group: the finding, in the lede's weight.
struct Finding: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.system(size: 15, weight: .medium))
            .foregroundStyle(Palette.ink)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityAddTraits(.isHeader)
    }
}

/// A number with its label under it, as the canvas sets the work-day and outcome figures.
struct SmallFigure: View {
    let value: String
    let label: String

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value).font(.system(size: 20, weight: .semibold)).tracking(-0.4).monospacedDigit().contentTransition(.numericText())
            Text(label).font(.system(size: 11.5)).foregroundStyle(Palette.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

/// A legend's 8 pt square and its name.
struct LegendKey: View {
    let title: String
    let color: Color

    var body: some View {
        HStack(spacing: 5) {
            RoundedRectangle(cornerRadius: 2, style: .continuous).fill(color).frame(width: 8, height: 8)
            Text(title)
        }
        .font(.system(size: 11.5))
        .foregroundStyle(Palette.secondary)
    }
}

/// A bar split into parts with a 2 pt gap, 8 pt tall: the scheduled share, the value ratings.
struct SplitBar: View {
    let parts: [(share: Double, color: Color)]

    var body: some View {
        GeometryReader { g in
            let gaps = CGFloat(max(0, parts.filter { $0.share > 0 }.count - 1)) * 2
            HStack(spacing: 2) {
                ForEach(Array(parts.enumerated()), id: \.offset) { _, p in
                    if p.share > 0 { Rectangle().fill(p.color).frame(width: max(0, (g.size.width - gaps) * p.share)) }
                }
            }
        }
        .frame(height: 8)
        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
        .accessibilityHidden(true)
    }
}

/// The two-part rows of the time and costs sections: the evidence on the left, a smaller story on the right.
struct SideBySide<Main: View, Side: View>: View {
    var sideWidth: CGFloat = 260
    var sideLeading = false
    @ViewBuilder let main: Main
    @ViewBuilder let side: Side

    var body: some View {
        HStack(alignment: .top, spacing: 28) {
            if sideLeading { side.frame(width: sideWidth, alignment: .leading) }
            main.frame(maxWidth: .infinity, alignment: .leading)
            if !sideLeading { side.frame(width: sideWidth, alignment: .leading) }
        }
    }
}

/// "14 h 11 min", "45 min".
func hours(_ seconds: TimeInterval) -> String { AnalyticsFindings.duration(seconds) }

func money(_ dollars: Double) -> String {
    dollars.formatted(.currency(code: "USD").precision(.fractionLength(dollars < 10 ? 2 : 0)))
}

func percentText(_ share: Double) -> String { "\(Int((share * 100).rounded()))%" }
func fraction(_ part: Int, _ whole: Int) -> Double { whole > 0 ? Double(part) / Double(whole) : 0 }

extension AnalyticsReport {
    var calendarUnit: Calendar.Component {
        switch bucket { case .day: .day; case .week: .weekOfYear; case .month: .month }
    }
}
