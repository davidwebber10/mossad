import Foundation

public struct CoachResult: Sendable, Equatable {
    public var review: CoachReview
    public var update: CoachProfileUpdate
    /// A focus for the owner to accept, when they have none.
    public var proposal: CoachFocus?
    /// Conclusions for the owner to confirm.
    public var questions: [CoachQuestion]
    /// What the review says, for the advice log. Filled by `CoachLineRules.settle`.
    public var advice: [CoachAdvice] = []
    /// Why code dropped a note of the model: no proof, too long, a trend, a skill that is not coached.
    public var dropped: [String] = []

    public init(review: CoachReview, update: CoachProfileUpdate, proposal: CoachFocus? = nil, questions: [CoachQuestion] = []) {
        self.review = review
        self.update = update
        self.proposal = proposal
        self.questions = questions
    }
}

public protocol Coaching: Sendable {
    func review(record: CallRecord, profile: CoachProfile, tone: VoiceTone?) async throws -> CoachResult
    /// `people` are "Name, Title" lines for speakers found in the org chart.
    func review(record: CallRecord, profile: CoachProfile, tone: VoiceTone?, people: [String]) async throws -> CoachResult
    /// `measured` is what the app counted for this call, so the model is told what is not usual and judges no trend.
    func review(record: CallRecord, profile: CoachProfile, tone: VoiceTone?, people: [String], measured: CoachMeasured) async throws -> CoachResult
}

extension Coaching {
    public func review(record: CallRecord, profile: CoachProfile, tone: VoiceTone?, people: [String]) async throws -> CoachResult {
        try await review(record: record, profile: profile, tone: tone)
    }

