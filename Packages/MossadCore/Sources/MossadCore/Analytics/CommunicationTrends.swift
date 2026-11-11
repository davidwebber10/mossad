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
    public enum Change: Sendable, Equatable {
        /// The period is shorter than `minimumDays`.
        case tooShort
        /// One of the two thirds has fewer than `Usual.firmSamples` meetings.
        case tooFew
        case steady
        /// The number moved, and the mix of 1:1s and groups explains it.
        case mixed
        /// The medians of the first and the last third.
        case moved(from: Double, to: Double)
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
        /// Empty with fewer than two steps.
        public var line: [Step]
        /// How many days one step of the line covers.
        public var lineDays: Int
        public var usual: Band?
        public var change: Change
        /// The median of the points; nil without points.
        public var typical: Double?
        /// The whole days of the period.
        public var days: Int
        public var scale: Scale
    }

    public let interval: DateInterval
    /// The splits there is something to choose between: all three when the period has 1:1s and groups, else none.
    public let splits: [Split]
    private let all: [Split: [Series]]

    /// One series per number of `metrics`, in that order.
    public func series(_ split: Split) -> [Series] { all[split] ?? [] }
    public func series(_ metric: PersonMetric, _ split: Split) -> Series { series(split).first { $0.metric == metric }! }

    /// One meeting's number, with the size the meeting counts for.
    struct Row {
        var point: Point
        var size: Split?
    }

    /// A meeting of two main voices is a 1:1 and one of more is a group; one voice alone is neither.
    static func size(_ facts: MeetingFacts) -> Split? { facts.mainVoices == 2 ? .oneOnOne : facts.mainVoices > 2 ? .group : nil }

    /// `facts` is every written meeting, in any order: the ones before `interval` say what is usual.
    public init(facts: [MeetingFacts], interval: DateInterval, calendar: Calendar = .current) {
        self.interval = interval
        let days = max(1, Int((interval.duration / 86_400).rounded()))
        let sorted = facts.sorted { ($0.start, $0.id) < ($1.start, $1.id) }
        var all: [Split: [Series]] = [:]
        for split in Split.allCases {
            let meetings = sorted.filter { split == .all || Self.size($0) == split }
            all[split] = Self.metrics.map { metric in
                let rows = meetings.compactMap { f in
                    f.owner?.values[metric].map { Row(point: Point(id: f.id, date: f.start, value: $0, title: f.title), size: Self.size(f)) }
                }
                return Series(metric, rows: rows, interval: interval, days: days, mixed: split == .all, calendar: calendar)
            }
        }
        self.all = all
        let sizes = Set(sorted.filter { interval.contains($0.start) && $0.owner != nil }.compactMap(Self.size))
        splits = sizes.count == 2 ? Split.allCases : []
    }
}

extension CommunicationTrends.Series {
    typealias T = CommunicationTrends

    /// `rows` is every meeting with the number, oldest first. `mixed` says that they are of both sizes.
    init(_ metric: PersonMetric, rows: [T.Row], interval: DateInterval, days: Int, mixed: Bool, calendar: Calendar) {
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

        (line, lineDays) = T.line(points, interval: interval, calendar: calendar)
        change = T.change(metric, inside, interval: interval, days: days, mixed: mixed)
        scale = T.Scale(metric, values: values, usual: usual, line: line)
    }
}
