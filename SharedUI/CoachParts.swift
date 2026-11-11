import Charts
import MossadCore
import SwiftUI

/// The coach's parts shared by the Mac and the iPhone. Each app puts them in its own cards.

func coachClock(_ t: TimeInterval) -> String {
    let s = Int(t)
    return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
}

extension FocusOutcome {
    var tint: Color {
        switch self {
        case .hit: .green
        case .missed: .orange
        case .noChance: .secondary
        }
    }

    var label: String {
        switch self {
        case .hit: "Hit"
        case .missed: "Missed"
        case .noChance: "No chance to try"
        }
    }
}

/// One dot per call on the focus, oldest first; the open call's dot has a ring.
struct FocusDots: View {
    let results: [FocusResult]
    var current: String?

    var body: some View {
        HStack(spacing: 5) {
            ForEach(results.suffix(10), id: \.callID) { r in
                Circle()
                    .fill(r.outcome == .noChance ? Color.secondary.opacity(0.3) : r.outcome.tint)
                    .frame(width: 11, height: 11)
                    .overlay { if r.callID == current { Circle().stroke(Color.accentColor, lineWidth: 2).padding(-3) } }
            }
        }
        .accessibilityLabel("\(results.filter { $0.outcome == .hit }.count) hits in \(results.filter { $0.outcome != .noChance }.count) chances")
    }
}

/// The focus at the top of every review: the agreed plan and how calls went on it, or a proposal to answer.
struct FocusPanel: View {
    let profile: CoachProfile
    /// The call being shown, to ring its dot and show its result.
    var callID: String?
    var result: FocusResult?
    /// On a review's page: the proposal is its plan and the three answers. The reason is in Settings and in the
    /// memory, so the same sentences do not stand under each call.
    var compact = false

    /// True when a review's page shows the panel: an accepted focus on each review, and a proposal only on the
    /// review of the call that made it. A proposal is advice that waits for an answer; under each call it would
    /// be the same advice after each call.
    static func belongs(to record: CallRecord, profile: CoachProfile) -> Bool {
        if profile.activeFocus != nil { return true }
        return profile.proposedFocus.map { abs($0.proposed.timeIntervalSince(record.start)) < 1 } ?? false
    }
    let accept: (UUID, String?) -> Void
    let dismiss: (UUID) -> Void
    @State private var editing = false
    @State private var text = ""

    var body: some View {
        if let f = profile.activeFocus {
            VStack(alignment: .leading, spacing: 8) {
                label("YOUR FOCUS" + (f.accepted.map { " · SINCE \($0.formatted(.dateTime.month(.abbreviated).day()).uppercased())" } ?? ""))
                Text(f.plan).font(.headline)
                if !f.results.isEmpty {
                    HStack(spacing: 10) {
                        FocusDots(results: f.results, current: callID)
                        Text("\(f.chances.filter { $0.outcome == .hit }.count) of \(f.chances.count) \(f.goal == nil ? "chances" : "1:1s at the target")")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                if let result {
                    (Text(result.outcome.label + ". ").foregroundStyle(result.outcome.tint).bold() + Text(result.evidence).foregroundStyle(.secondary))
                        .font(.subheadline)
                }
            }
        } else if let f = profile.proposedFocus {
            VStack(alignment: .leading, spacing: 8) {
                label("PROPOSED FOCUS")
                if editing {
                    TextField("Your focus", text: $text, axis: .vertical).textFieldStyle(.roundedBorder)
                } else {
                    Text(f.plan).font(.headline)
                }
                if !compact {
                    Text(f.why).font(.subheadline).foregroundStyle(.secondary)
                    Text("Nothing counts until you accept it. Each review then reports how the call went on it.")
                        .font(.caption).foregroundStyle(.tertiary)
                }
                HStack(spacing: 8) {
                    Button(editing ? "Save" : "Accept") {
                        accept(f.id, editing ? text : nil)
                        editing = false
                    }
                    .buttonStyle(.borderedProminent)
                    if !editing { Button("Edit") { text = f.plan; editing = true }.buttonStyle(.bordered) }
                    Button(editing ? "Cancel" : "Not now") { if editing { editing = false } else { dismiss(f.id) } }.buttonStyle(.bordered)
                }
                .controlSize(.small)
            }
        }
    }

    private func label(_ s: String) -> some View {
        Text(s).font(.caption2.weight(.semibold)).kerning(0.5).foregroundStyle(Color.accentColor)
    }
}

extension CoachLine {
    var symbol: String {
        switch kind {
        case .focus: "scope"
        case .progress: "chart.line.uptrend.xyaxis"
        case .tryNext: "arrow.forward.circle.fill"
        case .again: "arrow.triangle.2.circlepath"
        case .number: "chart.bar.fill"
        case .didWell: "hand.thumbsup.fill"
        }
    }

    var tint: Color {
        switch kind {
        case .focus: outcome?.tint ?? .accentColor
        case .progress: .teal
        case .tryNext, .again: .orange
        case .number: .blue
        case .didWell: .green
        }
    }

    /// The title, with the result for the focus: "Your focus · Hit".
    var heading: String { outcome.map { "\(title) · \($0.label)" } ?? title }
}

/// The coach's one line for a call, or that there is nothing to say. The rest of the review is the full review.
struct CoachLineView: View {
    let review: CoachReview
    /// Plays the call from a time, where the audio is here.
    var play: ((TimeInterval) -> Void)?

    var body: some View {
        if let line = review.shownLine {
            CoachLineRow(line: line, play: play)
        } else {
            VStack(alignment: .leading, spacing: 6) {
                Text(review.headline).font(.headline)
                if review.saysNothing {
                    Text(CoachLineView.nothing).font(.subheadline).foregroundStyle(.secondary)
                } else if !review.overview.isEmpty, review.overview != review.headline {
                    Text(review.overview).font(.subheadline).foregroundStyle(.secondary)
                }
            }
        }
    }

    /// A review with no line is a good review: said in one sentence, the same on each surface.
    static let nothing = "Nothing to work on from this one."
}

/// One line: what it is, the text, its proof (the owner's words with their time, or a measured number), and the
/// words to say.
struct CoachLineRow: View {
    let line: CoachLine
    var play: ((TimeInterval) -> Void)?

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: line.symbol).foregroundStyle(line.tint).frame(width: 18)
            VStack(alignment: .leading, spacing: 4) {
                Text(line.heading.uppercased()).font(.caption2.weight(.semibold)).kerning(0.5).foregroundStyle(line.tint)
                Text(line.text).fixedSize(horizontal: false, vertical: true)
                if line.quote != nil || line.at != nil {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        if let at = line.at {
                            if let play {
                                Button(coachClock(at)) { play(at) }.buttonStyle(.plain).foregroundStyle(Color.accentColor)
                            } else {
                                Text(coachClock(at)).foregroundStyle(.secondary)
                            }
                        }
                        if let q = line.quote { Text("“\(q)”").italic().foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
                    }
                    .font(.caption).monospacedDigit()
                }
                if let number = line.number {
                    Text(number).font(.caption).foregroundStyle(.secondary).monospacedDigit().fixedSize(horizontal: false, vertical: true)
                }
                if let say = line.say {
                    Text("Say: “\(say)”").font(.subheadline).fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 10).padding(.vertical, 7)
                        .background(line.tint.opacity(0.1), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
            }
        }
        .textSelection(.enabled)
        .accessibilityElement(children: .combine)
    }
}

