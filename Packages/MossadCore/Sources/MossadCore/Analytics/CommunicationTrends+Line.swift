import Foundation

// MARK: The line

extension CommunicationTrends {
    /// The widths a step of the line can have, in days: whole weeks.
    static let widths = [7, 14, 28, 56, 91, 182, 364]
    /// More steps than this are a scribble, not a line.
    static let maximumSteps = 26

    /// The median of each week of the period, counted back from its last day.
    ///
    /// A median per week, not a rolling median of the last few meetings: the owner's meetings repeat by the
    /// week (the Monday staff meeting, the Thursday 1:1), so a window of whole weeks holds each of them the same
    /// number of times and the line moves when the owner changes, not when the window slides from the 1:1s to
    /// the staff meetings. A median, so one meeting that is not like the others moves nothing. The steps are
    /// even in days of the calendar, as the axis is, also across a change of the clocks.
    ///
    /// The width is the first of `widths` at which at least half of the steps hold `Usual.firmSamples` meetings
    /// (else `Usual.minimumSamples`) and the line has at most `maximumSteps` steps. The steps are counted from
    /// the first meeting when it comes a week or more into the period, so a library younger than the period
    /// still has a line. A step with fewer than `Usual.minimumSamples` meetings, or with fewer than half of what
    /// a step usually holds (the week of a holiday), is left out: its median is less sure than the others and
    /// would stand in the line as their equal. The line breaks there (`Step.segment`). The oldest step takes the
    /// days that do not fill a step of their own.
    static func line(_ points: [Point], interval: DateInterval, calendar: Calendar) -> (steps: [Step], days: Int) {
        guard let firstDate = points.map(\.date).min() else { return ([], widths[0]) }
        // The period's last day ends the last step, so "the last 90 days" does not cut today in two.
        let lastDay = calendar.startOfDay(for: max(interval.start, interval.end.addingTimeInterval(-1)))
        let end = calendar.date(byAdding: .day, value: 1, to: lastDay) ?? interval.end
        func daysBack(_ date: Date) -> Int { calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: end).day ?? 0 }
        let period = self.days(interval, calendar: calendar)
        let unused = period - daysBack(firstDate)
        let days = unused >= 7 ? period - unused : period
        let start = unused >= 7 ? calendar.startOfDay(for: firstDate) : interval.start
        let backs = points.map { max(0, daysBack($0.date) - 1) }

        func buckets(_ width: Int) -> [[Double]]? {
            let count = max(1, Int((Double(days) / Double(width)).rounded()))
            guard count <= maximumSteps else { return nil }
            var out = [[Double]](repeating: [], count: count)
            for (p, back) in zip(points, backs) { out[min(count - 1, back / width)].append(p.value) }
            return out
        }
        func fits(_ width: Int, _ least: Int) -> Bool {
            guard let counts = buckets(width)?.map({ Double($0.count) }) else { return false }
            return (median(of: counts) ?? 0) >= Double(least)
        }
        let usual = MeetingAnalytics.Usual.self
        guard let width = widths.first(where: { fits($0, usual.firmSamples) }) ?? widths.first(where: { fits($0, usual.minimumSamples) }),
              let filled = buckets(width) else { return ([], widths[0]) }

        let typical = median(of: filled.map { Double($0.count) }) ?? 0
        let least = max(usual.minimumSamples, Int((typical / 2).rounded(.up)))
        func day(_ back: Int) -> Date { calendar.date(byAdding: .day, value: -back, to: end) ?? end }
        var steps: [Step] = []
        var segment = 0, skipped = false
        for (back, values) in filled.enumerated().reversed() {
            guard values.count >= least, let value = median(of: values) else {
                skipped = !steps.isEmpty
                continue
            }
            if skipped { segment += 1; skipped = false }
            let newest = day(back * width)
            let oldest = back == filled.count - 1 ? start : day((back + 1) * width)
            steps.append(Step(date: oldest.addingTimeInterval(newest.timeIntervalSince(oldest) / 2), value: value, meetings: values.count, segment: segment))
        }
        return (steps.count >= 2 ? steps : [], width)
    }
}

// MARK: The scale

extension CommunicationTrends.Scale {
    /// From this many points the axis follows the middle of them, and a far point is drawn at the edge.
    static let percentilePoints = 20
    /// A point this part of the range outside is still taken in.
    static let reach = 0.25

    /// An axis that holds the usual band, the line, and the points, apart from a few that are far out: one
    /// burst of questions must not press every other meeting flat. Counts start at 0; a pace and a share start
    /// near their lowest value, because a line and points are read by position, not by length.
    init(_ metric: PersonMetric, values: [Double], usual: CommunicationTrends.Band?, line: [CommunicationTrends.Step]) {
        let sorted = values.sorted()
        guard let least = sorted.first, let most = sorted.last else {
            self = switch metric {
            case .talkShare: Self(lower: 0, upper: 1, step: 0.25)
            case .wordsPerMinute: Self(lower: 100, upper: 200, step: 25)
            default: Self(lower: 0, upper: 8, step: 2)
            }
            return
        }
        func percentile(_ p: Double) -> Double {
            let at = p * Double(sorted.count - 1)
            let below = Int(at.rounded(.down)), above = min(sorted.count - 1, below + 1)
            return sorted[below] + (sorted[above] - sorted[below]) * (at - Double(below))
        }
        let wide = sorted.count < Self.percentilePoints
        let others = (usual.map { [$0.low, $0.high] } ?? []) + line.map(\.value)
        var low = (others + [wide ? least : percentile(0.05)]).min()!
        var high = (others + [wide ? most : percentile(0.95)]).max()!
        // The least difference that matters is the least height of the axis, so equal values do not make an
        // axis of no height, and a small wobble does not fill the chart.
        let margin = metric.margin(median: median(of: sorted) ?? least)
        let reach = max(high - low, margin) * Self.reach
        if most <= high + reach { high = max(high, most) }
        if least >= low - reach { low = min(low, least) }
        if metric.isCount { low = 0 }
        if high - low < margin {
            let middle = (high + low) / 2
            low = metric.isCount ? 0 : middle - margin / 2
            high = low + margin
        }

        let step = Self.nice((high - low) / 4)
        // A value that is a whole number of steps must not fall one step down by its last binary digit.
        lower = Self.clean((low / step + 1e-9).rounded(.down) * step)
        upper = Self.clean((high / step - 1e-9).rounded(.up) * step)
        if metric == .talkShare {
            lower = max(0, lower)
            upper = min(1, upper)
        }
        self.step = step
    }

    /// The first of 1, 2, 5 times a power of ten that is at least `raw`.
    static func nice(_ raw: Double) -> Double {
        let power = pow(10, (log10(max(raw, 1e-9))).rounded(.down))
        return [1, 2, 5, 10].map { $0 * power }.first { $0 >= raw - 1e-12 } ?? 10 * power
    }

    /// 0.3, not the 0.30000000000000004 that three steps of 0.1 make.
    private static func clean(_ value: Double) -> Double { (value * 1e9).rounded() / 1e9 }

    /// The axis's marks, from the lower end to the upper.
    public var marks: [Double] {
        let count = Int(((upper - lower) / step).rounded())
        return (0...max(count, 1)).map { Self.clean(lower + Double($0) * step) }
    }
}

extension PersonMetric {
    /// True for a count per hour, which cannot go under 0 and is read from there.
    var isCount: Bool { self == .questionsPerHour || self == .cutInsPerHour || self == .cutOffsPerHour }
}
