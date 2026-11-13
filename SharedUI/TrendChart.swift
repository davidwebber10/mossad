import Charts
import MossadCore
import SwiftUI

/// One number of "How you communicate" across the period, at the full width of its page: the title, the
/// sentence that says whether it moved, the chart, and what the marks are.
struct TrendPanel: View {
    typealias T = CommunicationTrends

    let series: T.Series
    let interval: DateInterval
    var height: CGFloat = TrendPanel.chartHeight
    /// Opens the meeting with this id.
    let open: (String) -> Void

    #if os(iOS)
    static let chartHeight: CGFloat = 210
    #else
    static let chartHeight: CGFloat = 230
    #endif
    /// The header and the key around the chart, for a placeholder of the same height while the numbers load.
    static let chrome: CGFloat = 82

    var body: some View {
        VStack(alignment: .leading, spacing: Space.m) {
            header
            if series.points.isEmpty {
                Text("No meeting in this period has this number.")
                    .textRole(.secondary).foregroundStyle(Palette.tertiary)
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .topLeading)
            } else {
                TrendChart(series: series, interval: interval, open: open)
                    .frame(height: height)
                key
            }
        }
    }

    private var moved: Bool { series.change.moved }

    private var header: some View {
        HStack(alignment: .top, spacing: Space.l) {
            VStack(alignment: .leading, spacing: 3) {
                Text(T.title(series.metric)).textRole(.headline).foregroundStyle(Palette.ink)
                    .accessibilityAddTraits(.isHeader)
                // A change is news and reads in ink; "no clear change" stays quiet.
                Text(series.sentence).textRole(.body).fontWeight(moved ? .medium : .regular)
                    .foregroundStyle(moved ? Palette.ink : Palette.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityHidden(spokenByChart)
                    #if os(macOS)
                    .help(series.basis)
                    #endif
                #if os(iOS)
                // The iPhone has no room beside the sentence, so the typical value is a line under it.
                if let typical = series.typical {
                    Text("\(T.short(series.metric, typical)) \(typicalCaption)").textRole(.secondary).foregroundStyle(Palette.secondary)
                        .accessibilityHidden(spokenByChart)
                } else if !partTypicals.isEmpty {
                    Text(partTypicals.map { "\($0.value) \($0.label)" }.joined(separator: " · ")).textRole(.secondary).foregroundStyle(Palette.secondary)
                        .accessibilityHidden(spokenByChart)
                }
                #endif
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            #if os(macOS)
            if let typical = series.typical {
                VStack(alignment: .trailing, spacing: 1) {
                    Text(T.short(series.metric, typical)).textRole(.title).foregroundStyle(Palette.ink)
                        .contentTransition(.numericText())
                    Text(typicalCaption).textRole(.secondary).foregroundStyle(Palette.secondary)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Typical meeting \(T.text(series.metric, typical))")
                .accessibilityHidden(spokenByChart)
            } else if !partTypicals.isEmpty {
                VStack(alignment: .trailing, spacing: 1) {
                    ForEach(partTypicals, id: \.label) { part in
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text(part.value).textRole(.headline).foregroundStyle(Palette.ink).monospacedDigit()
                            Text(part.label).textRole(.secondary).foregroundStyle(Palette.secondary)
                        }
                    }
                }
                .accessibilityElement(children: .combine)
                .accessibilityHidden(spokenByChart)
            }
            #endif
        }
    }

    /// The chart says the sentence and the typical values; the header would say them twice.
    private var spokenByChart: Bool { !series.points.isEmpty }

    /// In the chart of all meetings with a line per size: each size's typical meeting.
    private var partTypicals: [(value: String, label: String)] {
        series.parts.compactMap { p in
            p.typical.map { (T.short(series.metric, $0), p.split == .oneOnOne ? "typical 1:1" : "typical group") }
        }
    }

    /// "in a typical meeting", with the unit when the number has one: "an hour in a typical meeting".
    private var typicalCaption: String {
        let unit = T.unit(series.metric)
        return unit.isEmpty ? "in a typical meeting" : "\(unit) in a typical meeting"
    }

    /// The three marks, each with its name. One row where it fits, else one mark a line.
    private var key: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: Space.l) { keys }
            VStack(alignment: .leading, spacing: Space.xs) { keys }
        }
        .textRole(.secondary)
        .foregroundStyle(Palette.secondary)
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private var keys: some View {
        HStack(spacing: 6) {
            Circle().fill(TrendChart.pointColor).frame(width: 7, height: 7)
            Text("Each meeting")
        }
        if !series.line.isEmpty {
            HStack(spacing: 6) {
                Capsule().fill(Palette.accentFill).frame(width: 14, height: 2.5)
                Text(T.Series.lineName(days: series.lineDays, held: series.held))
            }
        }
        ForEach(series.parts.filter { !$0.line.isEmpty }) { part in
            HStack(spacing: 6) {
                TrendChart.partSwatch(part.split)
                Text(T.Series.lineName(days: part.lineDays, split: part.split, held: part.held))
            }
        }
        if let usual = series.usualText {
            HStack(spacing: 6) {
                RoundedRectangle(cornerRadius: 2, style: .continuous).fill(Palette.accentTint).frame(width: 14, height: 9)
                Text(usual)
            }
        }
    }
}

