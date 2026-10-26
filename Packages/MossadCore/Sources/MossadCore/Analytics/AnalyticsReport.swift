import Foundation

public enum AnalyticsRange: Hashable, Sendable {
    case last7Days, last30Days, last90Days, thisMonth, lastMonth, yearToDate, all
    /// Whole days, both inclusive.
    case custom(Date, Date)

    public func interval(now: Date = Date(), calendar: Calendar = .current, earliest: Date? = nil) -> DateInterval {
        let today = calendar.startOfDay(for: now)
        func daysBack(_ n: Int) -> Date { calendar.date(byAdding: .day, value: -(n - 1), to: today)! }
        let start: Date = switch self {
        case .last7Days: daysBack(7)
        case .last30Days: daysBack(30)
        case .last90Days: daysBack(90)
        case .thisMonth: calendar.dateInterval(of: .month, for: now)!.start
        case .lastMonth: calendar.date(byAdding: .month, value: -1, to: calendar.dateInterval(of: .month, for: now)!.start)!
        case .yearToDate: calendar.dateInterval(of: .year, for: now)!.start
        case .all: calendar.startOfDay(for: min(earliest ?? today, today))
        case .custom(let a, _): calendar.startOfDay(for: a)
        }
        if self == .lastMonth { return DateInterval(start: start, end: calendar.dateInterval(of: .month, for: now)!.start) }
        if case .custom(_, let b) = self {
            return DateInterval(start: start, end: max(start, calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: b))!))
        }
        return DateInterval(start: start, end: max(start, now))
    }

    /// The same number of whole days just before (`by` -1) or after (+1) the period shown, as a custom range.
    public static func step(_ i: DateInterval, by direction: Int, calendar: Calendar = .current) -> AnalyticsRange {
        let first = calendar.startOfDay(for: i.start)
        let last = calendar.startOfDay(for: i.end.addingTimeInterval(-1))
        let days = (calendar.dateComponents([.day], from: first, to: last).day ?? 0) + 1
        let start = calendar.date(byAdding: .day, value: direction * days, to: first)!
        return .custom(start, calendar.date(byAdding: .day, value: days - 1, to: start)!)
    }

    /// The period of the same length just before, for the comparison figures.
    public static func previous(_ i: DateInterval) -> DateInterval {
        DateInterval(start: i.start.addingTimeInterval(-i.duration), duration: i.duration)
    }
}

/// Everything the Analytics tab shows for one period. Pure, so it is tested without the app.
public struct AnalyticsReport: Sendable {
    public enum Bucket: Sendable { case day, week, month }

    public struct Bar: Sendable, Identifiable {
        public var id: Date { date }
        public var date: Date
        public var seconds: TimeInterval = 0
        public var calls = 0
        /// Calls matched to a calendar invite; the rest were ad hoc.
        public var scheduledCalls = 0
        public var cost: [UsageEvent.Service: Double] = [:]
    }

    public struct HeatCell: Sendable, Hashable {
        /// 1 is Sunday, as in `Calendar`.
        public var weekday: Int
        public var hour: Int
        public var seconds: TimeInterval
    }

    public struct Slice: Sendable, Identifiable {
        public var id: String { name }
        public var name: String
        public var seconds: TimeInterval
        public var calls: Int
    }

    public struct PersonTime: Sendable, Identifiable {
        public var id: String { name }
        public var name: String
        public var seconds: TimeInterval
        public var calls: Int
        /// Speech in the calls they shared with the owner: the owner's, and theirs.
        public var mySpeech: TimeInterval = 0
        public var theirSpeech: TimeInterval = 0
        public var lastMet: Date?
        /// Calls together per bucket, in the order of `days`.
        public var trend: [Int] = []
    }

    public struct DeliveryPoint: Sendable, Identifiable {
        public var id: String { callID }
        public var callID: String
        public var date: Date
        public var wordsPerMinute: Double
        public var fillersPerMinute: Double
        public var talkShare: Double
    }

    public struct Cost: Sendable {
        public var total = 0.0
        public var byService: [UsageEvent.Service: Double] = [:]
        public var byPurpose: [UsageEvent.Purpose: Double] = [:]
        /// The part of the total that is estimated, 0 to 1.
        public var estimatedShare = 0.0
        public var perCall = 0.0
        public var perCallHour = 0.0
    }

