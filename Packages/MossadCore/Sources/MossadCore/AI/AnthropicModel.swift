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
        body["fallbacks"] = "default"
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
        let reply = try await send([
            "system": system,
            "output_config": ["effort": effort.rawValue, "format": ["type": "json_schema", "schema": schema]],
            "messages": [["role": "user", "content": user]],
        ], purpose: purpose)
        return try decodeOutput(Self.text(reply), as: Output.self)
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
