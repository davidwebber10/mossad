import Foundation

/// One subject of a longer meeting, shown collapsed under the overview.
public struct SummaryTopic: Codable, Equatable, Sendable, Hashable {
    public var title: String
    /// Short Markdown: a few sentences or a `-` list, `**bold**` for key numbers and dates.
    public var summary: String

    public init(title: String, summary: String) {
        self.title = title
        self.summary = summary
    }
}

public struct MeetingSummary: Sendable, Equatable {
    /// The overview: 3 to 4 sentences on what the call was. Older records hold longer Markdown.
    public var summary: String
    public var topics: [SummaryTopic]
    public var actionItems: [ActionItem]
    public var decisions: [Decision]
    public var headline: String?
    /// What sort of meeting this was, in 1 to 3 words ("Monthly update", "Working session").
    public var kind: String?
    /// Whether the meeting is the kind that makes decisions or assigns work; an update call is not.
    public var hasOutcomes: Bool?
    public var tags: [String]
    /// At most 60 characters; names the topic and, for a small meeting, who it was with.
    public var title: String?

    public init(summary: String, topics: [SummaryTopic] = [], actionItems: [ActionItem], decisions: [Decision] = [], headline: String? = nil,
                kind: String? = nil, hasOutcomes: Bool? = nil, tags: [String] = [], title: String? = nil) {
        self.title = title
        self.tags = tags
        self.summary = summary
        self.topics = topics
        self.actionItems = actionItems
        self.decisions = decisions
        self.headline = headline
        self.kind = kind
        self.hasOutcomes = hasOutcomes
    }
}

extension CallRecord {
    mutating func apply(_ s: MeetingSummary) {
        summary = s.summary
        topics = s.topics
        actionItems = s.actionItems
        // A time past the end of the call is a misread stamp.
        let length = end.timeIntervalSince(start)
        decisions = s.decisions.map { Decision(text: $0.text, at: $0.at.flatMap { $0 <= length ? $0 : nil }) }
        headline = s.headline
        kind = s.kind
        hasOutcomes = s.hasOutcomes
        summaryVersion = SummaryBackfill.currentVersion
        if tagsSetByOwner != true { tags = s.tags }
        // A summary without a title must not erase the live guess.
        if let title = s.title { generatedTitle = title }
    }
}

public protocol Summarizing: Sendable {
    /// `knownTags` are the tags of earlier meetings, so the same topic keeps one spelling.
    func summarize(transcript: String, title: String, knownTags: [String]) async throws -> MeetingSummary
    /// `people` are "Name, Title" lines for speakers found in the org chart.
    func summarize(transcript: String, title: String, knownTags: [String], people: [String]) async throws -> MeetingSummary
}

extension Summarizing {
    public func summarize(transcript: String, title: String, knownTags: [String], people: [String]) async throws -> MeetingSummary {
        try await summarize(transcript: transcript, title: title, knownTags: knownTags)
    }

    public func summarize(transcript: String, title: String) async throws -> MeetingSummary {
        try await summarize(transcript: transcript, title: title, knownTags: [])
    }
}

/// Writes the summary, action items, and tags with the chosen AI model.
public struct LLMSummarizer: Summarizing {
    private let llm: any LanguageModel
    private let ownerName: String
    private let organization: String

    public init(llm: any LanguageModel, ownerName: String = "the user", organization: String = "") {
        self.llm = llm
        self.ownerName = ownerName
        self.organization = organization
    }

    public init(apiKey: String, model: String = "claude-opus-5-5", session: URLSession = .shared,
                ownerName: String = "the user", organization: String = "", usage: UsageLog? = nil) {
        self.init(llm: AnthropicModel(apiKey: apiKey, model: model, session: session, usage: usage), ownerName: ownerName, organization: organization)
    }

    static func systemPrompt(owner: String, organization: String) -> String {
        let source = organization.isEmpty ? "meeting transcripts" : "internal \(organization) meeting transcripts"
        return "You summarize \(source) for \(owner). The summary is read later by \(owner) " + rules
    }

