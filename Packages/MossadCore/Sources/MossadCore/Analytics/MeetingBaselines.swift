import Foundation

extension MeetingAnalytics {
    /// What is normal for one number: the middle of its history. A value inside `low...high` is usual.
    public struct Usual: Sendable, Equatable {
        /// The 20th and the 80th percentile of the history.
        public var low: Double
        public var high: Double
        public var median: Double
        public var samples: Int

        /// Fewer earlier meetings than this say nothing about what is normal.
        public static let minimumSamples = 3

        public init?(_ history: [Double]) {
            guard history.count >= Self.minimumSamples else { return nil }
            let sorted = history.sorted()
            func percentile(_ p: Double) -> Double {
                let at = p * Double(sorted.count - 1)
                let below = Int(at.rounded(.down)), above = min(sorted.count - 1, below + 1)
                return sorted[below] + (sorted[above] - sorted[below]) * (at - Double(below))
            }
            low = percentile(0.2)
            high = percentile(0.8)
            median = percentile(0.5)
            samples = sorted.count
        }
    }

    public enum Standing: Sendable, Equatable { case below, usual, above }

    /// One number of this call next to what is usual for it.
    public struct Reading: Sendable, Equatable {
        public var value: Double
        /// Nil with too little history.
        public var usual: Usual?
        /// Nil when `usual` is. Outside the usual range by a margin that matters, or usual.
        public var standing: Standing?
        /// How far outside the range, in widths of the range; 0 when usual. The tab ranks by it.
        public var score: Double

        /// `margin` is how far outside the range a value must be before it stands out, so 41% against a usual
        /// "30 to 40%" stays quiet.
        init(value: Double, history: [Double], margin: (Usual) -> Double) {
            self.value = value
            usual = Usual(history)
            guard let usual else { standing = nil; score = 0; return }
            let least = margin(usual)
            let outside = value > usual.high ? value - usual.high : value < usual.low ? usual.low - value : 0
            guard outside >= least, outside > 0 else { standing = .usual; score = 0; return }
            standing = value > usual.high ? .above : .below
            score = outside / max(usual.high - usual.low, least)
        }

        public var stoodOut: Bool { standing == .above || standing == .below }
    }

    /// The earlier meetings a baseline comes from, most alike first: the same series, then the same setting
    /// (the 1:1s with that person, or meetings of a similar size and kind), then every meeting with the person.
    public struct Context: Sendable, Equatable {
        public enum Kind: Sendable, Equatable { case series, oneOnOne, setting, person, recent }

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
        /// Their talk share in the context's last meetings, oldest first, with this call last. Empty with no context.
        public var shareTrend: [Double]

        public subscript(_ metric: PersonMetric) -> Reading? { readings[metric] }
    }

    /// The owner's talk share in this call against their share in earlier meetings with one other person.
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

    /// The call against its calendar invite.
    public struct Schedule: Sendable, Equatable {
        public var plannedStart: Date
        public var plannedEnd: Date
        /// Positive when the recording began after the planned start.
        public var startDelay: TimeInterval
        /// Positive when the call ended after the planned end.
        public var overrun: TimeInterval
        public var plannedLength: TimeInterval { max(0, plannedEnd.timeIntervalSince(plannedStart)) }

        /// A minute or two is not late, and not over.
        public static let lateStart: TimeInterval = 5 * 60
        public static let longOverrun: TimeInterval = 5 * 60
        public var startedLate: Bool { startDelay >= Self.lateStart }
        public var ranOver: Bool { overrun >= Self.longOverrun }
    }

    public struct TrendPoint: Sendable, Equatable, Identifiable {
        /// The meeting's id.
        public var id: String
        public var date: Date
        public var value: Double
    }

