import Foundation

/// One thing the owner did well or can do better, tied to a moment in the call.
public struct CoachPoint: Codable, Equatable, Sendable, Hashable {
    public var title: String
    /// What happened and why it mattered in this call.
    public var observation: String
    /// The owner's words (or the exchange) that show it.
    public var quote: String
    /// Seconds from the start of the call, so the player can jump there.
    public var at: TimeInterval?
    /// The communication principle behind the point, named plainly.
    public var principle: String
    /// What to say or do next time, in the owner's own voice. Strengths have none.
    public var tryInstead: String?

    public init(title: String, observation: String, quote: String, at: TimeInterval?, principle: String, tryInstead: String?) {
        self.title = title
        self.observation = observation
        self.quote = quote
        self.at = at
        self.principle = principle
        self.tryInstead = tryInstead
    }
}

/// Whether a meeting was a good use of the owner's time, and what to change about it.
public struct MeetingValue: Codable, Equatable, Sendable, Hashable {
    public enum Rating: String, Codable, Sendable, CaseIterable { case high, medium, low }
    public enum Action: String, Codable, Sendable, CaseIterable { case keep, shorten, async, delegate, decline, restructure }

    public var rating: Rating
    public var reason: String
    public var action: Action
    /// The concrete change, in one or two sentences.
    public var suggestion: String

    public init(rating: Rating, reason: String, action: Action, suggestion: String) {
        self.rating = rating
        self.reason = reason
        self.action = action
        self.suggestion = suggestion
    }
}

/// The review at a glance: a score out of 5, scores by area, and the key points in a few words each.
public struct Scorecard: Codable, Equatable, Sendable {
    public struct Dimension: Codable, Equatable, Sendable, Hashable {
        public var name: String
        public var score: Int

        public init(name: String, score: Int) {
            self.name = name
            self.score = score
        }
    }

    public static let dimensionNames = ["Clarity", "Listening", "Follow-through", "Use of time"]
    public static let pointWords = 10

    public var score: Int
    public var reason: String
    public var dimensions: [Dimension]
    public var positives: [String]
    public var negatives: [String]

    /// Keeps scores in 1...5 and each point to 10 words, whatever the model sent.
    public init(score: Int, reason: String, dimensions: [Dimension], positives: [String], negatives: [String]) {
        func clamp(_ n: Int) -> Int { min(5, max(1, n)) }
        func short(_ text: String) -> String {
            let words = text.split(separator: " ")
            return words.count <= Self.pointWords ? text : words.prefix(Self.pointWords).joined(separator: " ") + "…"
        }
        self.score = clamp(score)
        self.reason = reason
        self.dimensions = dimensions.map { Dimension(name: $0.name, score: clamp($0.score)) }
        self.positives = positives.compactMap(\.nonBlank).prefix(3).map(short)
        self.negatives = negatives.compactMap(\.nonBlank).prefix(3).map(short)
    }
}

/// The owner's verdict on one point: right or wrong, and why.
public struct CoachFeedback: Codable, Equatable, Sendable {
    public var agree: Bool
    public var note: String?
    public var date: Date

    public init(agree: Bool, note: String?, date: Date = Date()) {
        self.agree = agree
        self.note = note
        self.date = date
    }
}

/// One short note of the review, with the moment it is about.
public struct CoachNote: Codable, Equatable, Sendable, Hashable {
    public var text: String
    public var quote: String?
    public var at: TimeInterval?
    /// For "try next time": the words the owner could say.
    public var say: String?
    /// The behavior the note is about, in a few words, so the same advice is known when it comes again.
    public var skill: String?
    public var measure: CoachMeasure?
    /// The measured number that stands next to the note, when its measure has one.
    public var number: String?
    /// Why it matters: the effect of the move, or what the miss costs. Nil in reviews from before it.
    public var why: String?

    public init(text: String, quote: String? = nil, at: TimeInterval? = nil, say: String? = nil, skill: String? = nil,
                measure: CoachMeasure? = nil, number: String? = nil, why: String? = nil) {
        self.text = text
        self.quote = quote
        self.at = at
        self.say = say
        self.skill = skill
        self.measure = measure
        self.number = number
        self.why = why
    }

    enum CodingKeys: String, CodingKey { case text, quote, at, say, skill, measure, number, why }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        text = try c.decode(String.self, forKey: .text)
        quote = try c.decodeIfPresent(String.self, forKey: .quote)
        at = try c.decodeIfPresent(TimeInterval.self, forKey: .at)
        say = try c.decodeIfPresent(String.self, forKey: .say)
        skill = try c.decodeIfPresent(String.self, forKey: .skill)
        // A measure from a later build is no measure here, not a review that cannot be read.
        measure = (try? c.decodeIfPresent(CoachMeasure.self, forKey: .measure)) ?? nil
        number = try c.decodeIfPresent(String.self, forKey: .number)
        why = try c.decodeIfPresent(String.self, forKey: .why)
    }
}

/// The coach's review of one call, saved as `coach.json` next to `call.json`.
public struct CoachReview: Codable, Equatable, Sendable {
    public static let fileName = "coach.json"