/// The chart of a `TrendPanel`: every meeting a quiet point, the median of each week a strong line (one for each
/// size in the chart of all meetings, for a number that follows the size), the usual range a soft band. Point at
/// a meeting on the Mac, or drag across on the iPhone, for its title, day, and value; a click on the Mac opens
/// it, and the iPhone shows a row that does.
struct TrendChart: View {
    typealias T = CommunicationTrends

    let series: T.Series
    let interval: DateInterval
    /// For a goal's chart: the day it was taken and its target. Nil in Analytics.
    var goal: Goal? = nil
    let open: (String) -> Void

    /// The marks of a goal over the chart, and what VoiceOver says of the chart in place of the period's sentence.
    struct Goal: Equatable {
        var start: Date
        var target: Double
        var spoken: String
        /// The labels on the chart: "Target 58%", "Goal taken Oct 19".
        var targetLabel: String
        var startLabel: String
    }

    /// The target: a dashed line in the color of good news.
    static let targetColor = Palette.okText

    @State private var picked: T.Point?
    #if os(iOS)
    @State private var scrub: Date?
    #endif

    /// The meetings are context for the line, so they take no hue.
    static let pointColor = Palette.secondary.opacity(0.5)

    /// The line of a size in the chart of all meetings: 1:1s in the accent, groups in ink with a dash.
    static func partStyle(_ split: T.Split) -> (color: Color, dash: [CGFloat]) {
        split == .group ? (Palette.ink.opacity(0.72), [5, 3.5]) : (Palette.accentFill, [])
    }

    static func partSwatch(_ split: T.Split) -> some View {
        let style = partStyle(split)
        return Path { p in p.move(to: CGPoint(x: 0, y: 1.25)); p.addLine(to: CGPoint(x: 14, y: 1.25)) }
            .stroke(style.color, style: StrokeStyle(lineWidth: 2.5, lineCap: .round, dash: style.dash))
            .frame(width: 14, height: 2.5)
    }

    var body: some View {
        let chart = TrendPlot(series: series, interval: interval, goal: goal)
            .equatable()
            .chartOverlay { proxy in
                GeometryReader { geometry in
                    if let plot = proxy.plotFrame {
                        TrendLayer(series: series, picked: $picked, proxy: proxy, plot: geometry[plot], size: geometry.size, open: open)
                    }
                }
            }

        #if os(iOS)
        VStack(alignment: .leading, spacing: Space.s) {
            chart
                .chartXSelection(value: $scrub)
                .onChange(of: scrub) { _, date in
                    // The finger leaves and the meeting stays picked, so its row can be tapped.
                    if let date { picked = nearest(to: date) }
                }
                .sensoryFeedback(.selection, trigger: picked?.id)
            if let picked {
                Button { open(picked.id) } label: {
                    HStack(spacing: Space.s) {
                        Text(picked.title).fontWeight(.medium).foregroundStyle(Palette.ink).lineLimit(1)
                        Text(T.short(series.metric, picked.value)).foregroundStyle(Palette.secondary)
                        Spacer(minLength: 0)
                        Text("Open").fontWeight(.semibold).foregroundStyle(Palette.accent)
                        Image(systemName: "chevron.right").font(.caption2.weight(.semibold)).foregroundStyle(Palette.accent)
                            .accessibilityHidden(true)
                    }
                    .textRole(.secondary)
                    .padding(.horizontal, Space.m).padding(.vertical, Space.s)
                    .background(Palette.fill, in: RoundedRectangle(cornerRadius: Radius.row, style: .continuous))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Open \(picked.title), \(T.text(series.metric, picked.value))")
            }
        }
        .onChange(of: series.points.count) { _, _ in
            if let id = picked?.id, !series.points.contains(where: { $0.id == id }) { picked = nil }
        }
        .onAppear(perform: pickForPreview)
        #else
        chart
            // A meeting can leave the chart while the pointer rests on it.
            .onChange(of: series.points.count) { _, _ in picked = nil }
            .onChange(of: series.points.last?.id) { _, _ in picked = nil }
            .onAppear(perform: pickForPreview)
        #endif
    }

    /// Development hook for screenshots: MOSSAD_TREND_TIP=1 picks a meeting as the pointer or the finger would,
    /// in a Mac preview or on the iPhone's sample folder only.
    private func pickForPreview() {
        let env = ProcessInfo.processInfo.environment
        #if os(iOS)
        let preview = env["MOSSAD_ROOT"] != nil
        #else
        let preview = CommandLine.arguments.contains("--ui-preview")
        #endif
        if preview, env["MOSSAD_TREND_TIP"] != nil { picked = series.points.dropFirst(series.points.count * 2 / 3).first }
    }

    #if os(iOS)
    private func nearest(to date: Date) -> T.Point? {
        series.points.min { abs($0.date.timeIntervalSince(date)) < abs($1.date.timeIntervalSince(date)) }
    }
    #endif
}

/// The marks of a `TrendChart`, apart from the picked meeting: a new picked meeting does not draw every point
/// again.
private struct TrendPlot: View, Equatable {
    typealias T = CommunicationTrends