    /// The last meetings of the series, or with the one other person, oldest first with this call last. A line
    /// with fewer than `minimumPoints` points is empty.
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
        /// For a meeting with more than one other named person.
        public var ownerWith: [OwnerWith]
        public var meeting: MeetingBaseline
        /// Nil for a call with no calendar invite, or an invite from before the planned times were saved.
        public var schedule: Schedule?
        public var trends: Trends?
        /// The few numbers furthest from usual, the furthest first.
        public var standouts: [Standout]

        public func person(_ id: String) -> PersonBaseline? { people.first { $0.id == id } }
        /// True when at least one number has a usual range to stand against.
        public var hasHistory: Bool { meeting.context != nil || people.contains { $0.context != nil } }

        static let maximumStandouts = 5
        /// At most this many about one person, so one loud voice does not fill the list. A 1:1 has two people
        /// to share five lines, so each may have three.
        static let standoutsPerSubject = 2
        static let standoutsPerSubjectOfTwo = 3
    }
}

// MARK: Margins

extension PersonMetric {
    /// How far outside the usual range this number must be to stand out.
    func margin(_ u: MeetingAnalytics.Usual) -> Double {
        switch self {
        case .talkShare: 0.05
        case .wordsPerMinute: 10
        case .fillersPerMinute: 0.5
        case .questionsPerHour: 2
        case .averageTurn: max(5, u.median * 0.2)
        case .longestTurn: max(15, u.median * 0.2)
        case .cutInsPerHour, .cutOffsPerHour: 1.5
        case .responseGap: 0.5
        }
    }
}