    public var headline: String
    public var overview: String
    public var strengths: [CoachPoint]
    public var improvements: [CoachPoint]
    /// How the call went against the focus the owner was working on, when there was one.
    public var focusProgress: String?
    public var value: MeetingValue?
    public var delivery: DeliveryStats?
    /// Nil for reviews from before the scorecard.
    public var scorecard: Scorecard?
    /// The owner's rating of each point, by the point's title.
    public var feedback: [String: CoachFeedback] = [:]
    /// The owner's conversation with the coach about this review.
    public var thread: [ChatMessage] = []
    public var didWell: CoachNote?
    /// The model's own claim of a change, in reviews from before one line. Kept in the file and shown nowhere:
    /// it compared one call with a median. A measured change is a line of the kind `progress`.
    public var improving: CoachNote?
    public var tryNext: CoachNote?
    /// The focus that was active for this call, and how the call went on it.
    public var focusID: UUID?
    public var focusResult: FocusResult?
    /// The owner mostly listened, or nothing stood out: the review is a line at most.
    public var quiet = false
    /// 0 for a review from before one line.
    public var version = 0
    /// The one line the review shows; nil when there is nothing with proof to say.
    public var line: CoachLine?
    /// Advice of the last 30 days that this call showed again: the moment, kept as evidence and not said again.
    public var seenAgain: CoachNote?
    /// The cards this call gives about how the owner acted, each with proof (`FindingRules`). Nil for a review
    /// from before the cards: its cards are then made from its line and its notes.
    public var findings: [CoachFinding]?

    public init(headline: String, overview: String, strengths: [CoachPoint], improvements: [CoachPoint],
                focusProgress: String?, value: MeetingValue? = nil, delivery: DeliveryStats? = nil, scorecard: Scorecard? = nil) {
        self.value = value
        self.scorecard = scorecard
        self.headline = headline
        self.overview = overview
        self.strengths = strengths
        self.improvements = improvements
        self.focusProgress = focusProgress
        self.delivery = delivery
    }

    enum CodingKeys: String, CodingKey {
        case headline, overview, strengths, improvements, focusProgress, value, delivery, feedback, thread, scorecard
        case didWell, improving, tryNext, focusID, focusResult, quiet, version, line, seenAgain, findings
    }

    /// Reviews from before feedback existed have no feedback or thread.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        headline = try c.decode(String.self, forKey: .headline)
        overview = try c.decode(String.self, forKey: .overview)
        strengths = try c.decode([CoachPoint].self, forKey: .strengths)
        improvements = try c.decode([CoachPoint].self, forKey: .improvements)
        focusProgress = try c.decodeIfPresent(String.self, forKey: .focusProgress)
        value = try c.decodeIfPresent(MeetingValue.self, forKey: .value)
        delivery = try c.decodeIfPresent(DeliveryStats.self, forKey: .delivery)
        feedback = try c.decodeIfPresent([String: CoachFeedback].self, forKey: .feedback) ?? [:]
        thread = try c.decodeIfPresent([ChatMessage].self, forKey: .thread) ?? []
        scorecard = try c.decodeIfPresent(Scorecard.self, forKey: .scorecard)
        didWell = try c.decodeIfPresent(CoachNote.self, forKey: .didWell)
        improving = try c.decodeIfPresent(CoachNote.self, forKey: .improving)
        tryNext = try c.decodeIfPresent(CoachNote.self, forKey: .tryNext)
        focusID = try c.decodeIfPresent(UUID.self, forKey: .focusID)
        focusResult = try c.decodeIfPresent(FocusResult.self, forKey: .focusResult)
        quiet = try c.decodeIfPresent(Bool.self, forKey: .quiet) ?? false
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 0
        // A line of a kind from a later build is no line here, not a review that cannot be read.
        line = (try? c.decodeIfPresent(CoachLine.self, forKey: .line)) ?? nil
        seenAgain = (try? c.decodeIfPresent(CoachNote.self, forKey: .seenAgain)) ?? nil
        // One card that does not decode is left out; the review still reads.
        findings = ((try? c.decodeIfPresent(LossyArray<CoachFinding>.self, forKey: .findings)) ?? nil)?.values
    }

    /// This review with another device's ratings and conversation added: the newer rating of a point wins,
    /// and messages the other copy has that this one lacks are appended.
    public func mergingNotes(from other: CoachReview) -> CoachReview {
        var out = self
        for (title, f) in other.feedback where (out.feedback[title]?.date ?? .distantPast) < f.date { out.feedback[title] = f }
        let ids = Set(thread.map(\.id))
        out.thread += other.thread.filter { !ids.contains($0.id) }
        return out
    }

    /// Below this the owner mostly listened, and the review covers listening and value instead of delivery.
    public static let listenerSeconds: TimeInterval = 60

    public static func isListener(_ d: DeliveryStats) -> Bool { d.talkSeconds < listenerSeconds }

    public static func load(in dir: URL) -> CoachReview? {
        guard let data = try? Data(contentsOf: dir.appendingPathComponent(fileName)) else { return nil }
        return try? JSONDecoder.coach.decode(CoachReview.self, from: data)
    }

    /// The call's folder must be there: a review must not bring back the folder of a deleted meeting.
    public func save(in dir: URL) throws {
        try JSONEncoder.coach.encode(self).write(to: dir.appendingPathComponent(Self.fileName), options: .atomic)
    }
}

extension JSONEncoder {
    static let coach: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }()
}

extension JSONDecoder {
    static let coach: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}
