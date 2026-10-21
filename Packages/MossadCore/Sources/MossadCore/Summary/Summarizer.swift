import Foundation

public struct MeetingSummary: Sendable, Equatable {
    public var summary: String
    public var actionItems: [String]
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

    public init(apiKey: String, model: String = "claude-opus-5-5", session: URLSession = .shared) {
        self.apiKey = apiKey
        self.model = model
        self.session = session
    }

    static let system = """
    You summarize internal POLYWOOD meeting transcripts for David Webber. The summary is read later by David \
    and by AI agents that act on it, so be concrete: decisions, numbers, dates, owners, and open questions. \
    Write the summary as 3 to 8 short sentences. List every request, commitment, or follow-up as an action item \
    in the form "Owner: task". Use the speaker names exactly as they appear in the transcript; when the owner \
    is unclear, write "Unassigned". Return no action items when there are none.
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
            "system": Self.system,
            "output_config": [
                "effort": "medium",
                "format": [
                    "type": "json_schema",
                    "schema": [
                        "type": "object",
                        "properties": [
                            "summary": ["type": "string"],
                            "action_items": ["type": "array", "items": ["type": "string"]],
                        ],
                        "required": ["summary", "action_items"],
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
        return MeetingSummary(summary: result.summary, actionItems: result.action_items)
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
        let action_items: [String]
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
