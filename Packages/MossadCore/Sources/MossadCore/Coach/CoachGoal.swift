import Foundation

/// What the app counts for a goal. In the file it is text (`CoachGoal.measureName`): a measure from a later build
/// is no measure here, and the memory still reads.
public enum GoalMeasure: String, Codable, Sendable, CaseIterable {
    /// The owner's share of the talk in their 1:1s: the number of "room in 1:1s". Lower leaves the other person
    /// more room.
    case oneOnOneTalkShare = "one_on_one_talk_share"

    var metric: PersonMetric { .talkShare }
    var split: CommunicationTrends.Split { .oneOnOne }

    /// "Your talk share in 1:1s".
    public var title: String { "Your talk share in 1:1s" }
    /// Where the goal applies.
    public var context: String { "1:1s" }
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

    /// How one call went on the goal, from its number alone: hit at or under the target, missed over it, and no
    /// chance in a call that is not a 1:1. Nil for a call with no numbers: unknown is not a miss.
    public func result(of facts: MeetingFacts?, callID: String) -> FocusResult? {
        guard let facts, let measure else { return nil }
        guard let row = CommunicationTrends.row(facts, measure.metric), row.size == measure.split else {
            return FocusResult(callID: callID, date: facts.start, outcome: .noChance, evidence: "Not a 1:1.")
        }
        let with = facts.partner.map { " with \($0.name.split(separator: " ").first.map(String.init) ?? $0.name)" } ?? ""
        let value = (row.point.value * 100).rounded() / 100
        return FocusResult(callID: callID, date: facts.start, outcome: value <= target ? .hit : .missed,
                           evidence: "You talked \(CommunicationTrends.short(.talkShare, row.point.value)) of this 1:1\(with).")
    }
}

extension CoachFocus {
    /// When the owner looks at the goal again: `CoachGoal.reviewDays` after it was taken, or offered. Nil for a
    /// focus with no measured number.
    public var reviewDate: Date? { goal == nil ? nil : (accepted ?? proposed).addingTimeInterval(CoachGoal.reviewDays * 86_400) }
}

/// The goals that code offers, from the owner's own numbers, as a card in Findings.
public enum GoalOffers {
    /// An owner who talks less than this in a typical 1:1 already leaves the room: no goal to talk less.
    static let leastShare = 0.40
    /// The 1:1s that say what is usual: of the last 90 days, the newest 20.
    static let baselineDays = 90.0
    static let baselineLimit = 20
    /// The lowest target: a 1:1 is a talk of two.
    static let lowestTarget = 0.30
    /// An offer that waits this long with no answer has ended, and another can come.
    public static let offerDays = 7.0

    /// "Room in 1:1s", the owner's first goal: offered at the review of a 1:1, with what was usual in the 1:1s
    /// up to it and a target of the least difference that counts for a talk share. Nil while a goal is active,
    /// while another offer waits (`offerDays`), for 30 days after it was last offered, declined, or ended, after
    /// "No, never again", once it was learned, and without `Usual.firmSamples` 1:1s.
    public static func roomInOneOnOnes(this: MeetingFacts, history: [MeetingFacts], profile: CoachProfile, at date: Date) -> CoachFocus? {
        let skill = CoachSkill.roomInOneOnOnes.rawValue, measure = GoalMeasure.oneOnOneTalkShare
        guard profile.activeFocus == nil else { return nil }
        if let waiting = profile.proposedFocus, date.timeIntervalSince(waiting.proposed) < offerDays * 86_400 { return nil }
        let training = profile.training(asOf: date)
        guard !training.isGoalBlocked(skill), !training.isBlocked(skill) else { return nil }
        let same = profile.foci.filter { AdviceRules.key($0.skillID) == AdviceRules.key(skill) }
        guard !same.contains(where: { $0.status == .learned }),
              !same.contains(where: { date.timeIntervalSince($0.updated) < AdviceRules.repeatDays * 86_400 }) else { return nil }

        guard let now = CommunicationTrends.row(this, measure.metric), now.size == measure.split else { return nil }
        let rows = (history.filter { $0.id != this.id } + [this]).compactMap { f -> CommunicationTrends.Row? in
            guard f.start <= this.start, this.start.timeIntervalSince(f.start) <= baselineDays * 86_400,
                  let row = CommunicationTrends.row(f, measure.metric), row.size == measure.split else { return nil }
            return row
        }.sorted { $0.point.date < $1.point.date }.suffix(baselineLimit)
        guard let usual = MeetingAnalytics.Usual(rows.map(\.point.value)), usual.isFirm, usual.median >= leastShare,
              let first = rows.first?.point.date else { return nil }
        let target = max(lowestTarget, ((usual.median - measure.metric.margin(median: usual.median)) * 100).rounded() / 100)
        let goal = CoachGoal(measure: measure, usual: usual, from: first, to: now.point.date, target: target)
        var focus = CoachFocus(plan: "In your 1:1s, talk less and let the other person lead.",
                               why: "You talked \(goal.typicalText) (\(goal.usualText)). The target: \(goal.targetText).",
                               metric: .talkShare, proposed: date, skill: skill)
        focus.goal = goal
        return focus
    }
}

