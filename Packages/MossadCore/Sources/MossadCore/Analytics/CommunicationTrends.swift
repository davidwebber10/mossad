import Foundation

/// The owner's numbers of "How you communicate" across a period: one point per meeting, a line through them, the
/// usual range, and a sentence that says whether the number moved. Pure; made from the meetings' facts
/// (`MeetingFactsCache`), so a point is the number that the meeting's own Analytics tab shows.
///
/// A meeting that cannot give a number has no point for it, never a 0.
public struct CommunicationTrends: Sendable, Equatable {
    /// The meetings a chart is made from. A talk share and cut-ins follow the size of the meeting, so the two
    /// sizes can be read apart.
    public enum Split: String, Sendable, CaseIterable, Identifiable {
        case all, oneOnOne, group
        public var id: String { rawValue }
    }

    /// The numbers of the section, in its order.
    public static let metrics: [PersonMetric] = [.talkShare, .questionsPerHour, .cutInsPerHour, .wordsPerMinute]

    public struct Point: Sendable, Equatable, Identifiable {
        /// The meeting's id.
        public var id: String
        public var date: Date
        public var value: Double
        public var title: String
    }

    /// One value of the line: the median of the meetings of some weeks, in the middle of those weeks.
    public struct Step: Sendable, Equatable, Identifiable {
        public var id: Date { date }
        public var date: Date
        public var value: Double
        public var meetings: Int
        /// The piece of the line the step is in: a step left out between two steps breaks the line, so the line
        /// does not cross a week as if it had a value there.
        public var segment: Int = 0
    }

    /// In the chart of all meetings, one size's own line, for a number that follows the size: the line of all
    /// sizes would move with the mix of 1:1s and groups and say something other than the sentence.
    public struct Part: Sendable, Equatable, Identifiable {
        public var id: Split { split }
        public var split: Split
        public var line: [Step]
        public var lineDays: Int
        /// The median of the size's meetings.
        public var typical: Double?
        /// See `Series.held`.
        public var held: Bool
    }

    /// What is usual for the number, by the rule of the meeting baselines (`MeetingAnalytics.Usual`).
    public struct Band: Sendable, Equatable {
        public var usual: MeetingAnalytics.Usual
        /// True when it comes from the meetings before the period; false when those are too few and it is the
        /// period's own range.
        public var fromBefore: Bool

        public var low: Double { usual.low }
        public var high: Double { usual.high }
        public var median: Double { usual.median }
        public var meetings: Int { usual.samples }
    }

    /// The first third of the period against the last third.
    public indirect enum Change: Sendable, Equatable {
        /// The period is shorter than `minimumDays`.
        case tooShort
        /// One of the two thirds has fewer than `Usual.firmSamples` meetings.
        case tooFew
        case steady
        /// The medians of the first and the last third.
        case moved(from: Double, to: Double)
        /// For a number that follows the size of the meeting, over meetings of both sizes: each size's own
        /// change. More 1:1s and fewer groups raise a talk share with no change in how the owner talks, so the
        /// two sizes are never compared as one, as in the baselines. Inside the groups, each group size and
        /// each kind of meeting is compared with itself (`Mix`).
        case bySize(oneOnOne: Change, group: Change)

        /// True when the number moved, in one size at least.
        public var moved: Bool {
            switch self {
            case .moved: true
            case .bySize(let one, let group): one.moved || group.moved
            default: false
            }
        }
    }

    /// The value axis: its ends and the distance between its marks.
    public struct Scale: Sendable, Equatable {
        public var lower: Double
        public var upper: Double
        public var step: Double
    }

    public struct Series: Sendable, Equatable, Identifiable {
        public var id: PersonMetric { metric }
        public var metric: PersonMetric
        /// The period's meetings with this number, oldest first.
        public var points: [Point]
        /// Empty with fewer than two steps, and in the chart of all meetings when it has `parts`.
        public var line: [Step]
        /// How many days one step of the line covers.
        public var lineDays: Int
        /// True when the line is of more than one kind of meeting, each moved to the typical level (`Mix`): it
        /// moves when the owner changes, not when the mix of meetings does, and so does the sentence.
        public var held: Bool
        /// The line of each size, in place of `line`, `usual`, and `typical`, when the chart of all meetings
        /// holds 1:1s and groups and the number follows the size.
        public var parts: [Part]
        public var usual: Band?
        public var change: Change
        /// The median of the points; nil without points, and nil when the chart has `parts`.
        public var typical: Double?
        /// The days of the calendar that the period covers.
        public var days: Int
        public var scale: Scale
    }

    public let interval: DateInterval
    /// The splits there is something to choose between: all three when the period has 1:1s and groups, else none.
    public let splits: [Split]
    private let all: [Split: [Series]]

    /// One series per number of `metrics`, in that order.
    public func series(_ split: Split) -> [Series] { all[split] ?? [] }
    /// Nil for a number that is not in `metrics`.
    public func series(_ metric: PersonMetric, _ split: Split) -> Series? { series(split).first { $0.metric == metric } }

    /// One meeting's number, with the size the meeting counts for and the kind of meeting it is compared within.
    struct Row {
        var point: Point
        var size: Split?
        /// Its kind of meeting: the group size when the number follows it, and the series or else the kind.
        var kind: String
        /// The same with only the group size, for a kind of meeting that is not in the two thirds compared.
        var sizeKind: String
    }

