import MossadCore
import SwiftUI

/// A goal's number over time: the sentence that says whether it moved (from code, never from the model), the
/// target and the typical meeting since the goal, the chart of each meeting with what was usual before the goal as
/// its band, and what the marks are.
struct GoalProgressPanel: View {
    let progress: GoalProgress
    var height: CGFloat = TrendPanel.chartHeight
    /// Opens the meeting with this id.
    let open: (String) -> Void

    private var moved: Bool {
        switch progress.state {
        case .toward, .away: true
        default: false
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.m) {
            header
            TrendChart(series: progress.series, interval: progress.interval,
                       goal: TrendChart.Goal(start: progress.start, target: progress.goal.target, spoken: progress.spoken), open: open)
                .frame(height: height)
            key
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: Space.l) {
            VStack(alignment: .leading, spacing: 3) {
                Text(progress.goal.measure?.title ?? "").textRole(.headline).foregroundStyle(Palette.ink)
                    .accessibilityAddTraits(.isHeader)
                // A change is news and reads in ink; "too early" and "no clear change" stay quiet.
                Text(progress.sentence).textRole(.body).fontWeight(moved ? .medium : .regular)
                    .foregroundStyle(progress.reached ? Palette.okText : moved ? Palette.ink : Palette.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    #if os(macOS)
                    .help(progress.basis)
                    #endif
                #if os(iOS)
                Text(figures.map { "\($0.value) \($0.label)" }.joined(separator: " · ")).textRole(.secondary).foregroundStyle(Palette.secondary)
                #endif
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            #if os(macOS)
            HStack(alignment: .top, spacing: Space.xl) {
                ForEach(figures, id: \.label) { f in
                    VStack(alignment: .trailing, spacing: 1) {
                        Text(f.value).textRole(.title).foregroundStyle(f.label == "target" ? TrendChart.targetColor : Palette.ink).monospacedDigit()
                        Text(f.label).textRole(.secondary).foregroundStyle(Palette.secondary)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
            #endif
        }
    }

    /// The target, and the typical 1:1 since the goal once there are enough of them to say it.
    private var figures: [(value: String, label: String)] {
        var out = [(CommunicationTrends.short(.talkShare, progress.goal.target) + " or less", "target")]
        if let typical = progress.typicalSince { out.append((CommunicationTrends.short(.talkShare, typical), "typical 1:1 since")) }
        return out
    }

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
            Text("Each 1:1")
        }
        if !progress.series.line.isEmpty {
            HStack(spacing: 6) {
                Capsule().fill(Palette.accentFill).frame(width: 14, height: 2.5)
                Text(CommunicationTrends.Series.lineName(days: progress.series.lineDays, held: progress.series.held))
            }
        }
        HStack(spacing: 6) {
            RoundedRectangle(cornerRadius: 2, style: .continuous).fill(Palette.accentTint).frame(width: 14, height: 9)
            Text("Before the goal \(CommunicationTrends.range(.talkShare, progress.goal.low, progress.goal.high))")
        }
        HStack(spacing: 6) {
            Path { p in p.move(to: CGPoint(x: 0, y: 1)); p.addLine(to: CGPoint(x: 14, y: 1)) }
                .stroke(TrendChart.targetColor, style: StrokeStyle(lineWidth: 1.5, lineCap: .round, dash: [5, 4]))
                .frame(width: 14, height: 2)
            Text("Target")
        }
        HStack(spacing: 6) {
            Path { p in p.move(to: CGPoint(x: 1, y: 0)); p.addLine(to: CGPoint(x: 1, y: 10)) }
                .stroke(Palette.secondary.opacity(0.7), style: StrokeStyle(lineWidth: 1, dash: [2, 3]))
                .frame(width: 2, height: 10)
            Text("Goal taken \(progress.start.formatted(.dateTime.month(.abbreviated).day()))")
        }
    }
}