    let series: T.Series
    let interval: DateInterval
    let goal: TrendChart.Goal?

    private var scale: T.Scale { series.scale }
    private func inside(_ value: Double) -> Double { min(max(value, scale.lower), scale.upper) }

    var body: some View {
        let near = series.points.filter { $0.value >= scale.lower && $0.value <= scale.upper }
        let far = series.points.filter { $0.value > scale.upper || $0.value < scale.lower }
        Chart {
            if let band = series.usual, band.high >= scale.lower, band.low <= scale.upper {
                RectangleMark(xStart: .value("From", interval.start), xEnd: .value("To", interval.end),
                              yStart: .value("Low", inside(band.low)), yEnd: .value("High", inside(band.high)))
                    .foregroundStyle(Palette.accentTint)
            }
            PointPlot(near, x: .value("Date", \.date), y: .value("Value", \.value))
                .symbolSize(34)
                .foregroundStyle(TrendChart.pointColor)
            ForEach(far) { p in
                // Further out than the axis goes: an arrow at the edge says so, and the value is in its label.
                PointMark(x: .value("Date", p.date), y: .value("Value", inside(p.value)))
                    .symbol {
                        Image(systemName: p.value > scale.upper ? "arrowtriangle.up.fill" : "arrowtriangle.down.fill")
                            .font(.system(size: 7)).foregroundStyle(TrendChart.pointColor)
                    }
            }
            if let goal {
                // The day the goal was taken, and the target: what the points since are read against.
                RuleMark(x: .value("Goal taken", goal.start))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [2, 3]))
                    .foregroundStyle(Palette.secondary.opacity(0.7))
                    .annotation(position: .top, alignment: .center, spacing: 2) {
                        Text(goal.startLabel).font(Self.axisFont).foregroundStyle(Palette.secondary)
                    }
                RuleMark(y: .value("Target", inside(goal.target)))
                    .lineStyle(StrokeStyle(lineWidth: 1.5, lineCap: .round, dash: [5, 4]))
                    .foregroundStyle(TrendChart.targetColor)
                    .annotation(position: .bottom, alignment: .leading, spacing: 3) {
                        Text(goal.targetLabel).font(Self.axisFont).fontWeight(.medium).foregroundStyle(TrendChart.targetColor)
                    }
            }
            lineMarks(series.line, name: "all", color: Palette.accentFill, dash: [])
            ForEach(series.parts) { part in
                let style = TrendChart.partStyle(part.split)
                lineMarks(part.line, name: part.split.rawValue, color: style.color, dash: style.dash)
            }
        }
        .chartXScale(domain: interval.start...max(interval.end, interval.start.addingTimeInterval(1)), range: .plotDimension(padding: 8))
        .chartYScale(domain: scale.lower...scale.upper, range: .plotDimension(padding: 8))
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: Self.dateMarks)) { v in
                AxisTick(length: 4, stroke: StrokeStyle(lineWidth: 1)).foregroundStyle(Palette.hairline)
                AxisValueLabel {
                    if let d = v.as(Date.self) { Text(dateText(d)).font(Self.axisFont).foregroundStyle(Palette.tertiary) }
                }
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading, values: scale.marks) { v in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 1)).foregroundStyle(Palette.hairline)
                AxisValueLabel {
                    if let n = v.as(Double.self) { Text(markText(n)).font(Self.axisFont).monospacedDigit().foregroundStyle(Palette.tertiary) }
                }
            }
        }
        .chartYAxisLabel(position: .top, alignment: .leading, spacing: 6) {
            Text(T.axis(series.metric)).font(Self.axisFont).foregroundStyle(Palette.tertiary)
        }
        .chartLegend(.hidden)
        .animation(.smooth, value: series.points.count)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(goal?.spoken ?? series.spoken)
        .accessibilityChartDescriptor(TrendDescriptor(series: series, summary: goal?.spoken))
    }

    /// A line in pieces: it breaks where a step was left out, and a piece of one step is a dot.
    @ChartContentBuilder
    private func lineMarks(_ steps: [T.Step], name: String, color: Color, dash: [CGFloat]) -> some ChartContent {
        let single = Set(Dictionary(grouping: steps, by: \.segment).filter { $0.value.count == 1 }.keys)
        ForEach(steps) { step in
            LineMark(x: .value("Date", step.date), y: .value("Median", step.value), series: .value("Piece", "\(name)-\(step.segment)"))
                .interpolationMethod(.monotone)
                .lineStyle(StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round, dash: dash))
                .foregroundStyle(color)
            if single.contains(step.segment) {
                PointMark(x: .value("Date", step.date), y: .value("Median", step.value))
                    .symbolSize(30)
                    .foregroundStyle(color)
            }
        }
    }

    #if os(iOS)
    private static let dateMarks = 4
    static let axisFont = Font.caption2
    #else
    private static let dateMarks = 7
    static let axisFont = Font.system(size: Rhythm.noteSize)
    #endif

    /// "Sep 12"; "Sep 2025" when the period is longer than a year.
    private func dateText(_ date: Date) -> String {
        series.days > 400 ? date.formatted(.dateTime.month(.abbreviated).year()) : date.formatted(.dateTime.month(.abbreviated).day())
    }

    /// "40%", "4", "2.5", "150": no decimals unless the marks are less than 1 apart.
    private func markText(_ value: Double) -> String {
        if series.metric == .talkShare { return T.short(.talkShare, value) }
        return scale.step < 1 ? String(format: "%.1f", value) : "\(Int(value.rounded()))"
    }
}

