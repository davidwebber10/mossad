import Foundation

public struct CoachResult: Sendable, Equatable {
    public var review: CoachReview
    public var update: CoachProfileUpdate
}

public protocol Coaching: Sendable {
    func review(record: CallRecord, profile: CoachProfile, tone: VoiceTone?) async throws -> CoachResult
}

/// Reviews one call with Claude, given the coach's profile of the owner.
public struct LLMCoach: Coaching {
    private let llm: any LanguageModel
    private let ownerName: String

    public init(llm: any LanguageModel, ownerName: String) {
        self.llm = llm
        self.ownerName = ownerName
    }

    public init(apiKey: String, model: String = "claude-opus-5-5", session: URLSession = .shared, ownerName: String, usage: UsageLog? = nil) {
        self.init(llm: AnthropicModel(apiKey: apiKey, model: model, session: session, usage: usage), ownerName: ownerName)
    }

    static var schema: [String: Any] {
        let point = Schema.object([
            "title": Schema.string, "observation": Schema.string, "quote": Schema.string,
            "at_seconds": ["anyOf": [["type": "number"], ["type": "null"]]],
            "principle": Schema.string, "try_instead": Schema.nullableString,
        ])
        return Schema.object([
            "headline": Schema.string,
            "overview": Schema.string,
            "strengths": Schema.array(point),
            "improvements": Schema.array(point),
            "focus_progress": Schema.nullableString,
            "meeting_value": Schema.object([
                "rating": Schema.oneOf(MeetingValue.Rating.allCases.map(\.rawValue)),
                "reason": Schema.string,
                "action": Schema.oneOf(MeetingValue.Action.allCases.map(\.rawValue)),
                "suggestion": Schema.string,
            ]),
            "profile": Schema.object([
                "summary": Schema.string,
                "focus": Schema.string,
                "patterns": Schema.array(Schema.object([
                    "name": Schema.string, "kind": Schema.oneOf(["strength", "growth"]), "note": Schema.string,
                    "trend": Schema.oneOf(["improving", "steady", "slipping"]),
                ])),
                "people": Schema.array(Schema.object(["name": Schema.string, "note": Schema.string])),
            ]),
        ])
    }

    public func review(record: CallRecord, profile: CoachProfile, tone: VoiceTone?) async throws -> CoachResult {
        var delivery = DeliveryStats(record: record, owner: ownerName)
        delivery.tone = tone
        let out = try await llm.json(system: CoachPrompt.system(owner: ownerName),
                                     user: CoachPrompt.user(record: record, owner: ownerName, profile: profile, delivery: delivery),
                                     schema: Self.schema, effort: .high, purpose: .coach, as: Output.self)
        let review = CoachReview(headline: out.headline, overview: out.overview, strengths: out.strengths.map(\.point),
                                 improvements: out.improvements.map(\.point), focusProgress: out.focus_progress?.nonBlank,
                                 value: out.meeting_value, delivery: delivery)
        return CoachResult(review: review, update: out.profile)
    }

    private struct Output: Decodable {
        let headline: String
        let overview: String
        let strengths: [Point]
        let improvements: [Point]
        let focus_progress: String?
        let meeting_value: MeetingValue?
        let profile: CoachProfileUpdate
    }

    private struct Point: Decodable {
        let title, observation, quote, principle: String
        let at_seconds: Double?
        let try_instead: String?

        var point: CoachPoint {
            CoachPoint(title: title, observation: observation, quote: quote, at: at_seconds, principle: principle, tryInstead: try_instead?.nonBlank)
        }
    }
}
