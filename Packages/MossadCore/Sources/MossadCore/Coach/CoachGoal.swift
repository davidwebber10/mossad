import Foundation

/// What the app counts for a goal. In the file it is text (`CoachGoal.measureName`): a measure from a later build
/// is no measure here, and the memory still reads.
public enum GoalMeasure: String, Codable, Sendable, CaseIterable {
    /// The owner's share of the talk in their 1:1s: the number of "room in 1:1s". Lower leaves the other person
    /// more room.
    case oneOnOneTalkShare = "one_on_one_talk_share"

    var metric: PersonMetric { .talkShare }

    /// "Your talk share in 1:1s".
    public var title: String { "Your talk share in 1:1s" }
    /// Where the goal applies.
    public var context: String { "1:1s" }

    /// A meeting of the goal: a sure 1:1 by the size rule of the Meetings filter (the owner speaks, exactly one
    /// other person, and nobody else invited), with the owner's share. Its kind is the other person: each 1:1 is
    /// compared only with the 1:1s with the same person, so a change of who the owner meets is not a change of
    /// the owner. A 1:1 with a voice that has no name is a kind of its own and is never compared. Nil for any
    /// other meeting, and for a meeting whose size is not known: unknown is not a 1:1.
    func row(_ f: MeetingFacts, people: MeetingFilterPeople) -> CommunicationTrends.Row? {
        guard f.size(people: people) == .oneOnOne, let value = f.owner?.values[metric] else { return nil }
        let other = f.mainNames.compactMap { $0 }.first { $0 != f.owner?.name }
        let kind = other.map { "with:" + PersonNames.key($0) } ?? "unnamed:" + f.id
        return CommunicationTrends.Row(point: CommunicationTrends.Point(id: f.id, date: f.start, value: value, title: f.title), size: .oneOnOne,
                                       kind: kind, sizeKind: kind)
    }

    /// The meetings of the goal among `facts`, oldest first.
    func rows(_ facts: [MeetingFacts], people: MeetingFilterPeople) -> [CommunicationTrends.Row] {
        facts.compactMap { row($0, people: people) }.sorted { ($0.point.date, $0.point.id) < ($1.point.date, $1.point.id) }
    }
}

/// The numbers of a goal: what the app counts, what was usual before it, and the target. Code sets them when it
/// offers the goal, from the meetings' own numbers; the model gives none of them.
public struct CoachGoal: Codable, Equatable, Sendable, Hashable {
    public var measureName: String
    /// What was usual before the goal: the median and the range of the meetings from `from` to `to`.
    public var median: Double
    public var low: Double
    public var high: Double
    public var samples: Int
    public var from: Date
    public var to: Date
    /// The number to reach: at most this, for a measure where less is the goal.
    public var target: Double

    public init(measure: GoalMeasure, usual: MeetingAnalytics.Usual, from: Date, to: Date, target: Double) {
        measureName = measure.rawValue
        median = usual.median
        low = usual.low
        high = usual.high
        samples = usual.samples
        self.from = from
        self.to = to
        self.target = target
    }

    public var measure: GoalMeasure? { GoalMeasure(rawValue: measureName) }

    /// The goal is looked at again after this many days: what the owner wants to be better at changes.
    public static let reviewDays = 42.0

    /// "64% in a typical 1:1".
    public var typicalText: String { "\(CommunicationTrends.short(.talkShare, median)) in a typical 1:1" }
    /// "56 to 71% in your last 12 1:1s".
    public var usualText: String { "\(CommunicationTrends.range(.talkShare, low, high)) in your last \(samples) 1:1s" }
    /// "56% or less".
    public var targetText: String { "\(CommunicationTrends.short(.talkShare, target)) or less" }

    /// True when a share is at the target or under it, as a whole percent.
    public func meets(_ value: Double) -> Bool { (value * 100).rounded() <= (target * 100).rounded() }

    /// How one call went on the goal, from its number alone: hit at or under the target, missed over it. Nil for
    /// a call that is not a sure 1:1, for one that started before the goal was taken (`since`), and for one with
    /// no numbers: such a call says nothing about the goal, and unknown is not a miss.
    public func result(of facts: MeetingFacts?, callID: String, people: MeetingFilterPeople, since: Date?) -> FocusResult? {
        guard let facts, let measure, let since, facts.start >= since, let row = measure.row(facts, people: people) else { return nil }
        let with = facts.partner.map { " with \($0.name.split(separator: " ").first.map(String.init) ?? $0.name)" } ?? ""
        return FocusResult(callID: callID, date: facts.start, outcome: meets(row.point.value) ? .hit : .missed,
                           evidence: "You talked \(CommunicationTrends.short(.talkShare, row.point.value)) of this 1:1\(with).")
    }
}

extension CoachFocus {
    /// When the owner looks at the goal again: `CoachGoal.reviewDays` after it was taken. Nil for a goal that is
    /// only offered, and for a focus with no measured number.
    public var reviewDate: Date? {
        guard goal != nil, let accepted else { return nil }
        return accepted.addingTimeInterval(CoachGoal.reviewDays * 86_400)
    }
}