/// How a goal goes, from the meetings' numbers alone: the meetings since the goal against the ones before it, by
/// the rule of the Analytics trends. A change is said only when it holds against chance; with too few meetings
/// the page says that it is too early.
public struct GoalProgress: Equatable, Sendable {
    public enum State: Equatable, Sendable {
        /// Fewer meetings since the goal, of kinds that were there before, than the comparison needs.
        case early(meetings: Int)
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
    /// The chart: the meetings from the first one of the baseline to now, with the baseline as the usual band.
    public var series: CommunicationTrends.Series
    public var interval: DateInterval

    /// True when the change toward the goal holds and its median is at the target.
    public var reached: Bool {
        if case .toward(_, let to) = state { return (to * 100).rounded() / 100 <= goal.target }
        return false
    }

    /// True while there are too few meetings to compare.
    public var isEarly: Bool {
        if case .early = state { return true }
        return false
    }

    /// The median of the meetings since the goal, once there are enough of them to say it.
    public var typicalSince: Double? {
        since.count >= MeetingAnalytics.Usual.firmSamples ? median(of: since.map(\.value)) : nil
    }

    /// Nil for a focus with no goal, or with a measure from a later build.
    public init?(focus: CoachFocus, facts: [MeetingFacts], now: Date, calendar: Calendar = .current) {
        guard let goal = focus.goal, let measure = goal.measure else { return nil }
        self.goal = goal
        let start = focus.accepted ?? now
        self.start = start
        let rows = facts.compactMap { f -> CommunicationTrends.Row? in
            guard let row = CommunicationTrends.row(f, measure.metric), row.size == measure.split else { return nil }
            return row
        }.sorted { $0.point.date < $1.point.date }
        let before = rows.filter { $0.point.date >= goal.from && $0.point.date <= goal.to }
        let after = rows.filter { $0.point.date >= start && $0.point.date <= now }
        since = after.map(\.point)
        switch CommunicationTrends.change(measure.metric, before: before, after: after) {
        case .moved(let from, let to): state = to < from ? .toward(from: from, to: to) : .away(from: from, to: to)
        case .steady: state = .steady
        default: state = .early(meetings: CommunicationTrends.pools(before: before, after: after).reduce(0) { $0 + $1.last.count })
        }

        let first = calendar.startOfDay(for: min(goal.from, start))
        interval = DateInterval(start: first, end: max(now, first.addingTimeInterval(86_400)))
        var series = CommunicationTrends(facts: facts, interval: interval, calendar: calendar).series(measure.metric, measure.split)
            ?? CommunicationTrends.Series(measure.metric, rows: [], interval: interval, days: CommunicationTrends.days(interval, calendar: calendar),
                                          calendar: calendar, split: measure.split)
        if let usual = MeetingAnalytics.Usual(before.map(\.point.value)) {
            series.usual = CommunicationTrends.Band(usual: usual, fromBefore: true)
        }
        series.scale = CommunicationTrends.Scale(measure.metric, values: series.points.map(\.value) + [goal.target], usual: series.usual, line: series.line)
        self.series = series
    }

    private var day: String { start.formatted(.dateTime.month(.abbreviated).day()) }

    /// One sentence, in words that code chose: "Down from 64% to 52% since Nov 3, at your target".
    public var sentence: String {
        let short = { CommunicationTrends.short(.talkShare, $0) }
        switch state {
        case .early(let compared):
            let firm = MeetingAnalytics.Usual.firmSamples
            if since.isEmpty { return "No 1:1 since \(day) yet. The app compares from \(firm)" }
            let count = since.count == 1 ? "One 1:1" : "\(since.count) 1:1s"
            if compared < since.count {
                return "\(count) since \(day), \(compared) of them like the ones before. Too early to tell: the app compares from \(firm)"
            }
            return "\(count) since \(day). Too early to tell: the app compares from \(firm)"
        case .steady: return "No clear change since \(day)"
        case .toward(let from, let to): return "Down from \(short(from)) to \(short(to)) since \(day)" + (reached ? ", at your target" : "")
        case .away(let from, let to): return "Up from \(short(from)) to \(short(to)) since \(day)"
        }
    }

    /// How the sentence was reached, for a tooltip and for the coach.
    public var basis: String {
        "Your 1:1s since the goal against the \(goal.samples) before it, each kind of 1:1 against its own kind. A 1:1 with someone new is not "
            + "compared. A change is said only when it is 8 points or more, and chance gives one as large in fewer than 1 in 100 shuffles."
    }

    /// The whole chart in words, for VoiceOver.
    public var spoken: String {
        var said = [goal.measure?.title ?? "", sentence, "Target \(goal.targetText)", "Before the goal \(goal.typicalText), \(goal.usualText)"]
        if let typicalSince { said.append("Typical 1:1 since the goal \(CommunicationTrends.short(.talkShare, typicalSince))") }
        return said.joined(separator: ". ") + "."
    }
}
