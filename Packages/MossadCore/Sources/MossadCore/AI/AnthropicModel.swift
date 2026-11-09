import Foundation

/// Claude through the Anthropic Messages API (raw HTTP; there is no Swift SDK).
public struct AnthropicModel: LanguageModel {
    static let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!
    static let maxRounds = 12

    private let apiKey: String
    private let model: String
    private let session: URLSession
    private let usage: UsageLog?

    public init(apiKey: String, model: String = "claude-opus-5-5", session: URLSession = .shared, usage: UsageLog? = nil) {
        self.apiKey = apiKey
        self.model = model
        self.session = session
        self.usage = usage
    }

    private var headers: [String: String] {
        ["x-api-key": apiKey, "anthropic-version": "2023-06-01", "anthropic-beta": "server-side-fallback-2026-07-01"]
    }

    private func send(_ body: [String: Any], purpose: UsageEvent.Purpose) async throws -> [String: Any] {
        var body = body
        body["model"] = model
        body["max_tokens"] = 16_000
        // Haiku has no server-side fallback, so the field is left out for it.
        if !model.hasPrefix("claude-haiku") { body["fallbacks"] = "default" }
        let reply = try await postJSON(Self.endpoint, headers: headers, body: body, session: session)
        if let u = reply["usage"] as? [String: Any] {
            usage?.record(service: .claude, purpose: purpose, model: reply["model"] as? String ?? model,
                          inputTokens: u["input_tokens"] as? Int, outputTokens: u["output_tokens"] as? Int,
                          cacheReadTokens: u["cache_read_input_tokens"] as? Int, cacheWriteTokens: u["cache_creation_input_tokens"] as? Int)
        }
        if reply["stop_reason"] as? String == "refusal" { throw SummaryError.refused }
        return reply
    }

    private static func text(_ reply: [String: Any]) -> String {
        (reply["content"] as? [[String: Any]] ?? []).compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }
            .joined(separator: "\n\n")
    }

    public func json<Output: Decodable>(system: String, user: String, schema: [String: Any], effort: Effort,
                                        purpose: UsageEvent.Purpose, as: Output.Type) async throws -> Output {
        do {
            let reply = try await send([
                "system": system,
                "output_config": ["effort": effort.rawValue, "format": ["type": "json_schema", "schema": schema]],
                "messages": [["role": "user", "content": user]],
            ], purpose: purpose)
            try Self.checkComplete(reply)
            return try decodeOutput(Self.text(reply), as: Output.self)
        } catch SummaryError.http(400, let body) where body.contains("grammar is too large") {
            // Claude can refuse a large strict schema; the same schema in the instructions still gets valid JSON.
            Log.info("Claude refused the strict schema as too large; asking with the schema in the instructions")
            let data = try JSONSerialization.data(withJSONObject: schema, options: [.sortedKeys])
            let reply = try await send([
                "system": system + "\n\nReply with one JSON object and nothing else. It must match this JSON Schema exactly:\n"
                    + String(decoding: data, as: UTF8.self),
                "output_config": ["effort": effort.rawValue],
                "messages": [["role": "user", "content": user]],
            ], purpose: purpose)
            try Self.checkComplete(reply)
            return try decodeOutput(Self.jsonObject(in: Self.text(reply)), as: Output.self)
        }
    }

    /// A reply cut at the token limit is not JSON. Say what happened, so it does not read as a random bad reply.
    static func checkComplete(_ reply: [String: Any]) throws {
        if reply["stop_reason"] as? String == "max_tokens" { throw SummaryError.cutOff }
    }

    /// The JSON object in a reply, without a code fence or words around it.
    static func jsonObject(in text: String) -> String {
        guard let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}"), start < end else { return text }
        return String(text[start...end])
    }

    public func runTools(system: String, history: [ChatMessage], question: String, tools: [ToolSpec], purpose: UsageEvent.Purpose,
                         execute: @escaping @Sendable (String, [String: Any]) -> String) async throws -> String {
        var messages: [[String: Any]] = history.map { ["role": $0.role.rawValue, "content": $0.text] }
        messages.append(["role": "user", "content": question])
        let definitions = tools.map { ["name": $0.name, "description": $0.description, "input_schema": $0.schema] as [String: Any] }
        for _ in 0..<Self.maxRounds {
            let reply = try await send(["system": system, "output_config": ["effort": "medium"], "tools": definitions, "messages": messages],
                                       purpose: purpose)
            let content = reply["content"] as? [[String: Any]] ?? []
            let calls = content.filter { $0["type"] as? String == "tool_use" }
            guard reply["stop_reason"] as? String == "tool_use", !calls.isEmpty else { return Self.text(reply) }
            // The assistant turn goes back exactly as sent: its thinking must stay with it.
            messages.append(["role": "assistant", "content": content])
            messages.append(["role": "user", "content": calls.map { call in
                ["type": "tool_result", "tool_use_id": call["id"] as? String ?? "",
                 "content": execute(call["name"] as? String ?? "", call["input"] as? [String: Any] ?? [:])]
            }])
        }
        throw ChatError.tooManySteps
    }
}
