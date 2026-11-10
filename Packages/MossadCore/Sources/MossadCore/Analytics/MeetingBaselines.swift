import Foundation

extension MeetingAnalytics {
    /// What is normal for one number, from its history.
    public struct Usual: Sendable, Equatable {
        /// The range of the history: its lowest and highest value up to `percentileSamples` values, then its 10th
        /// and 90th percentile.
        public var low: Double
        public var high: Double
        public var median: Double
        /// How far the history spreads around its median: the larger of the scaled median absolute deviation and
        /// the standard deviation.
        public var spread: Double
        public var samples: Int

        /// Fewer earlier meetings than this give no range at all.
        public static let minimumSamples = 3
        /// Fewer than this give a range, but no judgment: three meetings do not say what is usual.
        public static let firmSamples = 5
        static let percentileSamples = 10

        /// True when the history is long enough to call a value usual or not.
        public var isFirm: Bool { samples >= Self.firmSamples }

        public init?(_ history: [Double]) {
            guard history.count >= Self.minimumSamples else { return nil }
            let sorted = history.sorted()
            func percentile(_ values: [Double], _ p: Double) -> Double {
                let at = p * Double(values.count - 1)
                let below = Int(at.rounded(.down)), above = min(values.count - 1, below + 1)
                return values[below] + (values[above] - values[below]) * (at - Double(below))
            }
            let n = Double(sorted.count)
            let middle = percentile(sorted, 0.5)
            median = middle
            low = sorted.count < Self.percentileSamples ? sorted[0] : percentile(sorted, 0.1)
            high = sorted.count < Self.percentileSamples ? sorted[sorted.count - 1] : percentile(sorted, 0.9)
            let deviation = percentile(sorted.map { abs($0 - middle) }.sorted(), 0.5) * 1.4826
            let mean = sorted.reduce(0, +) / n
            let standard = (sorted.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / (n - 1)).squareRoot()
            spread = max(deviation, standard)
            samples = sorted.count
        }

        /// The 97.5% point of Student's t for the history's size over the normal one: a short history knows its
        /// own spread badly, so a value must be further out before it counts.
        var smallSample: Double {
            let table: [(df: Int, t: Double)] = [(4, 2.776), (5, 2.571), (6, 2.447), (7, 2.365), (8, 2.306), (9, 2.262), (10, 2.228), (12, 2.179),
                                                 (15, 2.131), (20, 2.086), (25, 2.060), (30, 2.042), (60, 2.000)]
            let t = table.last { $0.df <= samples - 1 }?.t ?? 3.182
            return t / 1.96 * (1 + 1 / Double(samples)).squareRoot()
        }

        /// How far `value` is from the median, in spreads. `floor` is half the least difference that matters for
        /// the metric, so a history of equal values does not make every other value infinitely far.
        func score(_ value: Double, floor: Double) -> Double {
            abs(value - median) / (max(spread, floor) * smallSample)
        }
    }

    public enum Standing: Sendable, Equatable { case below, usual, above }

    /// One number of this call next to what is usual for it.
    public struct Reading: Sendable, Equatable {
        public var value: Double
        /// Nil with fewer than `Usual.minimumSamples` earlier values.
        public var usual: Usual?
        /// Nil when there is no judgment: no range, or a range from fewer than `Usual.firmSamples` values.
        public var standing: Standing?
        /// How far from the median, in spreads; 0 unless the value stood out. The tab ranks by it.
        public var score: Double

        /// A value stands out only at this score or more.
        public static let minimumScore = 2.5

        /// A value stands out when the history is firm and all of these hold: it is outside the range, it is at
        /// least `margin` from the median, and its score is at least `minimumScore`.
        init(value: Double, history: [Double], margin: Double) {
            self.value = value
            usual = Usual(history)
            score = 0
            guard let usual, usual.isFirm else { standing = nil; return }
            let outside = value > usual.high || value < usual.low
            let found = usual.score(value, floor: margin / 2)
            guard outside, abs(value - usual.median) >= margin, found >= Self.minimumScore else { standing = .usual; return }
            standing = value > usual.median ? .above : .below
            score = found
        }

