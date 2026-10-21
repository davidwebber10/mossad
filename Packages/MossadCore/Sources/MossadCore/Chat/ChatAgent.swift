import Foundation

/// A link in an answer to a meeting, and to a moment in it: `mossad://call/<call_id>?t=<seconds>`.
public struct ChatLink: Equatable, Sendable {
    public var callID: String
    public var at: TimeInterval?

    public static func parse(_ url: URL) -> ChatLink? {
        guard url.scheme == "mossad", url.host == "call" else { return nil }
        let id = url.pathComponents.dropFirst().first ?? ""
        guard !id.isEmpty else { return nil }
        let t = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "t" }?.value.flatMap(Double.init)
        return ChatLink(callID: id, at: t)
    }
}

public enum ChatError: Error, CustomStringConvertible {
    case tooManySteps

    public var description: String { "Claude looked up too many things without an answer. Try a narrower question." }
}

/// Answers one chat message with Claude and the meeting tools: Claude decides what to look up, Mossad runs each
/// lookup on this Mac, and the loop ends when Claude answers. Earlier turns go in as plain text.
public struct ChatAgent: Sendable {
    static let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!
    static let maxRounds = 12

    private let apiKey: String
    private let model: String
    private let session: URLSession
    private let ownerName: String
    private let usage: UsageLog?

    public init(apiKey: String, model: String = "claude-opus-5-5", session: URLSession = .shared, ownerName: String, usage: UsageLog? = nil) {
        self.apiKey = apiKey
        self.model = model
        self.session = session
        self.ownerName = ownerName
        self.usage = usage
    }

    static func system(owner: String, tools: ChatTools, now: Date) -> String {
        let dates = tools.records.isEmpty ? "none yet"
            : "\(tools.records.count) meetings from \(tools.records.last!.start.formatted(date: .abbreviated, time: .omitted)) to \(tools.records.first!.start.formatted(date: .abbreviated, time: .omitted))"
        return """
        You are \(owner)'s assistant for their recorded meetings: Zoom, Google Meet, and Microsoft Teams calls with \
        transcripts, summaries, decisions, and action items. Today is \(now.formatted(.dateTime.weekday(.wide).year().month(.wide).day().hour().minute())). \
        The archive holds \(dates). People in the meetings, most frequent first: \(tools.knownPeople.prefix(150).joined(separator: ", ")). \
        Tags: \(Tags.known(tools.records).joined(separator: ", ")).

        Use the tools to find the facts; never answer from memory or guess. Find the right meetings first (by person, \
        date, tag, or words), then read the ones that matter. Before you say what someone said, agreed to, decided, or \
        committed to, read that meeting's transcript; summaries can miss details and deadlines. "Last call" with \
        someone means the most recent meeting they were in. Resolve relative dates ("last week", "Tuesday") \
        against today's date. Look again with other words or names when a search finds nothing, then say plainly \
        what you could not find.

        Answer directly, then the details. Name who said or committed to what, and any deadline; say clearly \
        when no deadline was set. Use **bold** for names, dates, numbers, and commitments. Use short "- " lists for \
        several items. Keep it tight: no preamble, no restating the question. Give absolute dates (Oct 21), not only \
        relative ones. Link every meeting you mention as [Title, Oct 21](mossad://call/<call_id>) and each moment \
        you quote as [12:40](mossad://call/<call_id>?t=760), where t is the line's time in seconds. Transcripts come \
        from speech recognition, so names and numbers can be misspelled; prefer the spelling in the people list.
        """
    }

    /// `onStep` reports each lookup as it starts, for the "Reading Launch sync" line.
    public func answer(_ question: String, history: [ChatMessage], records: [CallRecord], now: Date = Date(),
                       onStep: @escaping @Sendable (String) -> Void) async throws -> String {
        let tools = ChatTools(records: records, owner: ownerName)
        var messages: [[String: Any]] = history.map { ["role": $0.role.rawValue, "content": $0.text] }
        messages.append(["role": "user", "content": question])
        let system = Self.system(owner: ownerName, tools: tools, now: now)
        for _ in 0..<Self.maxRounds {
            let reply = try await send(system: system, messages: messages)
            let content = reply["content"] as? [[String: Any]] ?? []
            if reply["stop_reason"] as? String == "refusal" { throw SummaryError.refused }
            let calls = content.filter { $0["type"] as? String == "tool_use" }
            guard reply["stop_reason"] as? String == "tool_use", !calls.isEmpty else {
                return content.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }.joined(separator: "\n\n")
            }
            // The assistant turn goes back exactly as sent: its thinking must stay with it.
            messages.append(["role": "assistant", "content": content])
            let results: [[String: Any]] = calls.map { call in
                let name = call["name"] as? String ?? "", input = call["input"] as? [String: Any] ?? [:]
                onStep(ChatTools.step(name, input: input) { id in tools.records.first { $0.id == id }?.title })
                return ["type": "tool_result", "tool_use_id": call["id"] as? String ?? "", "content": tools.run(name, input: input)]
            }
            messages.append(["role": "user", "content": results])
        }
        throw ChatError.tooManySteps
    }

    private func send(system: String, messages: [[String: Any]]) async throws -> [String: Any] {
        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 600
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("server-side-fallback-2026-07-01", forHTTPHeaderField: "anthropic-beta")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": model, "max_tokens": 16_000, "fallbacks": "default", "system": system,
            "output_config": ["effort": "medium"], "tools": ChatTools.definitions, "messages": messages,
        ] as [String: Any])
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else { throw SummaryError.http(status, String(decoding: data.prefix(500), as: UTF8.self)) }
        guard let reply = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw SummaryError.malformed }
        if let u = reply["usage"] as? [String: Any] {
            usage?.record(service: .claude, purpose: .question, model: reply["model"] as? String ?? model,
                          inputTokens: u["input_tokens"] as? Int, outputTokens: u["output_tokens"] as? Int,
                          cacheReadTokens: u["cache_read_input_tokens"] as? Int, cacheWriteTokens: u["cache_creation_input_tokens"] as? Int)
        }
        return reply
    }
}
