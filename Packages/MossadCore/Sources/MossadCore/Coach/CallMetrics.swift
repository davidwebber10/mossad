import Foundation

/// The owner's numbers for one call against goals from research and against their own usual, plus where in the
/// call they talked. Measured from the transcript, never by the model.
public struct CallMetrics: Equatable, Sendable {
    public enum Status: Sendable { case good, over, info }

    public struct Check: Equatable, Sendable, Identifiable {
        public var id: FocusMetric { metric }
        public var metric: FocusMetric
        public var value: Double
        public var goal: String
        public var status: Status
        /// The owner's median over earlier calls where they spoke, when there are some.
        public var usual: Double?
    }

    /// Three minutes of the call.
    public struct Slice: Equatable, Sendable, Identifiable {
        public var id: TimeInterval { start }
        public var start: TimeInterval
        /// The owner's part of the speech that started in this slice, 0 to 1.
        public var share: Double
        /// Nil when the owner spoke too little in the slice to measure.
        public var wordsPerMinute: Double?
    }

    public struct Turn: Equatable, Sendable {
        public var start: TimeInterval
        public var seconds: TimeInterval
    }

    public static let sliceSeconds: TimeInterval = 180
    public static let longTurnSeconds: TimeInterval = 120
    public static let fastPace = 220.0
    public static let paceMargin = 1.15
    /// Lines closer than this are one turn: transcription splits a long answer at breaths.
    static let turnGap: TimeInterval = 2.5

    public let speakers: Int
    public let checks: [Check]
    public let timeline: [Slice]
    /// Owner turns over the long-turn goal, in call order.
    public let longTurns: [Turn]
    public let longestTurn: Turn?

    public init(record r: CallRecord, owner: String, history: [DeliveryStats]) {
        let keys = Set(r.speakerNames.filter { $0.value == owner }.keys)
        func isOwner(_ u: Utterance) -> Bool { keys.contains(u.speakerKey) }
        func seconds(_ u: Utterance) -> TimeInterval { max(0, u.end - u.start) }
        func words(_ u: Utterance) -> Int { u.text.split(whereSeparator: \.isWhitespace).count }
        let ordered = r.utterances.sorted { $0.start < $1.start }
        speakers = Set(ordered.map { r.speakerNames[$0.speakerKey] ?? $0.speakerKey }).count

        var turns: [Turn] = []
        var current: (start: TimeInterval, end: TimeInterval)?
        for u in ordered {
            if isOwner(u) {
                if let c = current, u.start - c.end < Self.turnGap { current = (c.start, max(c.end, u.end)) } else {
                    if let c = current { turns.append(Turn(start: c.start, seconds: c.end - c.start)) }
                    current = (u.start, u.end)
                }
            } else if let c = current {
                turns.append(Turn(start: c.start, seconds: c.end - c.start))
                current = nil
            }
        }
        if let c = current { turns.append(Turn(start: c.start, seconds: c.end - c.start)) }
        longestTurn = turns.max { $0.seconds < $1.seconds }
        longTurns = turns.filter { $0.seconds > Self.longTurnSeconds }

        let end = ordered.map(\.end).max() ?? 0
        timeline = stride(from: 0, to: end, by: Self.sliceSeconds).map { start in
            let here = ordered.filter { $0.start >= start && $0.start < start + Self.sliceSeconds }
            let mine = here.filter(isOwner)
            let all = here.map(seconds).reduce(0, +), talk = mine.map(seconds).reduce(0, +)
            return Slice(start: start, share: all > 0 ? talk / all : 0,
                         wordsPerMinute: talk > 20 ? Double(mine.map(words).reduce(0, +)) / (talk / 60) : nil)
        }

        let d = DeliveryStats(record: r, owner: owner)
        guard !CoachReview.isListener(d) else { checks = []; return }
        let spoke = history.filter { !CoachReview.isListener($0) }
        func median(_ xs: [Double]) -> Double? {
            guard !xs.isEmpty else { return nil }
            let s = xs.sorted()
            return s.count % 2 == 1 ? s[s.count / 2] : (s[s.count / 2 - 1] + s[s.count / 2]) / 2
        }

        let n = max(2, speakers)
        let shareLimit = n == 2 ? 0.5 : 1.5 / Double(n)
        let shareGoal = n == 2 ? "Up to 50% in a 1:1" : "Up to \(Int((shareLimit * 100).rounded()))% with \(n) people"
        let longest = longestTurn?.seconds ?? 0
        let usualPace = median(spoke.map(\.wordsPerMinute).filter { $0 > 0 })
        let paceLimit = min(Self.fastPace, (usualPace ?? .infinity) * Self.paceMargin)
        checks = [
            Check(metric: .talkShare, value: d.talkShare, goal: shareGoal, status: d.talkShare > shareLimit ? .over : .good,
                  usual: median(spoke.map(\.talkShare))),
            Check(metric: .longestTurn, value: longest, goal: "Under 2 min", status: longest > Self.longTurnSeconds ? .over : .good,
                  usual: median(spoke.map(\.longestTurnSeconds))),
            Check(metric: .questions, value: Double(d.questions), goal: "More than your usual", status: .info,
                  usual: median(spoke.map { Double($0.questions) })),
            Check(metric: .pace, value: d.wordsPerMinute, goal: usualPace == nil ? "Under 220 wpm" : "Near your usual",
                  status: d.wordsPerMinute > paceLimit ? .over : .good, usual: usualPace),
        ]
    }

    public func check(_ metric: FocusMetric) -> Check? { checks.first { $0.metric == metric } }
}