    public let interval: DateInterval
    public let bucket: Bucket
    public let records: [CallRecord]
    public var calls: Int { records.count }
    public let callSeconds: TimeInterval
    public var averageSeconds: TimeInterval { calls > 0 ? callSeconds / Double(calls) : 0 }
    public let longest: CallRecord?
    public let actionItems: Int
    /// The owner's part of all speech, nil when nobody spoke.
    public let talkShare: Double?
    public let people: [PersonTime]
    public let platforms: [Slice]
    public let kinds: [Slice]
    /// Time per topic tag; a call with three tags counts toward each.
    public let tags: [Slice]
    public let days: [Bar]
    public let heat: [HeatCell]
    public let delivery: [DeliveryPoint]
    /// Time in coached calls by the coach's value rating.
    public let valueSeconds: [MeetingValue.Rating: TimeInterval]
    /// Meeting titles rated low more than once in the period: the first ones to change.
    public let lowValueRepeats: [Slice]
    public let cost: Cost
    /// Calls matched to a calendar invite, and the rest (ad hoc calls).
    public let scheduled: Slice
    public let unscheduled: Slice
    public let workday: Workday
    public let communication: Communication
    public let outcomes: Outcomes
    /// Calls per calendar day in the period.
    public var callsPerDay: Double { Double(calls) / max(1, (interval.duration / 86_400).rounded()) }
    /// The bucket with the most calls.
    public var busiestDay: Bar? { days.max { $0.calls < $1.calls }.flatMap { $0.calls > 0 ? $0 : nil } }