        public var stoodOut: Bool { standing == .above || standing == .below }
    }

    /// The earlier meetings a baseline comes from, most alike first.
    public struct Context: Sendable, Equatable {
        public enum Kind: Sendable, Equatable {
            /// Earlier meetings with the same title.
            case series
            /// The 1:1s with the same other person.
            case oneOnOne
            /// All of the owner's 1:1s, with anyone.
            case ownOneOnOnes
            /// Meetings of the same size, and of the same kind or topics when enough are.
            case setting
            /// Every meeting with the person, of any size.
            case person
            /// The owner's last meetings, of any size.
            case recent

            /// False for the contexts that mix meetings of all sizes. A talk share, a number of people, and
            /// cut-ins follow the size, so those contexts do not compare them.
            var hasOneSize: Bool { self != .person && self != .recent }
        }

        public var kind: Kind
        public var meetings: Int
        /// As it reads after a number: "in Weekly sync", "in your 1:1s with Sam", "in all 14 meetings with you".
        public var label: String
    }

    public struct PersonBaseline: Sendable, Equatable, Identifiable {
        /// The speaker's `id`.
        public var id: String
        /// Nil when no context has `Usual.minimumSamples` earlier meetings: not enough history yet.
        public var context: Context?
        public var readings: [PersonMetric: Reading]
        /// Their talk share in the context's last meetings, oldest first, with this call last. Empty with fewer
        /// than `Trends.minimumPoints` points, or in a context of mixed sizes.
        public var shareTrend: [Double]

        public subscript(_ metric: PersonMetric) -> Reading? { readings[metric] }
    }

    /// The owner's talk share in this call against their share in earlier meetings of this size with one other person.
    public struct OwnerWith: Sendable, Equatable, Identifiable {
        /// The other person's speaker `id`.
        public var id: String
        public var context: Context
        public var reading: Reading
    }

    public struct MeetingBaseline: Sendable, Equatable {
        public var context: Context?
        public var readings: [MeetingMetric: Reading]

        public subscript(_ metric: MeetingMetric) -> Reading? { readings[metric] }
    }

    /// The recording against the calendar invite. The recording begins when the owner joins and ends when the
    /// owner leaves, so these say when the owner was there, not when the meeting began.
    public struct Schedule: Sendable, Equatable {
        public var plannedStart: Date
        public var plannedEnd: Date
        /// Positive when the recording began after the planned start.
        public var startDelay: TimeInterval
        /// Positive when the recording ended after the planned end.
        public var overrun: TimeInterval
        public var plannedLength: TimeInterval { max(0, plannedEnd.timeIntervalSince(plannedStart)) }

        /// A minute or two is not late, and not over.
        public static let lateStart: TimeInterval = 5 * 60
        public static let longOverrun: TimeInterval = 5 * 60
        public var joinedLate: Bool { startDelay >= Self.lateStart }
        public var ranOver: Bool { overrun >= Self.longOverrun }
    }

    public struct TrendPoint: Sendable, Equatable, Identifiable {
        /// The meeting's id.
        public var id: String
        public var date: Date
        public var value: Double
    }

    /// The last meetings of the series, or with the one other person, oldest first with this call last. A line
    /// with fewer than `minimumPoints` points is empty. A meeting with no value for a line has no point on it.
    public struct Trends: Sendable, Equatable {
        public var context: Context
        /// The owner's part of the talk, 0 to 1.
        public var talkShare: [TrendPoint]
        /// The coach's rating as 1, 2, or 3, for the meetings that have one.
        public var value: [TrendPoint]
        public var length: [TrendPoint]

        public static let minimumPoints = 3
        static let earlier = 11
        public var isEmpty: Bool { talkShare.isEmpty && value.isEmpty && length.isEmpty }
    }

    /// Where a number that stood out can be checked.
    public enum Evidence: Sendable, Equatable {
        /// A second of the call to play from.
        case moment(TimeInterval)
        /// A speaker's `id`: their profile.
        case person(String)
    }

