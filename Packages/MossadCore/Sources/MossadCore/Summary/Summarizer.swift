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
    public var decisions: [String]
    public var headline: String?
    /// What sort of meeting this was, in 1 to 3 words ("Monthly update", "Working session").
    public var kind: String?
    /// Whether the meeting is the kind that makes decisions or assigns work; an update call is not.
    public var hasOutcomes: Bool?
    public var tags: [String]

    public init(summary: String, topics: [SummaryTopic] = [], actionItems: [ActionItem], decisions: [String] = [], headline: String? = nil,
                kind: String? = nil, hasOutcomes: Bool? = nil, tags: [String] = []) {
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
        decisions = s.decisions
        headline = s.headline
        kind = s.kind
        hasOutcomes = s.hasOutcomes
        tags = s.tags
    }
}

public protocol Summarizing: Sendable {
    /// `knownTags` are the tags of earlier meetings, so the same topic keeps one spelling.
    func summarize(transcript: String, title: String, knownTags: [String]) async throws -> MeetingSummary
}

extension Summarizing {
    public func summarize(transcript: String, title: String) async throws -> MeetingSummary {
        try await summarize(transcript: transcript, title: title, knownTags: [])
    }
}

/// Writes the summary and action items with the Claude Messages API (raw HTTP; there is no Swift SDK).
public struct ClaudeSummarizer: Summarizing {
    private let apiKey: String
    private let model: String
    private let session: URLSession

    private let ownerName: String
    private let organization: String
    private let usage: UsageLog?

    public init(apiKey: String, model: String = "claude-opus-5-5", session: URLSession = .shared,
                ownerName: String = "the user", organization: String = "", usage: UsageLog? = nil) {
        self.usage = usage
        self.ownerName = ownerName
        self.organization = organization
        self.apiKey = apiKey
        self.model = model
        self.session = session
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
    decisions when none were made. Write a headline: one plain sentence of at most 140 characters that says \
    what the meeting was about and its main outcome. Name the kind of meeting in 1 to 3 words, such as \
    "Monthly update", "Working session", "Planning", "1:1", or "Interview". Set has_outcomes to false for a \
    meeting that only shares information (an update, a demo, a briefing) and made no decisions and assigned no \
    work; then return no action items and no decisions. Give 2 to 5 tags: short topic labels of 1 to 3 words in \
    Title Case for the projects, systems, vendors, and themes the meeting was about, such as "Databricks", \
    "Budget", or "Hiring". Use a known tag, with its exact spelling, whenever it fits; make a new one only for a new \
    topic. Do not use people's names or the meeting kind as tags. A line such as "(★ Bookmarked at 2:31 PM)" marks a \
    moment the owner flagged as important during the call: make sure the summary covers what was said around it.
    """

    public func summarize(transcript: String, title: String, knownTags: [String]) async throws -> MeetingSummary {
        let schema = Schema.object([
            "summary": Schema.string,
            "topics": Schema.array(Schema.object(["title": Schema.string, "summary": Schema.string])),
            "action_items": Schema.array(Schema.object(["owner": Schema.nullableString, "task": Schema.string])),
            "decisions": Schema.array(Schema.string),
            "headline": Schema.string,
            "kind": Schema.string,
            "has_outcomes": ["type": "boolean"],
            "tags": Schema.array(Schema.string),
        ])
        let known = knownTags.isEmpty ? "" : "Known tags: \(knownTags.joined(separator: ", "))\n\n"
        let result = try await ClaudeJSON(apiKey: apiKey, model: model, session: session, usage: usage, purpose: .summary)
            .call(system: Self.systemPrompt(owner: ownerName, organization: organization),
                  user: "\(known)Meeting: \(title)\n\nTranscript:\n\(transcript)", schema: schema, as: Output.self)
        let headline = result.headline.trimmingCharacters(in: .whitespacesAndNewlines)
        return MeetingSummary(summary: result.summary, topics: result.topics, actionItems: result.action_items, decisions: result.decisions,
                              headline: headline.isEmpty ? nil : headline,
                              kind: result.kind.isEmpty ? nil : result.kind, hasOutcomes: result.has_outcomes,
                              tags: (result.tags ?? []).compactMap(\.nonBlank))
    }

    private struct Output: Decodable {
        let summary: String
        let topics: [SummaryTopic]
        let action_items: [ActionItem]
        let decisions: [String]
        let headline: String
        let kind: String
        let has_outcomes: Bool
        let tags: [String]?
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
