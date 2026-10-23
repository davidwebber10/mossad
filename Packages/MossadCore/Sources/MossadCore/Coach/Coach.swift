import Foundation

public struct CoachResult: Sendable, Equatable {
    public var review: CoachReview
    public var update: CoachProfileUpdate
    /// A focus for the owner to accept, when they have none.
    public var proposal: CoachFocus?

    public init(review: CoachReview, update: CoachProfileUpdate, proposal: CoachFocus? = nil) {
        self.review = review
        self.update = update
        self.proposal = proposal
    }
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
            "at_seconds": Schema.nullableNumber,
            "principle": Schema.string, "try_instead": Schema.nullableString,
        ])
        let note = Schema.object(["text": Schema.string, "quote": Schema.nullableString, "at_seconds": Schema.nullableNumber])
        func nullable(_ s: [String: Any]) -> [String: Any] { ["anyOf": [s, ["type": "null"]]] }
        return Schema.object([
            "quiet": ["type": "boolean"],
            "headline": Schema.string,
            "did_well": nullable(note),
            "improving": nullable(note),
            "try_next": nullable(Schema.object(["text": Schema.string, "quote": Schema.nullableString, "at_seconds": Schema.nullableNumber,
                                                "say": Schema.nullableString])),
            "focus_result": nullable(Schema.object(["outcome": Schema.oneOf(FocusOutcome.allCases.map(\.rawValue)),
                                                    "evidence": Schema.string, "at_seconds": Schema.nullableNumber])),
            "focus_proposal": nullable(Schema.object(["plan": Schema.string, "why": Schema.string,
                                                      "metric": nullable(Schema.oneOf(FocusMetric.allCases.map(\.rawValue)))])),
            "strengths": Schema.array(point),
            "improvements": Schema.array(point),
            "meeting_value": Schema.object([
                "rating": Schema.oneOf(MeetingValue.Rating.allCases.map(\.rawValue)),
                "reason": Schema.string,
                "action": Schema.oneOf(MeetingValue.Action.allCases.map(\.rawValue)),
                "suggestion": Schema.string,
            ]),
            "profile": Schema.object([
                "summary": Schema.string,
                "patterns": Schema.array(Schema.object([
                    "name": Schema.string, "kind": Schema.oneOf(["strength", "growth"]), "note": Schema.string,
                    "trend": Schema.oneOf(["improving", "steady", "slipping"]),
                ])),
                "people": Schema.array(Schema.object(["name": Schema.string, "note": Schema.string])),
            ]),
        ])
    }

    /// The most detail points kept per side, for "More from the coach".
    static let detailPoints = 2

    public func review(record: CallRecord, profile: CoachProfile, tone: VoiceTone?) async throws -> CoachResult {
        var delivery = DeliveryStats(record: record, owner: ownerName)
        delivery.tone = tone
        let metrics = CallMetrics(record: record, owner: ownerName, history: profile.history.compactMap(\.delivery))
        let out = try await llm.json(system: CoachPrompt.system(owner: ownerName, voice: profile.voice),
                                     user: CoachPrompt.user(record: record, owner: ownerName, profile: profile, delivery: delivery, metrics: metrics),
                                     schema: Self.schema, effort: .high, purpose: .coach, as: Output.self)
        let focus = profile.activeFocus
        var review = CoachReview(headline: out.headline, overview: "", strengths: Array(out.strengths.prefix(Self.detailPoints).map(\.point)),
                                 improvements: Array(out.improvements.prefix(Self.detailPoints).map(\.point)), focusProgress: nil,
                                 value: out.meeting_value, delivery: delivery)
        review.quiet = out.quiet
        review.didWell = out.did_well?.note
        review.improving = out.improving?.note
        review.tryNext = out.try_next.map { CoachNote(text: $0.text, quote: $0.quote?.nonBlank, at: $0.at_seconds, say: $0.say?.nonBlank) }
        if let focus, let r = out.focus_result {
            review.focusID = focus.id
            review.focusResult = FocusResult(callID: record.id, date: record.start, outcome: r.outcome, evidence: r.evidence, at: r.at_seconds)
        }
        let proposal = out.focus_proposal.map { CoachFocus(plan: $0.plan, why: $0.why, metric: $0.metric, proposed: record.start) }
        let update = CoachProfileUpdate(summary: out.profile.summary, focus: "", patterns: out.profile.patterns, people: out.profile.people)
        return CoachResult(review: review, update: update, proposal: proposal)
    }

    private struct Note: Decodable {
        let text: String
        let quote: String?
        let at_seconds: Double?
        var note: CoachNote { CoachNote(text: text, quote: quote?.nonBlank, at: at_seconds) }
    }

    private struct Next: Decodable {
        let text: String
        let quote, say: String?
        let at_seconds: Double?
    }

    private struct Result: Decodable {
        let outcome: FocusOutcome
        let evidence: String
        let at_seconds: Double?
    }

    private struct Proposal: Decodable {
        let plan, why: String
        let metric: FocusMetric?
    }

    private struct ProfileOut: Decodable {
        let summary: String
        let patterns: [CoachPatternUpdate]
        let people: [CoachPersonUpdate]
    }

    private struct Output: Decodable {
        let quiet: Bool
        let headline: String
        let did_well, improving: Note?
        let try_next: Next?
        let focus_result: Result?
        let focus_proposal: Proposal?
        let strengths: [Point]
        let improvements: [Point]
        let meeting_value: MeetingValue?
        let profile: ProfileOut
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