    /// One thing about this call that is not like the owner's other meetings.
    public struct Standout: Sendable, Equatable, Identifiable {
        public var id: String
        /// The `id` of the speaker it is about; nil when it is about the meeting.
        public var subject: String?
        /// The whole sentence without a subject; with one, what follows the name.
        public var text: String
        public var evidence: Evidence?
        public var score: Double
    }

    public struct Baselines: Sendable, Equatable {
        /// How many earlier meetings there are to compare with, in any context.
        public var earlier: Int
        /// One per named speaker, in the speakers' order.
        public var people: [PersonBaseline]
        /// For a group: one per other named person with enough meetings of this size together.
        public var ownerWith: [OwnerWith]
        public var meeting: MeetingBaseline
        /// Nil for a call with no calendar invite, or an invite from before the planned times were saved.
        public var schedule: Schedule?
        public var trends: Trends?
        /// The numbers that passed the test of `Reading`, the furthest first. Empty for an ordinary call.
        public var standouts: [Standout]

        public func person(_ id: String) -> PersonBaseline? { people.first { $0.id == id } }
        /// True when at least one number has a range to stand against.
        public var hasHistory: Bool { meeting.context != nil || people.contains { $0.context != nil } }
        /// True when at least one number has a history long enough to be judged.
        public var hasFirmHistory: Bool {
            meeting.readings.values.contains { $0.standing != nil } || people.contains { $0.readings.values.contains { $0.standing != nil } }
        }

        static let maximumStandouts = 5
        /// At most this many about one person, so one loud voice does not fill the list. A 1:1 has two people
        /// to share five lines, so each may have three.
        static let standoutsPerSubject = 2
        static let standoutsPerSubjectOfTwo = 3
    }
}

// MARK: Margins

extension PersonMetric {
    /// The least difference from the median that matters for this number.
    func margin(_ u: MeetingAnalytics.Usual) -> Double {
        switch self {
        case .talkShare: 0.08
        case .wordsPerMinute: 20
        case .fillersPerMinute: 1
        case .questionsPerHour: 3
        case .averageTurn: max(8, u.median * 0.25)
        case .longestTurn: max(20, u.median * 0.25)
        case .cutInsPerHour, .cutOffsPerHour: 2
        case .responseGap: 0.7
        }
    }

    /// True for a number that follows how many people are in the meeting.
    var followsSize: Bool { self == .talkShare || self == .cutInsPerHour || self == .cutOffsPerHour }
}

extension MeetingMetric {
    func margin(_ u: MeetingAnalytics.Usual) -> Double {
        switch self {
        case .length: max(300, u.median * 0.15)
        case .voices, .decisions, .actionItems: 2
        case .screens: 3
        case .silenceShare: 0.08
        case .wordsPerMinute: 20
        case .value: 1
        }
    }
}

extension MeetingAnalytics.Reading {
    init(value: Double, history: [Double], metric: PersonMetric) {
        self.init(value: value, history: history, margin: MeetingAnalytics.Usual(history).map(metric.margin) ?? 0)
    }

    init(value: Double, history: [Double], metric: MeetingMetric) {
        self.init(value: value, history: history, margin: MeetingAnalytics.Usual(history).map(metric.margin) ?? 0)
    }
}

// MARK: Contexts

extension MeetingAnalytics {
    /// The earlier meetings, and the rules for which of them a number is compared with.
    struct History {
        let this: MeetingFacts
        /// Newest first.
        let before: [MeetingFacts]

        /// A context uses its most recent meetings: what was normal two years ago is not what is normal now.
        static let limit = 30
        static let recent = 20
        static let ownerLimit = 50

        /// One earlier meeting of a person's context, with the row to read the person's numbers from.
        typealias Row = (meeting: MeetingFacts, person: MeetingFacts.Person)

        init(this: MeetingFacts, history: [MeetingFacts]) {
            self.this = this
            before = history.filter { $0.id != this.id && $0.start < this.start }.sorted { $0.start > $1.start }
        }

        private static func enough<T>(_ rows: [T]) -> Bool { rows.count >= Usual.minimumSamples }
        private static func first(_ name: String) -> String { name.split(separator: " ").first.map(String.init) ?? name }