/// What lies over the plot: on the Mac the surface that follows the pointer, and on both the picked meeting's
/// dot and label. The label sits over its point, or under it when there is no room above, and stays inside the
/// chart.
private struct TrendLayer: View {
    typealias T = CommunicationTrends

    let series: T.Series
    @Binding var picked: T.Point?
    let proxy: ChartProxy
    let plot: CGRect
    let size: CGSize
    let open: (String) -> Void

    /// The pointer picks the nearest meeting within this many points.
    private static let reach: CGFloat = 28
    /// From the picked point to its label.
    private static let tipGap: CGFloat = 12

    private func inside(_ value: Double) -> Double { min(max(value, series.scale.lower), series.scale.upper) }

    var body: some View {
        ZStack(alignment: .topLeading) {
            #if os(macOS)
            Color.clear
                .contentShape(Rectangle())
                .onContinuousHover { phase in
                    switch phase {
                    case .active(let at):
                        let next = nearest(to: CGPoint(x: at.x - plot.minX, y: at.y - plot.minY))
                        if next?.id != picked?.id { picked = next }
                    case .ended: picked = nil
                    }
                }
                .onTapGesture { if let picked { open(picked.id) } }
                .pointerStyle(picked == nil ? .default : .link)
            #else
            Color.clear.allowsHitTesting(false)
            #endif
            if let picked, let at = proxy.position(for: (x: picked.date, y: inside(picked.value))) {
                let x = plot.minX + at.x, y = plot.minY + at.y
                Circle().fill(Palette.accent).frame(width: 9, height: 9)
                    .overlay { Circle().strokeBorder(Palette.window, lineWidth: 2).padding(-2) }
                    .position(x: x, y: y)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
                TrendTip(metric: series.metric, point: picked)
                    .alignmentGuide(.leading) { d in -min(max(x - d.width / 2, 0), max(0, size.width - d.width)) }
                    .alignmentGuide(.top) { d in -(y - Self.tipGap - d.height >= 0 ? y - Self.tipGap - d.height : y + Self.tipGap) }
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
    }

    #if os(macOS)
    /// The meeting whose point is nearest to the pointer, so the pointer does not have to land on a dot. Only
    /// the points within reach across the date axis are placed.
    private func nearest(to pointer: CGPoint) -> T.Point? {
        guard let a = proxy.value(atX: pointer.x - Self.reach, as: Date.self), let b = proxy.value(atX: pointer.x + Self.reach, as: Date.self)
        else { return nil }
        let from = min(a, b), to = max(a, b)
        let points = series.points
        // The points are oldest first: find the first within reach and go on until past it.
        var low = 0, high = points.count
        while low < high {
            let mid = (low + high) / 2
            if points[mid].date < from { low = mid + 1 } else { high = mid }
        }
        var best: (point: T.Point, distance: CGFloat)?
        var i = low
        while i < points.count, points[i].date <= to {
            let p = points[i]
            if let at = proxy.position(for: (x: p.date, y: inside(p.value))) {
                let distance = hypot(at.x - pointer.x, at.y - pointer.y)
                if distance <= Self.reach, distance < best?.distance ?? .infinity { best = (p, distance) }
            }
            i += 1
        }
        return best?.point
    }
    #endif
}

/// The meeting under the pointer or the finger: its title, its day, and its value.
private struct TrendTip: View {
    let metric: PersonMetric
    let point: CommunicationTrends.Point

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).fontWeight(.medium).foregroundStyle(Palette.ink).lineLimit(1)
            Text("\(point.date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())) · \(CommunicationTrends.text(metric, point.value))")
                .foregroundStyle(Palette.secondary)
            #if os(macOS)
            Text("Click to open").foregroundStyle(Palette.tertiary)
            #endif
        }
        .textRole(.secondary)
        .fixedSize()
        .padding(.horizontal, 10).padding(.vertical, 7)
        // Opaque, not glass: the label lies over points and a line, and its words must not mix with them.
        .background(Palette.surface, in: RoundedRectangle(cornerRadius: Radius.row, style: .continuous))
        .hairlineBorder(RoundedRectangle(cornerRadius: Radius.row, style: .continuous))
        .shadow(color: .black.opacity(0.12), radius: 6, y: 3)
    }

    /// The label takes its own width, so a long title is cut here and not by the chart's edge.
    private var title: String { point.title.count > 44 ? point.title.prefix(43).trimmingCharacters(in: .whitespaces) + "…" : point.title }
}