/// The goals that code offers, from the owner's own numbers, as a card in Findings.
public enum GoalOffers {
    /// An owner who talks less than this in a typical 1:1 already leaves the room: no goal to talk less. It also
    /// ends the offers that come again after a goal ended, each with a lower target.
    static let leastShare = 0.40
    /// The 1:1s that say what is usual: of the last 90 days, the newest 20.
    static let baselineDays = 90.0
    static let baselineLimit = 20
    /// An offer that waits this long with no answer has ended, and another can come.
    public static let offerDays = 7.0
    static let skill = CoachSkill.roomInOneOnOnes.rawValue

    /// True while the owner said no to a goal of this skill, ended it, or got it offered, in the last 30 days,
    /// and after it was learned. Code and the model both keep to it.
    static func rests(_ skill: String, profile: CoachProfile, at date: Date) -> Bool {
        profile.foci.contains { f in
            AdviceRules.key(f.skillID) == AdviceRules.key(skill)
                && (f.status == .learned || (f.status != .active && date.timeIntervalSince(f.updated) < AdviceRules.repeatDays * 86_400))
        }
    }

    /// "Room in 1:1s", the owner's first goal: offered at the review of a 1:1, with what was usual in the 1:1s
    /// up to it and a target of the least difference that counts for a talk share. Nil while a goal is active,
    /// while another offer waits (`offerDays`), while the goal rests (`rests`), after "No, never again", and
    /// without `Usual.firmSamples` 1:1s with people the owner met in a 1:1 two times or more: the goal is
    /// measured against the 1:1s with the same person, so single 1:1s could never show progress.
    public static func roomInOneOnOnes(this: MeetingFacts, history: [MeetingFacts], profile: CoachProfile, at date: Date,
                                       people: MeetingFilterPeople) -> CoachFocus? {
        let measure = GoalMeasure.oneOnOneTalkShare
        guard profile.activeFocus == nil else { return nil }
        if let waiting = profile.proposedFocus, date.timeIntervalSince(waiting.proposed) < offerDays * 86_400 { return nil }
        let training = profile.training(asOf: date)
        guard !training.isGoalBlocked(skill), !training.isBlocked(skill), !rests(skill, profile: profile, at: date) else { return nil }

        guard let now = measure.row(this, people: people) else { return nil }
        let rows = Array(measure.rows(history.filter { $0.id != this.id } + [this], people: people).filter {
            $0.point.date <= this.start && this.start.timeIntervalSince($0.point.date) <= baselineDays * 86_400
        }.suffix(baselineLimit))
        let repeated = Dictionary(grouping: rows, by: \.kind).values.filter { $0.count >= 2 }.reduce(0) { $0 + $1.count }
        guard repeated >= MeetingAnalytics.Usual.firmSamples, let usual = MeetingAnalytics.Usual(rows.map(\.point.value)), usual.isFirm,
              usual.median >= leastShare, let first = rows.first?.point.date else { return nil }
        let target = ((usual.median - measure.metric.margin(median: usual.median)) * 100).rounded() / 100
        let goal = CoachGoal(measure: measure, usual: usual, from: first, to: now.point.date, target: target)
        // The numbers are the card's proof; the reason says what the app will measure.
        var focus = CoachFocus(plan: "In your 1:1s, talk less and let the other person lead.",
                               why: "The target: \(goal.targetText) of the talk, measured by the app in each 1:1.",
                               metric: .talkShare, proposed: date, skill: skill)
        focus.goal = goal
        return focus
    }
}

/// How a goal goes, from the meetings' numbers alone: the meetings since the goal against the ones before it, by
/// the rule of the Analytics trends, each 1:1 against the 1:1s with the same person. A change is said only when
/// it holds against chance; with too few meetings to compare the page says so.
public struct GoalProgress: Equatable, Sendable {
    public enum State: Equatable, Sendable {
        /// Fewer compared meetings than the comparison needs: before the goal, and since it.
        case early(before: Int, since: Int)
        case steady
        /// A change in the direction of the goal, as the medians before and since.
        case toward(from: Double, to: Double)
        case away(from: Double, to: Double)
    }

    public var goal: CoachGoal
    /// When the goal was taken; for a goal that is only offered, now.
    public var start: Date
    /// The meetings of the goal since `start`, oldest first.
    public var since: [CommunicationTrends.Point]
    public var state: State
    /// The median of the compared meetings since the goal, with the mix held: the number the sentence says.
    public var typicalSince: Double?
    /// The chart: the meetings from the first one of the baseline to now, with the baseline as the usual band and
    /// a line of two pieces, the median before the goal and the median since.
    public var series: CommunicationTrends.Series
    public var interval: DateInterval

    /// True when the change toward the goal holds and its median is at the target.
    public var reached: Bool {
        if case .toward(_, let to) = state { return goal.meets(to) }
        return false
    }

    /// True while there are too few meetings to compare.
    public var isEarly: Bool {
        if case .early = state { return true }
        return false
    }