        private func context<T>(_ kind: Context.Kind, _ rows: [T], _ label: String, limit: Int = limit) -> (Context, [T]) {
            let used = Array(rows.prefix(limit))
            return (Context(kind: kind, meetings: used.count, label: label), used)
        }

        private func rows(_ meetings: [MeetingFacts], of name: String) -> [Row] {
            meetings.compactMap { m in m.person(name).map { (m, $0) } }
        }

        /// Earlier meetings with this call's title. For a 1:1, only the ones that were a 1:1 too.
        private var seriesMeetings: [MeetingFacts] {
            guard let series = this.series else { return [] }
            return before.filter { $0.series == series && (this.partner == nil || $0.partner != nil) }
        }

        /// The 1:1s with this call's other person; empty when this call is not a 1:1.
        private var oneOnOnes: [MeetingFacts] {
            this.partner.map { p in before.filter { $0.partner?.name == p.name } } ?? []
        }

        /// All of the owner's 1:1s, with anyone.
        private var ownOneOnOnes: [MeetingFacts] { before.filter { $0.partner != nil } }

        /// "monthly update" for "Monthly update", so it reads inside a sentence; "QBR" stays.
        private static func inSentence(_ kind: String) -> String {
            let second = kind.dropFirst().first
            return second?.isLowercase == true ? kind.prefix(1).lowercased() + kind.dropFirst() : kind
        }

        /// Meetings of this call's size among `meetings`, narrowed by its kind or its topics when enough of them
        /// share one.
        private func setting(_ meetings: [MeetingFacts]) -> (meetings: [MeetingFacts], label: String)? {
            let sized = meetings.filter { $0.size == this.size && $0.partner == nil }
            if let kind = this.kind?.nonBlank {
                let same = sized.filter { $0.kind?.caseInsensitiveCompare(kind) == .orderedSame }
                if Self.enough(same) { return (same, "in \(Self.inSentence(kind)) meetings of \(this.size.words)") }
            }
            let topics = Set(this.tags.map { $0.lowercased() })
            if !topics.isEmpty {
                let same = sized.filter { !topics.isDisjoint(with: $0.tags.map { $0.lowercased() }) }
                if Self.enough(same) {
                    // Name the topics the earlier meetings share with this one, as this call writes them.
                    let shared = this.tags.filter { tag in same.contains { $0.tags.contains { $0.caseInsensitiveCompare(tag) == .orderedSame } } }
                    let named = shared.prefix(2).joined(separator: " or ")
                    return (same, "in meetings of \(this.size.words) about \(named)")
                }
            }
            return Self.enough(sized) ? (sized, "in meetings of \(this.size.words)") : nil
        }

        /// The context for one person's numbers.
        ///
        /// A group: the series, then meetings of this size (and kind or topics), then every meeting with the person.
        /// A 1:1: the series, then the 1:1s with this person, then all of the owner's 1:1s (the owner against
        /// their own 1:1s, the other person against the other people of those 1:1s), then every meeting with
        /// this person. A 1:1 is never compared with groups while there are 1:1s to compare with.
        func context(for person: MeetingFacts.Person) -> (Context, [Row])? {
            let series = rows(seriesMeetings, of: person.name)
            if Self.enough(series) { return context(.series, series, "in \(this.title)") }
            if let partner = this.partner {
                let together = rows(oneOnOnes, of: person.name)
                if Self.enough(together) {
                    return context(.oneOnOne, together, person.isOwner ? "in your 1:1s with \(Self.first(partner.name))" : "in 1:1s with you")
                }
                // The role, not the person: you in your 1:1s, and whoever sat across from you.
                let own: [Row] = ownOneOnOnes.compactMap { m in (person.isOwner ? m.owner : m.partner).map { (m, $0) } }
                if Self.enough(own) {
                    return context(.ownOneOnOnes, own, person.isOwner ? "in your 1:1s" : "for the other person in your 1:1s")
                }
                let with = rows(before.filter { $0.person(partner.name) != nil }, of: person.name)
                guard Self.enough(with) else { return nil }
                return context(.person, with, person.isOwner ? "in all \(with.count) meetings with \(Self.first(partner.name))" : "in all \(with.count) meetings with you",
                               limit: .max)
            }
            let with = before.filter { $0.person(person.name) != nil }
            if let s = setting(with) { return context(.setting, rows(s.meetings, of: person.name), s.label) }
            guard Self.enough(with) else { return nil }
            if person.isOwner {
                return context(.person, rows(with, of: person.name),
                               with.count > Self.ownerLimit ? "in your last \(Self.ownerLimit) meetings" : "in all \(with.count) of your meetings", limit: Self.ownerLimit)
            }
            return context(.person, rows(with, of: person.name), "in all \(with.count) meetings with you", limit: .max)
        }