/// VoiceOver's audio graph and table: each meeting's value, the line's values, and the sentence as the summary.
private struct TrendDescriptor: AXChartDescriptorRepresentable {
    let series: CommunicationTrends.Series
    /// In place of the period's sentence, for a goal's chart.
    var summary: String?

    func makeChartDescriptor() -> AXChartDescriptor {
        typealias T = CommunicationTrends
        let metric = series.metric
        // A time axis, so the audio graph places the line's steps among the meetings by their dates.
        let times = series.points.map(\.date.timeIntervalSince1970)
        let low = times.min() ?? 0, high = max(times.max() ?? 1, low + 1)
        let x = AXNumericDataAxisDescriptor(title: "Date", range: low...high, gridlinePositions: []) {
            Date(timeIntervalSince1970: $0).formatted(date: .abbreviated, time: .shortened)
        }
        // The far meetings that the chart draws at its edge are in the table with their own values.
        let values = series.points.map(\.value) + [series.scale.lower, series.scale.upper]
        let y = AXNumericDataAxisDescriptor(title: T.axis(metric), range: values.min()!...values.max()!, gridlinePositions: series.scale.marks) {
            T.text(metric, $0)
        }
        let meetings = AXDataSeriesDescriptor(name: "Each meeting", isContinuous: false, dataPoints: series.points.map {
            AXDataPoint(x: $0.date.timeIntervalSince1970, y: $0.value, label: $0.title)
        })
        func line(_ name: String, _ steps: [T.Step]) -> AXDataSeriesDescriptor {
            AXDataSeriesDescriptor(name: name, isContinuous: true, dataPoints: steps.map { AXDataPoint(x: $0.date.timeIntervalSince1970, y: $0.value) })
        }
        var lines: [AXDataSeriesDescriptor] = []
        if !series.line.isEmpty { lines.append(line(T.Series.lineName(days: series.lineDays, held: series.held), series.line)) }
        for part in series.parts where !part.line.isEmpty {
            lines.append(line(T.Series.lineName(days: part.lineDays, split: part.split, held: part.held), part.line))
        }
        return AXChartDescriptor(title: T.title(metric), summary: summary ?? series.sentence, xAxis: x, yAxis: y, additionalAxes: [],
                                 series: [meetings] + lines)
    }
}