    /// Nil for a focus with no goal, or with a measure from a later build.
    public init?(focus: CoachFocus, facts: [MeetingFacts], now: Date, people: MeetingFilterPeople, calendar: Calendar = .current) {
        guard let goal = focus.goal, let measure = goal.measure else { return nil }
        self.goal = goal
        let start = focus.accepted ?? now
        self.start = start
        let rows = measure.rows(facts, people: people)
        let before = rows.filter { $0.point.date >= goal.from && $0.point.date <= goal.to }
        let after = rows.filter { $0.point.date >= start && $0.point.date <= now }
        since = after.map(\.point)
        let pools = CommunicationTrends.pools(before: before, after: after)
        let held = CommunicationTrends.held(pools)
        let firm = MeetingAnalytics.Usual.firmSamples
        typicalSince = held.last.count >= firm ? median(of: held.last) : nil
        switch CommunicationTrends.change(measure.metric, before: before, after: after) {
        case .moved(let from, let to): state = to < from ? .toward(from: from, to: to) : .away(from: from, to: to)
        case .steady: state = .steady
        default: state = .early(before: held.first.count, since: held.last.count)
        }

        let first = calendar.startOfDay(for: min(goal.from, start))
        interval = DateInterval(start: first, end: max(now, first.addingTimeInterval(86_400)))
        // Only the one series: the goal's own meetings.
        var series = CommunicationTrends.Series(measure.metric, rows: rows, interval: interval, days: CommunicationTrends.days(interval, calendar: calendar),
                                                calendar: calendar, split: .oneOnOne)
        if let usual = MeetingAnalytics.Usual(before.map(\.point.value)) {
            series.usual = CommunicationTrends.Band(usual: usual, fromBefore: true)
        }
        // A line that ran across the day of the goal would show a change that began before it. Two pieces: what
        // was usual before, and, once it can be said, the typical 1:1 since.
        var line: [CommunicationTrends.Step] = []
        if let usual = median(of: before.map(\.point.value)) {
            line += [CommunicationTrends.Step(date: max(goal.from, interval.start), value: usual, meetings: before.count, segment: 0),
                     CommunicationTrends.Step(date: min(start, interval.end), value: usual, meetings: before.count, segment: 0)]
        }
        if let typicalSince, start < interval.end {
            // One second after the end of the first piece: the chart knows a step by its date.
            line += [CommunicationTrends.Step(date: start.addingTimeInterval(1), value: typicalSince, meetings: held.last.count, segment: 1),
                     CommunicationTrends.Step(date: interval.end, value: typicalSince, meetings: held.last.count, segment: 1)]
        }
        series.line = line
        series.lineDays = 0
        series.held = false
        series.scale = CommunicationTrends.Scale(measure.metric, values: series.points.map(\.value) + [goal.target], usual: series.usual, line: line)
        self.series = series
    }

    private var day: String { start.formatted(.dateTime.month(.abbreviated).day()) }

    /// One sentence, in words that code chose: "Down from 64% to 52% since Nov 3, at your target".
    public var sentence: String {
        let short = { CommunicationTrends.short(.talkShare, $0) }
        let needs = "the app needs \(MeetingAnalytics.Usual.firmSamples) 1:1s to compare"
        switch state {
        case .early(let before, let compared):
            let firm = MeetingAnalytics.Usual.firmSamples
            if since.isEmpty { return "No 1:1 since \(day) yet. The app needs \(firm) 1:1s to compare" }
            let count = since.count == 1 ? "One 1:1" : "\(since.count) 1:1s"
            if compared >= firm, before < firm {
                return "Only \(before) of the 1:1s before the goal are with the people of your 1:1s since. The app cannot compare yet"
            }
            if compared < since.count {
                return "\(count) since \(day), \(compared) of them with people from before. Too early to tell: \(needs)"
            }
            return "\(count) since \(day). Too early to tell: \(needs)"
        case .steady: return "No clear change since \(day)"
        case .toward(let from, let to):
            return "Down from \(short(from)) to \(short(to)) since \(day)" + compared(from) + (reached ? ", at your target" : "")
        case .away(let from, let to): return "Up from \(short(from)) to \(short(to)) since \(day)" + compared(from)
        }
    }

    /// The "from" of the sentence is of the compared 1:1s only: said when it is not the number of the goal.
    private func compared(_ from: Double) -> String {
        CommunicationTrends.short(.talkShare, from) == CommunicationTrends.short(.talkShare, goal.median) ? "" : " in the 1:1s the app can compare"
    }

    /// How the sentence was reached, for a tooltip and for the coach.
    public var basis: String {
        "Your 1:1s since the goal against the \(goal.samples) before it, each against the 1:1s with the same person. A 1:1 with someone new is not "
            + "compared. A change is said only when it is 8 points or more, and chance gives one as large in fewer than 1 in 100 shuffles."
    }

    /// The whole chart in words, for VoiceOver.
    public var spoken: String {
        var said = [goal.measure?.title ?? "", sentence, "Target \(goal.targetText)", "Before the goal \(goal.typicalText), \(goal.usualText)"]
        if let typicalSince { said.append("Typical 1:1 since the goal \(CommunicationTrends.short(.talkShare, typicalSince))") }
        return said.joined(separator: ". ") + "."
    }
}
