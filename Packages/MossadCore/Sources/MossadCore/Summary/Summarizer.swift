import Foundation

public struct MeetingSummary: Sendable, Equatable {
    /// Markdown: a lead paragraph, then optional `###` sections, `**bold**`, and `-` lists.
    public var summary: String
    public var actionItems: [ActionItem]
    public var decisions: [String]
    public var headline: String?

    public init(summary: String, actionItems: [ActionItem], decisions: [String] = [], headline: String? = nil) {
        self.summary = summary
        self.actionItems = actionItems
        self.decisions = decisions
        self.headline = headline
    }
}

extension CallRecord {
    mutating func apply(_ s: MeetingSummary) {
        summary = s.summary
        actionItems = s.actionItems
        decisions = s.decisions
        headline = s.headline
    }
}

public protocol Summarizing: Sendable {
    func summarize(transcript: String, title: String) async throws -> MeetingSummary
}

/// Writes the summary and action items with the Claude Messages API (raw HTTP; there is no Swift SDK).
public struct ClaudeSummarizer: Summarizing {
    static let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!

    private let apiKey: String
    private let model: String
    private let session: URLSession

    private let ownerName: String
    private let organization: String

    public init(apiKey: String, model: String = "claude-opus-5-5", session: URLSession = .shared,
                ownerName: String = "the user", organization: String = "") {
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
    Write the summary in Markdown: start with a short lead paragraph of 2 to 4 sentences. For a longer meeting, \
    add sections that each start with a "### Heading" line. Use **bold** for key numbers and dates, and "- " \
    bullet lists where a list reads better than prose. Do not use other headings, tables, or links. \
    List every request, commitment, or follow-up as an action item with its owner and the task. Use the speaker \
    names exactly as they appear in the transcript; when the owner is unclear, set the owner to null. Return no \
    action items when there are none. List each decision the meeting made as one short sentence; return no \
    decisions when none were made. Write a headline: one plain sentence of at most 140 characters that says \
    what the meeting was about and its main outcome.
    """

    public func summarize(transcript: String, title: String) async throws -> MeetingSummary {
        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 600
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("server-side-fallback-2026-07-01", forHTTPHeaderField: "anthropic-beta")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        let body: [String: Any] = [
            "model": model,
            "max_tokens": 16_000,
            "fallbacks": "default",
            "system": Self.systemPrompt(owner: ownerName, organization: organization),
            "output_config": [
                "effort": "medium",
                "format": [
                    "type": "json_schema",
                    "schema": [
                        "type": "object",
                        "properties": [
                            "summary": ["type": "string"],
                            "action_items": [
                                "type": "array",
                                "items": [
                                    "type": "object",
                                    "properties": [
                                        "owner": ["anyOf": [["type": "string"], ["type": "null"]]],
                                        "task": ["type": "string"],
                                    ],
                                    "required": ["owner", "task"],
                                    "additionalProperties": false,
                                ] as [String: Any],
                            ] as [String: Any],
                            "decisions": ["type": "array", "items": ["type": "string"]],
                            "headline": ["type": "string"],
                        ] as [String: Any],
                        "required": ["summary", "action_items", "decisions", "headline"],
                        "additionalProperties": false,
                    ],
                ],
            ],
            "messages": [["role": "user", "content": "Meeting: \(title)\n\nTranscript:\n\(transcript)"]],
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw SummaryError.http(status, String(decoding: data.prefix(500), as: UTF8.self))
        }
        let message = try JSONDecoder().decode(Message.self, from: data)
        if message.stop_reason == "refusal" { throw SummaryError.refused }
        guard let text = message.content.first(where: { $0.type == "text" })?.text,
              let result = try? JSONDecoder().decode(Output.self, from: Data(text.utf8)) else {
            throw SummaryError.malformed
        }
        let headline = result.headline.trimmingCharacters(in: .whitespacesAndNewlines)
        return MeetingSummary(summary: result.summary, actionItems: result.action_items, decisions: result.decisions,
                              headline: headline.isEmpty ? nil : headline)
    }

    private struct Message: Decodable {
        let stop_reason: String?
        let content: [Block]
    }

    private struct Block: Decodable {
        let type: String
        let text: String?
    }

    private struct Output: Decodable {
        let summary: String
        let action_items: [ActionItem]
        let decisions: [String]
        let headline: String
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
