import Foundation

/// A change in one of the owner's numbers that holds over enough calls. Code finds it with the rules of the
/// meeting Analytics baselines; the model never says "better" or "down from".
public struct CoachTrend: Equatable, Sendable {
    public var id: String
    /// What changed, in words that code wrote.
    public var text: String
    /// The numbers behind it: the last calls, and the range of the calls before.
    public var proof: String

    public init(id: String, text: String, proof: String) {
        self.id = id
        self.text = text
        self.proof = proof
    }

    /// The last calls that are compared with the ones before.
    public static let recentCalls = 5
    /// The calls before that say what was usual: not the ones from long ago.
    static let earlierCalls = 20

    /// The median of the last `recentCalls` values against the values before them, oldest first. Nil unless the
    /// earlier values are enough to say what was usual (`Usual.firmSamples`), the median is outside their range,
    /// and it differs from their median by at least `margin` and by more than their spread. One call that is
    /// not like the others moves no median, so one call is never a trend.
    static func shift(_ values: [Double], margin: Double) -> (recent: Double, before: MeetingAnalytics.Usual)? {
        guard values.count >= recentCalls + MeetingAnalytics.Usual.firmSamples else { return nil }
        let recent = values.suffix(recentCalls).sorted()[recentCalls / 2]
        guard let before = MeetingAnalytics.Usual(Array(values.dropLast(recentCalls).suffix(earlierCalls))), before.isFirm,
              recent < before.low || recent > before.high, abs(recent - before.median) >= max(margin, before.spread) else { return nil }
        return (recent, before)
    }

    /// The owner talks less than before in the 1:1s with this call's other person: room for them. Only after
    /// a 1:1, and only against 1:1s with the same person: the owner's share with a manager and with a direct
    /// report are different numbers, so a change of who the 1:1s are with must not read as a change of behavior.
    public static func oneOnOneShare(this: MeetingFacts, history: [MeetingFacts]) -> CoachTrend? {
        guard let partner = this.partner, let now = this.owner?.values[.talkShare] else { return nil }
        let earlier = history.filter { $0.id != this.id && $0.start < this.start && $0.partner?.name == partner.name }.sorted { $0.start < $1.start }
            .compactMap { $0.owner?.values[.talkShare] }
        guard let change = shift(earlier + [now], margin: 0.08), change.recent < change.before.median else { return nil }
        let first = partner.name.split(separator: " ").first.map(String.init) ?? partner.name
        return CoachTrend(id: "oneOnOneShare", text: "You leave more room in your 1:1s with \(first).",
                          proof: "You talked \(MeetingFindings.percent(change.recent)) in your last \(recentCalls) with \(first); "
                            + "\(MeetingFindings.range(.talkShare, change.before)) in the \(change.before.samples) before.")
    }
}

/// How many of the owner's commitments from calls have a day: the number behind "say the day when you take
/// an item". The model cannot count it; the commitment list can.
public struct CommitmentShare: Equatable, Sendable {
    public var withDay: Int
    public var total: Int

    /// With fewer commitments a share says nothing.
    public static let minimum = 5
    public static let days = 30.0

    public init(withDay: Int, total: Int) {
        self.withDay = withDay
        self.total = total
    }

    /// The commitments found in calls in the `days` up to `asOf`. Ones the owner added by hand are not in it:
    /// they were not said in a call.
    public init?(_ items: [Commitment], asOf: Date) {
        let recent = items.filter { !$0.deleted && $0.callID != nil && $0.madeAt <= asOf && asOf.timeIntervalSince($0.madeAt) <= Self.days * 86_400 }
        guard recent.count >= Self.minimum else { return nil }
        self.init(withDay: recent.filter { $0.due != nil }.count, total: recent.count)
    }

    public var text: String {
        "\(withDay) of \(total) commitments with a day (\(Int((Double(withDay) / Double(max(1, total)) * 100).rounded()))%), last \(Int(Self.days)) days"
    }
}

/// What the app measured for one call's review, before the model is asked: the numbers a line can stand on.
public struct CoachMeasured: Equatable, Sendable {
    /// A number of this call about the owner that is not their usual, by the test of the meeting Analytics tab.
    public struct Standout: Equatable, Sendable {
        /// The metric, so the same number is known when it comes again.
        public var id: String
        /// What follows "You": "talked 81% of the time; usually 62 to 70% in your 1:1s with Sam".
        public var text: String
        public var at: TimeInterval?

        public init(id: String, text: String, at: TimeInterval?) {
            self.id = id
            self.text = text
            self.at = at
        }
    }

    /// The furthest from the usual first.
    public var standouts: [Standout]
    public var trend: CoachTrend?
    public var commitments: CommitmentShare?
    /// The owner's longest turn, by the definition of a turn that the baselines use.
    public var longestTurn: TimeInterval?

    public init(standouts: [Standout] = [], trend: CoachTrend? = nil, commitments: CommitmentShare? = nil, longestTurn: TimeInterval? = nil) {
        self.standouts = standouts
        self.trend = trend
        self.commitments = commitments
        self.longestTurn = longestTurn
    }

    /// Numbers the coach does not make a line of: filler words are not coached, the count of questions counts
    /// each line with "?" ("right?"), and how often other people cut the owner off is not the owner's to change.
    static let notALine: Set<PersonMetric> = [.fillersPerMinute, .questionsPerHour, .cutOffsPerHour]

    /// From the same numbers and the same history as the meeting's Analytics tab, so the coach and the tab
    /// cannot say different things about one call.
    public init(record: CallRecord, owner: String, history: [MeetingFacts], commitments: [Commitment]) {
        let analytics = MeetingAnalytics(record: record, owner: owner, history: history)
        let me = analytics.owner?.id
        let left = Self.notALine.map { ".\($0.rawValue)" }
        standouts = analytics.baselines.standouts.filter { s in s.subject != nil && s.subject == me && !left.contains { s.id.hasSuffix($0) } }.map { s in
            var at: TimeInterval?
            if case .moment(let t) = s.evidence { at = t }
            return Standout(id: s.id.hasPrefix("with.") ? "talkShare" : String(s.id.split(separator: ".").last ?? ""), text: s.text, at: at)
        }
        longestTurn = analytics.owner?.longestTurn?.seconds
        trend = CoachTrend.oneOnOneShare(this: analytics.facts, history: history)
        self.commitments = CommitmentShare(commitments, asOf: record.end)
    }
}