        /// The context for the owner's talk share next to one other person of a group: meetings of this size
        /// with them. Meetings of other sizes say nothing about a share.
        func context(ownerWith other: MeetingFacts.Person) -> (Context, [MeetingFacts])? {
            guard let s = setting(before.filter { $0.person(other.name) != nil && $0.owner != nil }) else { return nil }
            return context(.setting, s.meetings, "\(s.label) with \(Self.first(other.name))")
        }

        /// The context for the meeting's own numbers, in the same order as a person's.
        func meetingContext() -> (Context, [MeetingFacts])? {
            if Self.enough(seriesMeetings) { return context(.series, seriesMeetings, "in \(this.title)") }
            if let partner = this.partner {
                if Self.enough(oneOnOnes) { return context(.oneOnOne, oneOnOnes, "in your 1:1s with \(Self.first(partner.name))") }
                if Self.enough(ownOneOnOnes) { return context(.ownOneOnOnes, ownOneOnOnes, "in your 1:1s") }
                let with = before.filter { $0.person(partner.name) != nil }
                return Self.enough(with) ? context(.person, with, "in all \(with.count) meetings with \(Self.first(partner.name))", limit: .max) : nil
            }
            if let s = setting(before) { return context(.setting, s.meetings, s.label) }
            let recent = Array(before.prefix(Self.recent))
            return Self.enough(recent) ? context(.recent, recent, "in your last \(recent.count) meetings") : nil
        }

        /// The series, else the 1:1s with the other person; a trend needs no minimum of its own beyond its points.
        func trendContext() -> (Context, [MeetingFacts])? {
            if seriesMeetings.count >= Trends.minimumPoints - 1 { return context(.series, seriesMeetings, "in \(this.title)", limit: Trends.earlier) }
            if let partner = this.partner, oneOnOnes.count >= Trends.minimumPoints - 1 {
                return context(.oneOnOne, oneOnOnes, "in your 1:1s with \(Self.first(partner.name))", limit: Trends.earlier)
            }
            return nil
        }
    }
}

// MARK: Building

extension MeetingAnalytics.Baselines {
    typealias A = MeetingAnalytics

