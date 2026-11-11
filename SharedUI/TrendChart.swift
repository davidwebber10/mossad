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
                    #if os(macOS)
                    .help(series.basis)
                    #endif
                #if os(iOS)
                // The iPhone has no room beside the sentence, so the typical value is a line under it.
                if let typical = series.typical {
                    Text("\(T.short(series.metric, typical)) \(typicalCaption)").textRole(.secondary).foregroundStyle(Palette.secondary)
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
            }
            #endif
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
                Text(lineName)
            }
        }
        if let usual = series.usualText {
            HStack(spacing: 6) {
                RoundedRectangle(cornerRadius: 2, style: .continuous).fill(Palette.accentTint).frame(width: 14, height: 9)
                Text(usual)
            }
        }
    }

    private var lineName: String {
        let weeks = series.lineDays / 7
        return weeks <= 1 ? "Median of each week" : "Median of each \(weeks) weeks"
    }
}

/// The chart of a `TrendPanel`: every meeting a quiet point, the median of each week a strong line, the usual
/// range a soft band. Point at a meeting on the Mac, or drag across on the iPhone, for its title, day, and value;
/// a click on the Mac opens it, and the iPhone shows a row that does.
struct TrendChart: View {
    typealias T = CommunicationTrends

    let series: T.Series
    let interval: DateInterval
    let open: (String) -> Void

    @State private var picked: T.Point?
    #if os(iOS)
    @State private var scrub: Date?
    #endif

    /// The meetings are context for the line, so they take no hue.
    static let pointColor = Palette.secondary.opacity(0.5)
    /// The pointer picks the nearest meeting within this many points.
    private static let reach: CGFloat = 28

    private var scale: T.Scale { series.scale }
    private func inside(_ value: Double) -> Double { min(max(value, scale.lower), scale.upper) }

    var body: some View {
        let chart = Chart {
            if let band = series.usual, band.high >= scale.lower, band.low <= scale.upper {
                RectangleMark(xStart: .value("From", interval.start), xEnd: .value("To", interval.end),
                              yStart: .value("Low", inside(band.low)), yEnd: .value("High", inside(band.high)))
                    .foregroundStyle(Palette.accentTint)
            }
            ForEach(series.points) { p in
                if p.value > scale.upper || p.value < scale.lower {
                    // Further out than the axis goes: an arrow at the edge says so, and the value is in its label.
                    PointMark(x: .value("Date", p.date), y: .value("Value", inside(p.value)))
                        .symbol {
                            Image(systemName: p.value > scale.upper ? "arrowtriangle.up.fill" : "arrowtriangle.down.fill")
                                .font(.system(size: 7)).foregroundStyle(Self.pointColor)
                        }
                } else {
                    PointMark(x: .value("Date", p.date), y: .value("Value", p.value))
                        .symbolSize(34)
                        .foregroundStyle(Self.pointColor)
                }
            }
            ForEach(series.line) { step in
                LineMark(x: .value("Date", step.date), y: .value("Median", step.value))
                    .interpolationMethod(.monotone)
                    .lineStyle(StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
                    .foregroundStyle(Palette.accentFill)
            }
            if let picked {
                PointMark(x: .value("Date", picked.date), y: .value("Value", inside(picked.value)))
                    .symbol {
                        Circle().fill(Palette.accent).frame(width: 9, height: 9)
                            .overlay { Circle().strokeBorder(Palette.window, lineWidth: 2).padding(-2) }
                    }
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
        .animation(.smooth, value: series.points.map(\.id))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(series.spoken)
        .accessibilityChartDescriptor(TrendDescriptor(series: series))
        .chartOverlay { proxy in
            GeometryReader { geometry in
                if let plot = proxy.plotFrame { layer(proxy, plot: geometry[plot], size: geometry.size) }
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
                .accessibilityHint("Drag across the chart to read a meeting")
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
        .onChange(of: series.points.map(\.id)) { _, ids in
            if let id = picked?.id, !ids.contains(id) { picked = nil }
        }
        .onAppear(perform: pickForPreview)
        #else
        chart
            // A meeting can leave the chart while the pointer rests on it.
            .onChange(of: series.points.map(\.id)) { _, _ in picked = nil }
            .onAppear(perform: pickForPreview)
        #endif
    }

    /// What lies over the plot: on the Mac the surface that follows the pointer, and on both the label of the
    /// picked meeting. The label sits over its point, or under it when there is no room above, and stays
    /// inside the chart.
    private func layer(_ proxy: ChartProxy, plot: CGRect, size: CGSize) -> some View {
        ZStack(alignment: .topLeading) {
            #if os(macOS)
            Color.clear
                .contentShape(Rectangle())
                .onContinuousHover { phase in
                    switch phase {
                    case .active(let at): picked = nearest(to: CGPoint(x: at.x - plot.minX, y: at.y - plot.minY), proxy)
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
                TrendTip(metric: series.metric, point: picked)
                    .alignmentGuide(.leading) { d in -min(max(x - d.width / 2, 0), max(0, size.width - d.width)) }
                    .alignmentGuide(.top) { d in -(y - Self.tipGap - d.height >= 0 ? y - Self.tipGap - d.height : y + Self.tipGap) }
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
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

    /// From the picked point to its label.
    private static let tipGap: CGFloat = 12

    #if os(iOS)
    private static let dateMarks = 4
    private static let axisFont = Font.caption2

    private func nearest(to date: Date) -> T.Point? {
        series.points.min { abs($0.date.timeIntervalSince(date)) < abs($1.date.timeIntervalSince(date)) }
    }
    #else
    private static let dateMarks = 7
    private static let axisFont = Font.system(size: 10.5)

    /// The meeting whose point is nearest to the pointer, so the pointer does not have to land on a dot.
    private func nearest(to pointer: CGPoint, _ proxy: ChartProxy) -> T.Point? {
        var best: (point: T.Point, distance: CGFloat)?
        for p in series.points {
            guard let at = proxy.position(for: (x: p.date, y: inside(p.value))) else { continue }
            let distance = hypot(at.x - pointer.x, at.y - pointer.y)
            if distance <= Self.reach, distance < best?.distance ?? .infinity { best = (p, distance) }
        }
        return best?.point
    }
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

    func makeChartDescriptor() -> AXChartDescriptor {
        typealias T = CommunicationTrends
        let metric = series.metric
        func day(_ date: Date) -> String { date.formatted(date: .abbreviated, time: .shortened) }
        let x = AXCategoricalDataAxisDescriptor(title: "Meeting", categoryOrder: series.points.map { day($0.date) } + series.line.map { day($0.date) })
        // The far meetings that the chart draws at its edge are in the table with their own values.
        let values = series.points.map(\.value) + [series.scale.lower, series.scale.upper]
        let y = AXNumericDataAxisDescriptor(title: T.axis(metric), range: values.min()!...values.max()!, gridlinePositions: series.scale.marks) {
            T.text(metric, $0)
        }
        let meetings = AXDataSeriesDescriptor(name: "Each meeting", isContinuous: false, dataPoints: series.points.map {
            AXDataPoint(x: day($0.date), y: $0.value, label: $0.title)
        })
        let line = AXDataSeriesDescriptor(name: "Median of each \(series.lineDays) days", isContinuous: true, dataPoints: series.line.map {
            AXDataPoint(x: day($0.date), y: $0.value)
        })
        return AXChartDescriptor(title: T.title(metric), summary: series.sentence, xAxis: x, yAxis: y, additionalAxes: [],
                                 series: series.line.isEmpty ? [meetings] : [meetings, line])
    }
}