extension MeetingMetric {
    func margin(_ u: MeetingAnalytics.Usual) -> Double {
        switch self {
        case .length: max(300, u.median * 0.15)
        case .voices, .decisions, .actionItems: 2
        case .screens: 3
        case .silenceShare: 0.05
        case .wordsPerMinute: 10
        case .value: 1
        }
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

        init(this: MeetingFacts, history: [MeetingFacts]) {
            self.this = this
            before = history.filter { $0.id != this.id && $0.start < this.start }.sorted { $0.start > $1.start }
        }

        private static func enough(_ meetings: [MeetingFacts]) -> Bool { meetings.count >= Usual.minimumSamples }

        private func context(_ kind: Context.Kind, _ meetings: [MeetingFacts], _ label: String, limit: Int = limit) -> (Context, [MeetingFacts]) {
            let used = Array(meetings.prefix(limit))
            return (Context(kind: kind, meetings: used.count, label: label), used)
        }

        private var seriesMeetings: [MeetingFacts] {
            this.series.map { s in before.filter { $0.series == s } } ?? []
        }

        /// "monthly update" for "Monthly update", so it reads inside a sentence; "QBR" stays.
        private static func inSentence(_ kind: String) -> String {
            let second = kind.dropFirst().first
            return second?.isLowercase == true ? kind.prefix(1).lowercased() + kind.dropFirst() : kind
        }

        /// Meetings of this call's size among `meetings`, narrowed by its kind or its topics when enough of them
        /// share one.
        private func setting(_ meetings: [MeetingFacts]) -> (meetings: [MeetingFacts], label: String)? {
            let sized = meetings.filter { $0.size == this.size }
            if let kind = this.kind?.nonBlank {
                let same = sized.filter { $0.kind?.caseInsensitiveCompare(kind) == .orderedSame }
                if Self.enough(same) { return (same, "in \(Self.inSentence(kind)) meetings of \(this.size.words)") }
            }
            let topics = Set(this.tags.map { $0.lowercased() })
            if !topics.isEmpty {
                let same = sized.filter { !topics.isDisjoint(with: $0.tags.map { $0.lowercased() }) }
                if Self.enough(same) { return (same, "in meetings of \(this.size.words) on these topics") }
            }
            return Self.enough(sized) ? (sized, "in meetings of \(this.size.words)") : nil
        }

        /// The 1:1s with this call's other person; empty when this call is not a 1:1.
        private var oneOnOnes: [MeetingFacts] {
            this.partner.map { p in before.filter { $0.partner?.name == p.name } } ?? []
        }

        private static func first(_ name: String) -> String { name.split(separator: " ").first.map(String.init) ?? name }

        /// The context for one person's numbers.
        func context(for person: MeetingFacts.Person) -> (Context, [MeetingFacts])? {
            let with = before.filter { $0.person(person.name) != nil }
            let series = seriesMeetings.filter { $0.person(person.name) != nil }
            if Self.enough(series) { return context(.series, series, "in \(this.title)") }
            if let partner = this.partner {
                if Self.enough(oneOnOnes) {
                    return context(.oneOnOne, oneOnOnes, person.isOwner ? "in your 1:1s with \(Self.first(partner.name))" : "in 1:1s with you")
                }
            } else if let s = setting(with) {
                return context(.setting, s.meetings, s.label)
            }
            guard Self.enough(with) else { return nil }
            if person.isOwner {
                return context(.person, with, with.count > Self.ownerLimit ? "in your last \(Self.ownerLimit) meetings" : "in all \(with.count) of your meetings",
                               limit: Self.ownerLimit)
            }
            return context(.person, with, "in all \(with.count) meetings with you", limit: .max)
        }

        /// The context for the owner's talk share next to one other person: meetings of this size with them,
        /// then every meeting with them.
        func context(ownerWith other: MeetingFacts.Person) -> (Context, [MeetingFacts])? {
            let with = before.filter { $0.person(other.name) != nil && $0.owner != nil }
            let name = Self.first(other.name)
            if let s = setting(with) { return context(.setting, s.meetings, "\(s.label) with \(name)") }
            return Self.enough(with) ? context(.person, with, "in all \(with.count) meetings with \(name)", limit: .max) : nil
        }

        /// The context for the meeting's own numbers.
        func meetingContext() -> (Context, [MeetingFacts])? {
            if Self.enough(seriesMeetings) { return context(.series, seriesMeetings, "in \(this.title)") }
            if let partner = this.partner {
                if Self.enough(oneOnOnes) { return context(.oneOnOne, oneOnOnes, "in your 1:1s with \(Self.first(partner.name))") }
            } else if let s = setting(before) {
                return context(.setting, s.meetings, s.label)
            }
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
            guard let (context, meetings) = past.context(for: person) else {
                people.append(A.PersonBaseline(id: s.id, context: nil, readings: [:], shareTrend: []))
                continue
            }
            var readings: [PersonMetric: A.Reading] = [:]
            for metric in PersonMetric.allCases {
                guard let now = person.values[metric] else { continue }
                readings[metric] = A.Reading(value: now, history: meetings.compactMap { $0.person(s.name)?.values[metric] }, margin: metric.margin)
            }
            let trend = meetings.prefix(A.Trends.earlier).reversed().compactMap { $0.person(s.name)?.values[.talkShare] } + [s.share]
            people.append(A.PersonBaseline(id: s.id, context: context, readings: readings, shareTrend: trend))
        }
        self.people = people

        // The owner next to each other person, when there is more than one.
        var ownerWith: [A.OwnerWith] = []
        if let owner = this.owner, let share = owner.values[.talkShare], this.partner == nil {
            for s in speakers where !s.isUnknown && !s.isOwner {
                guard let other = this.person(s.name), let (context, meetings) = past.context(ownerWith: other) else { continue }
                let reading = A.Reading(value: share, history: meetings.compactMap { $0.owner?.values[.talkShare] }, margin: PersonMetric.talkShare.margin)
                if reading.usual != nil { ownerWith.append(A.OwnerWith(id: s.id, context: context, reading: reading)) }
            }
        }
        self.ownerWith = ownerWith

        // The meeting.
        var meeting = A.MeetingBaseline(context: nil, readings: [:])
        if let (context, meetings) = past.meetingContext() {
            meeting.context = context
            for metric in MeetingMetric.allCases {
                guard let now = this.values[metric] else { continue }
                let history = metric == .value ? meetings.compactMap { value($0.id).map { Double($0.level) } } : meetings.compactMap { $0.values[metric] }
                meeting.readings[metric] = A.Reading(value: now, history: history, margin: metric.margin)
            }
        }
        self.meeting = meeting

        if let plannedStart = r.plannedStart, let plannedEnd = r.plannedEnd, plannedEnd > plannedStart {
            schedule = A.Schedule(plannedStart: plannedStart, plannedEnd: plannedEnd, startDelay: r.start.timeIntervalSince(plannedStart),
                                  overrun: r.end.timeIntervalSince(plannedEnd))
        } else {
            schedule = nil
        }

        // Trends.
        if let (context, meetings) = past.trendContext() {
            let oldestFirst = Array(meetings.reversed())
            func line(_ of: (MeetingFacts) -> Double?, this now: Double?) -> [A.TrendPoint] {
                guard let now else { return [] }
                let points = oldestFirst.compactMap { m in of(m).map { A.TrendPoint(id: m.id, date: m.start, value: $0) } }
                    + [A.TrendPoint(id: this.id, date: this.start, value: now)]
                return points.count >= A.Trends.minimumPoints ? points : []
            }
            let trends = A.Trends(context: context,
                                  talkShare: line({ $0.owner?.values[.talkShare] ?? 0 }, this: this.owner?.values[.talkShare]),
                                  value: line({ value($0.id).map { Double($0.level) } }, this: this.values[.value]),
                                  length: line({ $0.values[.length] }, this: this.values[.length]))
            self.trends = trends.isEmpty ? nil : trends
        } else {
            trends = nil
        }

        standouts = Self.standouts(this, speakers: speakers, flow: flow, record: r, people: people, ownerWith: ownerWith, meeting: meeting,
                                   schedule: schedule)
    }

