import Foundation

/// OpenAI through the Responses API. Nothing is stored at OpenAI (`store: false`); reasoning comes back
/// encrypted and is sent back during a tool loop, as OpenAI requires.
public struct OpenAIModel: LanguageModel {
    static let endpoint = URL(string: "https://api.openai.com/v1/responses")!
    static let maxRounds = 12
    /// OpenAI suggests room for at least 25k tokens, since reasoning counts toward the limit.
    static let maxOutputTokens = 32_000

    private let apiKey: String
    private let model: String
    private let session: URLSession
    private let usage: UsageLog?

    public init(apiKey: String, model: String, session: URLSession = .shared, usage: UsageLog? = nil) {
        self.apiKey = apiKey
        self.model = model
        self.session = session
        self.usage = usage
    }

    private func send(_ body: [String: Any], purpose: UsageEvent.Purpose) async throws -> [String: Any] {
        var body = body
        body["model"] = model
        body["store"] = false
        body["max_output_tokens"] = Self.maxOutputTokens
        let reply: [String: Any]
        do {
            reply = try await postJSON(Self.endpoint, headers: ["Authorization": "Bearer \(apiKey)"], body: body, session: session)
        } catch SummaryError.http(let code, let text) {
            throw ProviderError.http("OpenAI", code, text)
        }
        if let u = reply["usage"] as? [String: Any] {
            let cached = (u["input_tokens_details"] as? [String: Any])?["cached_tokens"] as? Int ?? 0
            usage?.record(service: .openai, purpose: purpose, model: reply["model"] as? String ?? model,
                          inputTokens: (u["input_tokens"] as? Int).map { $0 - cached }, outputTokens: u["output_tokens"] as? Int,
                          cacheReadTokens: cached)
        }
        if reply["status"] as? String == "incomplete" { throw ProviderError.failed("OpenAI", "the reply was cut off before it finished") }
        return reply
    }

    private static func output(_ reply: [String: Any]) -> [[String: Any]] { reply["output"] as? [[String: Any]] ?? [] }

    private static func text(_ reply: [String: Any]) throws -> String {
        let parts = output(reply).filter { $0["type"] as? String == "message" }.flatMap { $0["content"] as? [[String: Any]] ?? [] }
        if parts.contains(where: { $0["type"] as? String == "refusal" }) { throw SummaryError.refused }
        return parts.compactMap { $0["type"] as? String == "output_text" ? $0["text"] as? String : nil }.joined(separator: "\n\n")
    }

    public func json<Output: Decodable>(system: String, user: String, schema: [String: Any], effort: Effort,
                                        purpose: UsageEvent.Purpose, as: Output.Type) async throws -> Output {
        let reply = try await send([
            "instructions": system,
            "input": user,
            "reasoning": ["effort": effort.rawValue],
            "text": ["format": ["type": "json_schema", "name": "output", "strict": true, "schema": schema]],
        ], purpose: purpose)
        return try decodeOutput(try Self.text(reply), as: Output.self)
    }

    public func runTools(system: String, history: [ChatMessage], question: String, tools: [ToolSpec], purpose: UsageEvent.Purpose,
                         execute: @escaping @Sendable (String, [String: Any]) -> String) async throws -> String {
        var input: [[String: Any]] = history.map { ["role": $0.role.rawValue, "content": $0.text] }
        input.append(["role": "user", "content": question])
        let definitions = tools.map {
            ["type": "function", "name": $0.name, "description": $0.description, "parameters": $0.schema, "strict": false] as [String: Any]
        }
        for _ in 0..<Self.maxRounds {
            // Instructions apply to one request only, so they go with every round.
            let reply = try await send(["instructions": system, "input": input, "tools": definitions, "reasoning": ["effort": "medium"],
                                        "include": ["reasoning.encrypted_content"]], purpose: purpose)
            let items = Self.output(reply)
            let calls = items.filter { $0["type"] as? String == "function_call" }
            guard !calls.isEmpty else { return try Self.text(reply) }
            input += items
            input += calls.map { call in
                let arguments = (call["arguments"] as? String).flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) } as? [String: Any] ?? [:]
                return ["type": "function_call_output", "call_id": call["call_id"] as? String ?? "",
                        "output": execute(call["name"] as? String ?? "", arguments)]
            }
        }
        throw ChatError.tooManySteps
    }
}