    init(_ this: MeetingFacts, speakers: [A.Speaker], flow: A.Flow?, record r: CallRecord, history: [MeetingFacts],
         value: (String) -> MeetingValue.Rating?) {
        let past = A.History(this: this, history: history)
        earlier = past.before.count

        // People.
        var people: [A.PersonBaseline] = []
        for s in speakers where !s.isUnknown {
            guard let person = this.person(s.name) else { continue }
            guard let (context, rows) = past.context(for: person) else {
                people.append(A.PersonBaseline(id: s.id, context: nil, readings: [:], shareTrend: []))
                continue
            }
            var readings: [PersonMetric: A.Reading] = [:]
            for metric in PersonMetric.allCases where context.kind.hasOneSize || !metric.followsSize {
                guard let now = person.values[metric] else { continue }
                readings[metric] = A.Reading(value: now, history: rows.compactMap { $0.person.values[metric] }, metric: metric)
            }
            var trend: [Double] = []
            // Not for the other people of the owner's 1:1s: their shares are not this person's history.
            if context.kind.hasOneSize, context.kind != .ownOneOnOnes || s.isOwner {
                trend = rows.prefix(A.Trends.earlier).reversed().compactMap { $0.person.values[.talkShare] } + [s.share]
                if trend.count < A.Trends.minimumPoints { trend = [] }
            }
            people.append(A.PersonBaseline(id: s.id, context: context, readings: readings, shareTrend: trend))
        }
        self.people = people

        // The owner next to each other person of a group.
        var ownerWith: [A.OwnerWith] = []
        if let owner = this.owner, let share = owner.values[.talkShare], this.partner == nil {
            for s in speakers where !s.isUnknown && !s.isOwner {
                guard let other = this.person(s.name), let (context, meetings) = past.context(ownerWith: other) else { continue }
                let reading = A.Reading(value: share, history: meetings.compactMap { $0.owner?.values[.talkShare] }, metric: .talkShare)
                if reading.usual != nil { ownerWith.append(A.OwnerWith(id: s.id, context: context, reading: reading)) }
            }
        }
        self.ownerWith = ownerWith

        // The meeting. Only the series can say how many people is usual: every other context either has this
        // call's size by its definition, or mixes all sizes.
        var meeting = A.MeetingBaseline(context: nil, readings: [:])
        if let (context, meetings) = past.meetingContext() {
            meeting.context = context
            for metric in MeetingMetric.allCases where metric != .voices || context.kind == .series {
                guard let now = this.values[metric] else { continue }
                let history = metric == .value ? meetings.compactMap { value($0.id).map { Double($0.level) } } : meetings.compactMap { $0.values[metric] }
                meeting.readings[metric] = A.Reading(value: now, history: history, metric: metric)
            }
        }
        self.meeting = meeting

        if let plannedStart = r.plannedStart, let plannedEnd = r.plannedEnd, plannedEnd > plannedStart {
            schedule = A.Schedule(plannedStart: plannedStart, plannedEnd: plannedEnd, startDelay: r.start.timeIntervalSince(plannedStart),
                                  overrun: r.end.timeIntervalSince(plannedEnd))
        } else {
            schedule = nil
        }

        // Trends. A meeting with no value for a line has no point on it: no owner's voice is not "0%".
        if let (context, meetings) = past.trendContext() {
            let oldestFirst = Array(meetings.reversed())
            func line(_ of: (MeetingFacts) -> Double?, this now: Double?) -> [A.TrendPoint] {
                guard let now else { return [] }
                let points = oldestFirst.compactMap { m in of(m).map { A.TrendPoint(id: m.id, date: m.start, value: $0) } }
                    + [A.TrendPoint(id: this.id, date: this.start, value: now)]
                return points.count >= A.Trends.minimumPoints ? points : []
            }
            let trends = A.Trends(context: context,
                                  talkShare: line({ $0.owner?.values[.talkShare] }, this: this.owner?.values[.talkShare]),
                                  value: line({ value($0.id).map { Double($0.level) } }, this: this.values[.value]),
                                  length: line({ $0.values[.length] }, this: this.values[.length]))
            self.trends = trends.isEmpty ? nil : trends
        } else {
            trends = nil
        }

        standouts = Self.standouts(this, speakers: speakers, flow: flow, record: r, people: people, ownerWith: ownerWith, meeting: meeting,
                                   schedule: schedule)
    }