    /// Every number outside its usual range, the furthest first; at most two about one person (three in a 1:1),
    /// and five in all. In a 1:1 a fact about the pair is said one time: the owner's talk share stands for the
    /// other person's, and who cut in stands for who was cut off.
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
                                      text: MeetingFindings.sentence(metric, reading, you: s.isOwner, context: context),
                                      evidence: evidence(metric, s, flow), score: reading.score))
            }
        }
        if let owner = speakers.first(where: \.isOwner) {
            for w in ownerWith where w.reading.stoodOut {
                guard let other = speakers.first(where: { $0.id == w.id }), let usual = w.reading.usual else { continue }
                all.append(A.Standout(id: "with.\(w.id)", subject: owner.id,
                                      text: "talked \(MeetingFindings.percent(w.reading.value)) of the time with \(other.name); "
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
        if let schedule {
            if schedule.startedLate {
                all.append(A.Standout(id: "schedule.start", subject: nil, text: "Started \(MeetingFindings.span(schedule.startDelay)) late",
                                      evidence: nil, score: min(3, schedule.startDelay / A.Schedule.lateStart)))
            }
            // The meeting's length says it when the length itself stood out.
            if schedule.ranOver, meeting.readings[.length]?.standing != .above {
                let at = schedule.plannedEnd.timeIntervalSince(r.start)
                all.append(A.Standout(id: "schedule.end", subject: nil, text: "Ran \(MeetingFindings.span(schedule.overrun)) over the planned end",
                                      evidence: at >= 0 ? .moment(at) : nil, score: min(3, schedule.overrun / A.Schedule.longOverrun)))
            }
        }
        var perSubject: [String: Int] = [:]
        var out: [A.Standout] = []
        for s in all.sorted(by: { ($0.score, $1.id) > ($1.score, $0.id) }) {
            let subject = s.subject ?? ""
            guard perSubject[subject, default: 0] < (oneOnOne ? standoutsPerSubjectOfTwo : standoutsPerSubject) || s.subject == nil else { continue }
            perSubject[subject, default: 0] += 1
            out.append(s)
            if out.count == maximumStandouts { break }
        }
        return out
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