    static let rules = """
    and by AI agents that act on it, so be concrete: decisions, numbers, dates, owners, and open questions. \
    The summary is an overview a person reads in ten seconds: 3 to 4 plain sentences on what the call was, who it \
    was with, and its main outcome. No headings, no lists, no details that belong in a topic. Put the details in \
    topics: none for a short or simple call, otherwise 2 to 6, one per subject that was discussed, in the order \
    they came up. Each topic has a title of 2 to 6 words and a summary of 2 to 5 sentences or a short "- " list. \
    Use **bold** for key numbers and dates. Do not use headings, tables, or links inside a topic. \
    List every request, commitment, or follow-up as an action item with its owner and the task. Use the speaker \
    names exactly as they appear in the transcript; when the owner is unclear, set the owner to null. Return no \
    action items when there are none. List each decision the meeting made as one short sentence; return no \
    decisions when none were made. Give each decision at_seconds: the second of the call when it was made, read from the \
    [HH:MM:SS] stamp of the line where it was agreed (null when you cannot tell). Write a headline: one plain \
    sentence of at most 140 characters that says \
    what the meeting was about and its main outcome. Name the kind of meeting in 1 to 3 words, such as \
    "Monthly update", "Working session", "Planning", "1:1", or "Interview". Set has_outcomes to false for a \
    meeting that only shares information (an update, a demo, a briefing) and made no decisions and assigned no \
    work; then return no action items and no decisions. Give 2 to 5 tags: short topic labels of 1 to 3 words in \
    Title Case for the projects, systems, vendors, and themes the meeting was about, such as "Databricks", \
    "Budget", or "Hiring". Use a known tag, with its exact spelling, whenever it fits; make a new one only for a new \
    topic. Do not use people's names or the meeting kind as tags. A line such as "(★ Bookmarked at 2:31 PM)" marks a \
    moment the owner flagged as important during the call: make sure the summary covers what was said around it. \
    A note after the time, such as "(★ Bookmarked at 2:31 PM: Ask Dana about budget)", is the owner's own words \
    about that moment; use it. \
    Write a title of at most 60 characters that names the topic; for a meeting of two or three people, add who it \
    was with, by first name.
    """

    public func summarize(transcript: String, title: String, knownTags: [String]) async throws -> MeetingSummary {
        try await summarize(transcript: transcript, title: title, knownTags: knownTags, people: [])
    }

    static func userPrompt(knownTags: [String], title: String, transcript: String, people: [String]) -> String {
        let known = knownTags.isEmpty ? "" : "Known tags: \(knownTags.joined(separator: ", "))\n\n"
        let titles = people.isEmpty ? "" : "Job titles of people in the meeting:\n" + people.map { "- \($0)" }.joined(separator: "\n") + "\n\n"
        return "\(known)\(titles)Meeting: \(title)\n\nTranscript:\n\(transcript)"
    }

    /// The shape of every summary, from any model, in one request or in parts.
    static var schema: [String: Any] {
        Schema.object([
            "summary": Schema.string,
            "topics": Schema.array(Schema.object(["title": Schema.string, "summary": Schema.string])),
            "action_items": Schema.array(Schema.object(["owner": Schema.nullableString, "task": Schema.string])),
            "decisions": Schema.array(Schema.object(["text": Schema.string, "at_seconds": Schema.nullableNumber])),
            "headline": Schema.string,
            "kind": Schema.string,
            "has_outcomes": ["type": "boolean"],
            "tags": Schema.array(Schema.string),
            "title": Schema.string,
        ])
    }

    public func summarize(transcript: String, title: String, knownTags: [String], people: [String]) async throws -> MeetingSummary {
        let system = Self.systemPrompt(owner: ownerName, organization: organization)
        let result: Output
        if let small = llm as? any ContextLimitedModel {
            result = try await summarizeInParts(small, system: system, transcript: transcript, title: title, knownTags: knownTags, people: people)
        } else {
            result = try await llm.json(system: system,
                                        user: Self.userPrompt(knownTags: knownTags, title: title, transcript: transcript, people: people), schema: Self.schema,
                                        effort: .medium, purpose: .summary, as: Output.self)
        }
        let headline = result.headline.trimmingCharacters(in: .whitespacesAndNewlines)
        return MeetingSummary(summary: result.summary, topics: result.topics, actionItems: result.action_items, decisions: result.decisions.map { Decision(text: $0.text, at: $0.at_seconds.flatMap { $0 >= 0 ? $0 : nil }) },
                              headline: headline.isEmpty ? nil : headline,
                              kind: result.kind.isEmpty ? nil : result.kind, hasOutcomes: result.has_outcomes,
                              tags: (result.tags ?? []).compactMap(\.nonBlank), title: result.title?.nonBlank.map(Titles.clean))
    }

    struct DecisionOutput: Decodable {
        let text: String
        let at_seconds: Double?
    }

    struct Output: Decodable {
        let summary: String
        let topics: [SummaryTopic]
        let action_items: [ActionItem]
        let decisions: [DecisionOutput]
        let headline: String
        let kind: String
        let has_outcomes: Bool
        let tags: [String]?
        let title: String?
    }
}

public enum SummaryError: Error, CustomStringConvertible {
    case http(Int, String)
    case refused
    case malformed

    public var description: String {
        switch self {
        case .http(let code, let body): "Claude HTTP \(code): \(body)"
        case .refused: "Claude refused to summarize this transcript"
        case .malformed: "Claude returned a reply that is not the expected JSON"
        }
    }
}
