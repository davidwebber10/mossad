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

    public init(headline: String, overview: String, strengths: [CoachPoint], improvements: [CoachPoint],
                focusProgress: String?, value: MeetingValue? = nil, delivery: DeliveryStats? = nil) {
        self.value = value
        self.headline = headline
        self.overview = overview
        self.strengths = strengths
        self.improvements = improvements
        self.focusProgress = focusProgress
        self.delivery = delivery
    }

    public static func load(in dir: URL) -> CoachReview? {
        guard let data = try? Data(contentsOf: dir.appendingPathComponent(fileName)) else { return nil }
        return try? JSONDecoder.coach.decode(CoachReview.self, from: data)
    }

    public func save(in dir: URL) throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
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