    public func review(record: CallRecord, profile: CoachProfile, tone: VoiceTone?, people: [String], measured: CoachMeasured) async throws -> CoachResult {
        try await review(record: record, profile: profile, tone: tone, people: people)
    }
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
        // Claude allows at most 16 union-typed parameters, so "say", a label, and a quote use "" for none instead
        // of null, and a note's time is a plain number: a note with no moment is no note.
        let skill = Schema.oneOf(CoachSkill.allCases.map(\.rawValue))
        let number: [String: Any] = ["type": "number"]
        func nullable(_ s: [String: Any]) -> [String: Any] { ["anyOf": [s, ["type": "null"]]] }
        return Schema.object([
            "quiet": ["type": "boolean"],
            "headline": Schema.string,
            "did_well": nullable(Schema.object(["text": Schema.string, "quote": Schema.string, "at_seconds": number, "skill": skill,
                                                "skill_label": Schema.string])),
            "try_next": nullable(Schema.object(["text": Schema.string, "quote": Schema.string, "at_seconds": number, "say": Schema.string,
                                                "skill": skill, "skill_label": Schema.string])),
            "seen_again": nullable(Schema.object(["skill": skill, "skill_label": Schema.string, "quote": Schema.string, "at_seconds": number])),
            "focus_result": nullable(Schema.object(["outcome": Schema.oneOf(FocusOutcome.allCases.map(\.rawValue)),
                                                    "evidence": Schema.string, "quote": Schema.string, "at_seconds": Schema.nullableNumber])),
            "focus_proposal": nullable(Schema.object(["plan": Schema.string, "why": Schema.string,
                                                      "metric": nullable(Schema.oneOf(FocusMetric.allCases.map(\.rawValue))), "skill": skill,
                                                      "skill_label": Schema.string])),
            "questions": Schema.array(Schema.object([
                "statement": Schema.string, "kind": Schema.oneOf(CoachQuestion.Kind.allCases.map(\.rawValue)),
                "evidence": Schema.string, "at_seconds": Schema.nullableNumber,
            ])),
            "strengths": Schema.array(point),
            "improvements": Schema.array(point),
            "meeting_value": Schema.object([
                "rating": Schema.oneOf(MeetingValue.Rating.allCases.map(\.rawValue)),
                "reason": Schema.string,
                "action": Schema.oneOf(MeetingValue.Action.allCases.map(\.rawValue)),
                "suggestion": Schema.string,
            ]),
            "profile": Schema.object([
                "patterns": Schema.array(Schema.object([
                    "name": Schema.string, "kind": Schema.oneOf(["strength", "growth"]),
                    "result": Schema.oneOf(CoachObservation.Result.allCases.map(\.rawValue)), "note": Schema.string,
                    "quote": Schema.string, "at_seconds": Schema.nullableNumber,
                ])),
                "people": Schema.array(Schema.object(["name": Schema.string, "note": Schema.string])),
            ]),
        ])
    }

    /// The most detail points kept per side, for the full review.
    static let detailPoints = 1
    /// The most patterns one call adds an observation to.
    static let patternsPerCall = 4

    public func review(record: CallRecord, profile: CoachProfile, tone: VoiceTone?) async throws -> CoachResult {
        try await review(record: record, profile: profile, tone: tone, people: [], measured: CoachMeasured())
    }

    public func review(record: CallRecord, profile: CoachProfile, tone: VoiceTone?, people: [String]) async throws -> CoachResult {
        try await review(record: record, profile: profile, tone: tone, people: people, measured: CoachMeasured())
    }

    /// The model's notes on one call, as it wrote them. `CoachLineRules.settle` checks them and picks the line.
    public func review(record: CallRecord, profile: CoachProfile, tone: VoiceTone?, people: [String], measured: CoachMeasured) async throws -> CoachResult {
        var delivery = DeliveryStats(record: record, owner: ownerName)
        delivery.tone = tone
        let out = try await llm.json(system: CoachPrompt.system(owner: ownerName, voice: profile.voice),
                                     user: CoachPrompt.user(record: record, owner: ownerName, profile: profile, delivery: delivery, people: people,
                                                            measured: measured),
                                     schema: Self.schema, effort: .high, purpose: .coach, as: Output.self)
        let focus = profile.activeFocus
        var review = CoachReview(headline: out.headline, overview: "", strengths: Array(out.strengths.prefix(Self.detailPoints).map(\.point)),
                                 improvements: Array(out.improvements.prefix(Self.detailPoints).map(\.point)), focusProgress: nil,
                                 value: out.meeting_value, delivery: delivery)
        review.quiet = out.quiet
        review.didWell = out.did_well?.note
        review.tryNext = out.try_next?.note
        if let again = out.seen_again {
            review.seenAgain = CoachNote(text: "", quote: again.quote?.nonBlank, at: again.at_seconds, skill: CoachSkill.id(key: again.skill, label: again.skill_label))
        }
        if let focus, let r = out.focus_result {
            review.focusID = focus.id
            review.focusResult = FocusResult(callID: record.id, date: record.start, outcome: r.outcome, evidence: r.evidence, at: r.at_seconds,
                                             quote: r.quote?.nonBlank)
        }
        let proposal = out.focus_proposal.map { p -> CoachFocus in
            // A focus that the model gave no name is named by its plan: it is one piece of advice, in one wording.
            let id = CoachSkill.id(key: p.skill, label: p.skill_label)
            return CoachFocus(plan: p.plan, why: p.why, metric: p.metric, proposed: record.start, skill: CoachSkill.isNamed(id) ? id : "other:" + AdviceRules.key(p.plan))
        }
        let patterns = out.profile.patterns.prefix(Self.patternsPerCall).map {
            CoachPatternUpdate(name: $0.name, kind: $0.kind, note: $0.note, result: $0.result, quote: $0.quote?.nonBlank, at: $0.at_seconds)
        }
        let update = CoachProfileUpdate(summary: "", focus: "", patterns: Array(patterns), people: out.profile.people)
        let questions = (out.questions ?? []).prefix(2).map {
            CoachQuestion(statement: $0.statement, kind: $0.kind, evidence: $0.evidence, callID: record.id, at: $0.at_seconds, asked: record.end)
        }
        return CoachResult(review: review, update: update, proposal: proposal, questions: Array(questions))
    }

    private struct Note: Decodable {
        let text: String
        let quote, say, skill, skill_label: String?
        let at_seconds: Double?
        var note: CoachNote {
            let id = CoachSkill.id(key: skill, label: skill_label)
            return CoachNote(text: text, quote: quote?.nonBlank, at: at_seconds, say: say?.nonBlank, skill: id, measure: CoachSkill(id: id)?.measure)
        }
    }

    private struct Again: Decodable {
        let skill, skill_label, quote: String?
        let at_seconds: Double?
    }

    private struct Result: Decodable {
        let outcome: FocusOutcome
        let evidence: String
        let quote: String?
        let at_seconds: Double?
    }

    private struct Proposal: Decodable {
        let plan, why: String
        let metric: FocusMetric?
        let skill, skill_label: String?
    }

    private struct PatternOut: Decodable {
        let name, note: String
        let kind: CoachPattern.Kind
        let result: CoachObservation.Result?
        let quote: String?
        let at_seconds: Double?
    }

    private struct ProfileOut: Decodable {
        let patterns: [PatternOut]
        let people: [CoachPersonUpdate]
    }

    private struct Output: Decodable {
        let quiet: Bool
        let headline: String
        let did_well, try_next: Note?
        let seen_again: Again?
        let focus_result: Result?
        let focus_proposal: Proposal?
        let strengths: [Point]
        let improvements: [Point]
        let meeting_value: MeetingValue?
        let profile: ProfileOut
        let questions: [Question]?
    }

    private struct Question: Decodable {
        let statement, evidence: String
        let kind: CoachQuestion.Kind
        let at_seconds: Double?
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