    /// The people of the meeting, with the owner counted when the owner said too little to be a main voice: two
    /// others who talk while the owner listens are a group of three, not a 1:1 of the owner at 1%.
    static func voices(_ facts: MeetingFacts) -> Int { facts.mainVoices + (facts.owner?.isMain == false ? 1 : 0) }

    /// A meeting of two people is a 1:1 and one of more is a group; one voice alone is neither.
    static func size(_ facts: MeetingFacts) -> Split? {
        let voices = voices(facts)
        return voices == 2 ? .oneOnOne : voices > 2 ? .group : nil
    }

    static func row(_ f: MeetingFacts, _ metric: PersonMetric) -> Row? {
        guard let value = f.owner?.values[metric] else { return nil }
        let size = size(f)
        // One voice alone has no share of a talk; a cut-in needs the word times that only the Mac keeps.
        if metric == .talkShare, size == nil { return nil }
        if metric.isCount, metric != .questionsPerHour, !f.hasWordTimes { return nil }
        let sizeKind = metric.followsSizeInTrend ? "\(size == nil ? "alone" : MeetingFacts.Size(voices: voices(f)).words)|" : "|"
        let kind = sizeKind + (f.series ?? f.kind?.lowercased() ?? "")
        return Row(point: Point(id: f.id, date: f.start, value: value, title: f.title), size: size, kind: kind, sizeKind: sizeKind)
    }

    /// The days of the calendar that the period covers: 90 for "the last 90 days", which begins at the start
    /// of a day and ends now.
    public static func days(_ interval: DateInterval, calendar: Calendar = .current) -> Int {
        let first = calendar.startOfDay(for: interval.start)
        let last = calendar.startOfDay(for: max(interval.start, interval.end.addingTimeInterval(-1)))
        return (calendar.dateComponents([.day], from: first, to: last).day ?? 0) + 1
    }

    /// `facts` is every written meeting, in any order: the ones before `interval` say what is usual.
    public init(facts: [MeetingFacts], interval: DateInterval, calendar: Calendar = .current) {
        self.interval = interval
        let days = Self.days(interval, calendar: calendar)
        let sorted = facts.sorted { ($0.start, $0.id) < ($1.start, $1.id) }
        var all: [Split: [Series]] = [:]
        for split in Split.allCases {
            let meetings = sorted.filter { split == .all || Self.size($0) == split }
            all[split] = Self.metrics.map { metric in
                Series(metric, rows: meetings.compactMap { Self.row($0, metric) }, interval: interval, days: days, calendar: calendar,
                       split: split)
            }
        }
        self.all = all
        let sizes = Set(sorted.filter { interval.contains($0.start) && $0.owner != nil }.compactMap(Self.size))
        splits = sizes.count == 2 ? Split.allCases : []
    }
}

extension CommunicationTrends.Series {
    typealias T = CommunicationTrends

    /// `rows` is every meeting with the number, oldest first.
    init(_ metric: PersonMetric, rows: [T.Row], interval: DateInterval, days: Int, calendar: Calendar, split: T.Split) {
        self.metric = metric
        self.days = days
        let inside = rows.filter { interval.contains($0.point.date) }
        points = inside.map(\.point)
        let values = points.map(\.value)
        typical = median(of: values)

        // The usual going into the period, from its most recent meetings: what was normal long ago is not what
        // is normal now. "Usual" is said from five meetings, as on the meeting page.
        let before = rows.filter { $0.point.date < interval.start }.suffix(MeetingAnalytics.History.ownerLimit).map(\.point.value)
        if let u = MeetingAnalytics.Usual(Array(before)), u.isFirm {
            usual = T.Band(usual: u, fromBefore: true)
        } else if let u = MeetingAnalytics.Usual(values), u.isFirm {
            usual = T.Band(usual: u, fromBefore: false)
        } else {
            usual = nil
        }

        let ones = inside.filter { $0.size == .oneOnOne }, groups = inside.filter { $0.size == .group }
        if split == .all, metric.followsSize, !ones.isEmpty, !groups.isEmpty {
            // 1:1s and groups sit far apart: a line, a range, or a typical meeting of the two together moves
            // with their mix. Each size has its own line, and the sentence compares each size with itself.
            let one = T.Mix(ones, interval: interval), group = T.Mix(groups, interval: interval)
            parts = [(T.Split.oneOnOne, one), (.group, group)].map { size, mix in
                let (line, width) = T.line(mix.points, interval: interval, calendar: calendar)
                return T.Part(split: size, line: line, lineDays: width, typical: median(of: mix.points.map(\.value)), held: mix.held)
            }
            line = []
            lineDays = parts[0].lineDays
            held = false
            usual = nil
            typical = nil
            change = .bySize(oneOnOne: T.change(metric, one, interval: interval, days: days), group: T.change(metric, group, interval: interval, days: days))
        } else {
            let mix = T.Mix(inside, interval: interval)
            (line, lineDays) = T.line(mix.points, interval: interval, calendar: calendar)
            held = mix.held
            parts = []
            change = T.change(metric, mix, interval: interval, days: days)
        }
        scale = T.Scale(metric, values: values, usual: usual, line: line + parts.flatMap(\.line))
    }
}

extension PersonMetric {
    /// A number that a trend compares only within one group size: the ones that follow the size, and the
    /// questions, which are counted per hour of the call, and the owner talks more of a 1:1's hour than of a
    /// group's.
    var followsSizeInTrend: Bool { followsSize || self == .questionsPerHour }
}