    public init(records all: [CallRecord], usage: [UsageEvent], owner: String, interval: DateInterval,
                reviews: [String: CoachReview] = [:], commitments: [Commitment] = [], calendar: Calendar = .current) {
        self.interval = interval
        let span = interval.duration / 86_400
        bucket = span > 400 ? .month : span > 62 ? .week : .day
        records = all.filter { $0.status != .recording && interval.contains($0.start) }.sorted { $0.start < $1.start }
        func length(_ r: CallRecord) -> TimeInterval { max(0, r.end.timeIntervalSince(r.start)) }
        callSeconds = records.map(length).reduce(0, +)
        let planned = records.filter { $0.calendarTitle != nil }, adHoc = records.filter { $0.calendarTitle == nil }
        scheduled = Slice(name: "Scheduled", seconds: planned.map(length).reduce(0, +), calls: planned.count)
        unscheduled = Slice(name: "Unscheduled", seconds: adHoc.map(length).reduce(0, +), calls: adHoc.count)
        longest = records.max { length($0) < length($1) }
        actionItems = records.map(\.actionItems.count).reduce(0, +)

        var mine = 0.0, speech = 0.0
        var people: [String: PersonTime] = [:]
        var platforms: [String: Slice] = [:], kinds: [String: Slice] = [:], tags: [String: Slice] = [:]
        for r in records {
            for u in r.utterances {
                let d = max(0, u.end - u.start)
                speech += d
                if r.speakerNames[u.speakerKey] == owner { mine += d }
            }
            let exchange = Exchange(record: r)
            for name in Set(r.speakerNames.values) where name != owner {
                people[name, default: PersonTime(name: name, seconds: 0, calls: 0)].seconds += length(r)
                people[name]!.calls += 1
                people[name]!.mySpeech += exchange.speech(owner)
                people[name]!.theirSpeech += exchange.speech(name)
                people[name]!.lastMet = max(people[name]!.lastMet ?? r.start, r.start)
            }
            platforms[r.platform.displayName, default: Slice(name: r.platform.displayName, seconds: 0, calls: 0)].seconds += length(r)
            platforms[r.platform.displayName]!.calls += 1
            for t in Set(r.tags) {
                tags[t, default: Slice(name: t, seconds: 0, calls: 0)].seconds += length(r)
                tags[t]!.calls += 1
            }
            if let k = r.kind {
                kinds[k, default: Slice(name: k, seconds: 0, calls: 0)].seconds += length(r)
                kinds[k]!.calls += 1
            }
        }
        talkShare = speech > 0 ? mine / speech : nil
        var sortedPeople = people.values.sorted { ($0.seconds, $1.name) > ($1.seconds, $0.name) }
        self.platforms = platforms.values.sorted { $0.seconds > $1.seconds }
        self.kinds = kinds.values.sorted { $0.seconds > $1.seconds }
        self.tags = tags.values.sorted { ($0.seconds, $1.name) > ($1.seconds, $0.name) }

        // Buckets across the whole period, empty ones included, so the chart's time axis is even.
        let component: Calendar.Component = switch bucket { case .day: .day; case .week: .weekOfYear; case .month: .month }
        func bucketStart(_ d: Date) -> Date { calendar.dateInterval(of: component, for: d)?.start ?? d }
        var bars: [Date: Bar] = [:]
        var cursor = bucketStart(interval.start)
        while cursor < interval.end {
            bars[cursor] = Bar(date: cursor)
            cursor = calendar.date(byAdding: component, value: 1, to: cursor)!
        }
        var heat: [HeatCell] = []
        var heatIndex: [Int: Int] = [:]
        for r in records {
            bars[bucketStart(r.start), default: Bar(date: bucketStart(r.start))].seconds += length(r)
            bars[bucketStart(r.start)]!.calls += 1
            if r.calendarTitle != nil { bars[bucketStart(r.start)]!.scheduledCalls += 1 }
            // Spread the call over the hours it covers.
            var t = r.start
            while t < r.end {
                let hourEnd = calendar.dateInterval(of: .hour, for: t)!.end
                let slice = min(hourEnd, r.end).timeIntervalSince(t)
                let key = calendar.component(.weekday, from: t) * 100 + calendar.component(.hour, from: t)
                if let i = heatIndex[key] { heat[i].seconds += slice } else {
                    heatIndex[key] = heat.count
                    heat.append(HeatCell(weekday: key / 100, hour: key % 100, seconds: slice))
                }
                t = hourEnd
            }
        }
        self.heat = heat

        let starts = Dictionary(records.map { ($0.id, $0.start) }, uniquingKeysWith: { a, _ in a })
        let events = usage.filter { interval.contains($0.date) } + Pricing.estimates(for: records, logged: usage)
        var cost = Cost()
        var estimated = 0.0
        for e in events {
            let c = Pricing.cost(e)
            cost.total += c
            cost.byService[e.service, default: 0] += c
            cost.byPurpose[e.purpose, default: 0] += c
            if e.estimated { estimated += c }
            // Charge a call's processing to the bucket of the call, so cost lines up with the time bars.
            let when = e.callID.flatMap { starts[$0] } ?? e.date
            bars[bucketStart(when), default: Bar(date: bucketStart(when))].cost[e.service, default: 0] += c
        }
        cost.estimatedShare = cost.total > 0 ? estimated / cost.total : 0
        cost.perCall = records.isEmpty ? 0 : cost.total / Double(records.count)
        cost.perCallHour = callSeconds > 0 ? cost.total / (callSeconds / 3600) : 0
        self.cost = cost
        self.days = bars.values.sorted { $0.date < $1.date }
        let index = Dictionary(uniqueKeysWithValues: days.enumerated().map { ($1.date, $0) })
        for i in sortedPeople.indices {
            var trend = [Int](repeating: 0, count: days.count)
            for r in records where r.speakerNames.values.contains(sortedPeople[i].name) {
                if let b = index[bucketStart(r.start)] { trend[b] += 1 }
            }
            sortedPeople[i].trend = trend
        }
        self.people = sortedPeople
        workday = Self.workday(records, interval: interval, calendar: calendar)
        communication = Self.communication(records, owner: owner, callSeconds: callSeconds)
        outcomes = Self.outcomes(records, owner: owner, callSeconds: callSeconds, commitments: commitments, interval: interval)

        var valueSeconds: [MeetingValue.Rating: TimeInterval] = [:]
        var lows: [String: Slice] = [:]
        for r in records {
            guard let rating = reviews[r.id]?.value?.rating else { continue }
            valueSeconds[rating, default: 0] += length(r)
            if rating == .low {
                lows[r.title.lowercased(), default: Slice(name: r.title, seconds: 0, calls: 0)].seconds += length(r)
                lows[r.title.lowercased()]!.calls += 1
            }
        }
        self.valueSeconds = valueSeconds
        lowValueRepeats = lows.values.filter { $0.calls > 1 }.sorted { $0.seconds > $1.seconds }

        delivery = records.compactMap { r in
            reviews[r.id]?.delivery.map {
                DeliveryPoint(callID: r.id, date: r.start, wordsPerMinute: $0.wordsPerMinute, fillersPerMinute: $0.fillersPerMinute, talkShare: $0.talkShare)
            }
        }
    }
}
