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
                       goal: TrendChart.Goal(start: progress.start, target: progress.goal.target, spoken: progress.spoken,
                                             targetLabel: "Target \(CommunicationTrends.short(.talkShare, progress.goal.target))",
                                             startLabel: "Goal taken \(progress.start.formatted(.dateTime.month(.abbreviated).day()))"),
                       open: open)
                .frame(height: height)
            key
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: Space.l) {
            VStack(alignment: .leading, spacing: Rhythm.pairGap) {
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
                    VStack(alignment: .trailing, spacing: Rhythm.pairGap) {
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

    /// Three marks; the target and the day of the goal are labels on the chart.
    @ViewBuilder
    private var keys: some View {
        HStack(spacing: Space.s) {
            Circle().fill(TrendChart.pointColor).frame(width: 7, height: 7)
            Text("Each 1:1")
        }
        if !progress.series.line.isEmpty {
            HStack(spacing: Space.s) {
                Capsule().fill(Palette.accentFill).frame(width: 14, height: 2.5)
                Text(progress.typicalSince == nil ? "Median before the goal" : "Median before and since the goal")
            }
        }
        HStack(spacing: Space.s) {
            RoundedRectangle(cornerRadius: 2, style: .continuous).fill(Palette.accentTint).frame(width: 14, height: 9)
            Text("Before the goal \(CommunicationTrends.range(.talkShare, progress.series.usual?.low ?? progress.goal.low, progress.series.usual?.high ?? progress.goal.high))")
        }
    }
}