/// Your numbers in this call against the goals and your usual.
struct GoalsGrid: View {
    let metrics: CallMetrics
    var focus: FocusMetric?

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), spacing: 12, alignment: .topLeading)], alignment: .leading, spacing: 12) {
            ForEach(metrics.checks) { c in
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 4) {
                        Text(name(c.metric)).font(.caption).foregroundStyle(.secondary)
                        if c.metric == focus { Image(systemName: "scope").font(.caption2).foregroundStyle(Color.accentColor) }
                    }
                    Text(value(c.metric, c.value)).font(.title3.weight(.semibold)).monospacedDigit()
                        .foregroundStyle(c.status == .over ? Color.orange : Color.primary)
                    Text(c.goal).font(.caption).foregroundStyle(.secondary)
                    Text(c.usual.map { "Your usual: " + value(c.metric, $0) } ?? " ").font(.caption).foregroundStyle(.tertiary)
                }
            }
        }
    }

    private func name(_ m: FocusMetric) -> String {
        switch m {
        case .talkShare: "Talk share"
        case .longestTurn: "Longest turn"
        case .questions: "Questions"
        case .pace: "Pace"
        }
    }

    private func value(_ m: FocusMetric, _ v: Double) -> String {
        switch m {
        case .talkShare: "\(Int((v * 100).rounded()))%"
        case .longestTurn: coachClock(v)
        case .questions: "\(Int(v.rounded()))"
        case .pace: "\(Int(v)) wpm"
        }
    }
}

/// Your share of the talking every 3 minutes, with turns over 2 minutes marked.
struct CallStrip: View {
    let metrics: CallMetrics

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Chart {
                ForEach(metrics.timeline) { s in
                    BarMark(x: .value("Minute", s.start / 60 + 1.5), y: .value("Your share", s.share * 100), width: .ratio(0.8))
                        .foregroundStyle(Color.accentColor.opacity(0.35 + s.share * 0.5))
                        .cornerRadius(2)
                }
                ForEach(metrics.longTurns, id: \.start) { t in
                    RectangleMark(xStart: .value("Start", t.start / 60), xEnd: .value("End", (t.start + t.seconds) / 60), yStart: .value("Low", 0), yEnd: .value("High", 100))
                        .foregroundStyle(Color.orange.opacity(0.18))
                        .annotation(position: .top, alignment: .leading) {
                            Text("\(coachClock(t.seconds)) turn").font(.caption2).foregroundStyle(.orange)
                        }
                }
            }
            .chartYScale(domain: 0...100)
            .chartYAxis { AxisMarks(values: [0, 50, 100]) { v in AxisGridLine(); AxisValueLabel { Text("\(v.as(Int.self) ?? 0)%") } } }
            .chartXAxis { AxisMarks { v in AxisValueLabel { Text("\(Int(v.as(Double.self) ?? 0)) min") } } }
            .frame(height: 110)
            Text("Your share of the talking, every 3 minutes" + (metrics.longTurns.isEmpty ? "" : ". Orange marks turns over 2 minutes."))
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}