    /// The numbers that stood out (see `Reading`), the furthest first; at most two about one person (three in a
    /// 1:1), and five in all. In a 1:1 a fact about the pair is said one time: the owner's talk share stands for
    /// the other person's, and who cut in stands for who was cut off.
    static func standouts(_ this: MeetingFacts, speakers: [A.Speaker], flow: A.Flow?, record r: CallRecord, people: [A.PersonBaseline],
                          ownerWith: [A.OwnerWith], meeting: A.MeetingBaseline, schedule: A.Schedule?) -> [A.Standout] {
        var all: [A.Standout] = []
        let oneOnOne = this.partner != nil
        func other(of s: A.Speaker) -> A.PersonBaseline? {
            people.first { q in q.id != s.id && speakers.contains { $0.id == q.id && !$0.isUnknown } }
        }
        for p in people {
            guard let s = speakers.first(where: { $0.id == p.id }), let context = p.context else { continue }
            for (metric, reading) in p.readings where reading.stoodOut {
                if oneOnOne {
                    // One person's share is the rest of the other's: say it about the owner.
                    if metric == .talkShare, !s.isOwner, other(of: s)?.readings[.talkShare]?.stoodOut == true { continue }
                    // Each time one was cut off, the other cut in: say who cut in.
                    if metric == .cutOffsPerHour, other(of: s)?.readings[.cutInsPerHour]?.stoodOut == true { continue }
                }
                all.append(A.Standout(id: "\(p.id).\(metric.rawValue)", subject: p.id,
                                      text: MeetingFindings.sentence(metric, reading, count: count(metric, s), you: s.isOwner, context: context),
                                      evidence: evidence(metric, s, flow), score: reading.score))
            }
        }
        if let owner = speakers.first(where: \.isOwner) {
            for w in ownerWith where w.reading.stoodOut {
                guard let usual = w.reading.usual else { continue }
                all.append(A.Standout(id: "with.\(w.id)", subject: owner.id,
                                      text: "talked \(MeetingFindings.percent(w.reading.value)) of the time; "
                                        + "usually \(MeetingFindings.range(.talkShare, usual)) \(w.context.label)",
                                      evidence: .person(w.id), score: w.reading.score))
            }
        }
        if let context = meeting.context {
            for (metric, reading) in meeting.readings where reading.stoodOut {
                let moment: TimeInterval? = switch metric {
                case .decisions: r.decisions.compactMap(\.at).min()
                case .screens: r.screens?.map(\.offset).min()
                case .silenceShare: flow?.longestSilence?.start
                case .length: schedule.flatMap { $0.ranOver ? $0.plannedEnd.timeIntervalSince(r.start) : nil }
                default: nil
                }
                all.append(A.Standout(id: "meeting.\(metric.rawValue)", subject: nil, text: MeetingFindings.sentence(metric, reading, context: context),
                                      evidence: moment.flatMap { $0 >= 0 ? .moment($0) : nil }, score: reading.score))
            }
        }
        var perSubject: [String: Int] = [:]
        var out: [A.Standout] = []
        for s in onePerCause(all).sorted(by: { ($0.score, $1.id) > ($1.score, $0.id) }) {
            let subject = s.subject ?? ""
            guard perSubject[subject, default: 0] < (oneOnOne ? standoutsPerSubjectOfTwo : standoutsPerSubject) || s.subject == nil else { continue }
            perSubject[subject, default: 0] += 1
            out.append(s)
            if out.count == maximumStandouts { break }
        }
        return out
    }

    /// One line for each cause: a person's typical and longest turn tell of the same turns, and the owner's talk
    /// share tells of their share with each person. Of related lines the strongest stays, in the order given.
    static func onePerCause(_ list: [A.Standout]) -> [A.Standout] {
        func cause(_ s: A.Standout) -> String {
            let subject = s.subject ?? ""
            if s.id.hasSuffix(".averageTurn") || s.id.hasSuffix(".longestTurn") { return "\(subject).turns" }
            if s.id.hasSuffix(".talkShare") || s.id.hasPrefix("with.") { return "\(subject).share" }
            return s.id
        }
        var best: [String: A.Standout] = [:]
        for s in list where best[cause(s)].map({ s.score > $0.score }) ?? true { best[cause(s)] = s }
        return list.filter { best[cause($0)]?.id == $0.id }
    }

    /// The count in this call behind a number that the history holds per hour.
    private static func count(_ metric: PersonMetric, _ s: A.Speaker) -> Int? {
        switch metric {
        case .questionsPerHour: s.questions
        case .cutInsPerHour: s.interruptionsMade
        case .cutOffsPerHour: s.interruptionsReceived
        default: nil
        }
    }

    /// The moment that shows a number, or the person it is about.
    private static func evidence(_ metric: PersonMetric, _ s: A.Speaker, _ flow: A.Flow?) -> A.Evidence {
        let moment: TimeInterval? = switch metric {
        case .longestTurn, .averageTurn: s.longestTurn?.start
        case .questionsPerHour: s.firstQuestion
        case .cutInsPerHour: flow?.interruptions.filter { $0.by == s.id }.flatMap(\.moments).min()
        case .cutOffsPerHour: flow?.interruptions.filter { $0.of == s.id }.flatMap(\.moments).min()
        default: nil
        }
        return moment.map { .moment($0) } ?? .person(s.id)
    }
}
