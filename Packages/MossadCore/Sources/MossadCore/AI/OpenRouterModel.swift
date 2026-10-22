import Foundation

/// Any model on OpenRouter, through its OpenAI-style chat completions. Requests go only to endpoints that
/// support every parameter sent, and each reply carries what OpenRouter charged.
public struct OpenRouterModel: LanguageModel {
    static let endpoint = URL(string: "https://openrouter.ai/api/v1/chat/completions")!
    static let maxRounds = 12

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
        body["provider"] = ["require_parameters": true]
        let reply: [String: Any]
        do {
            reply = try await postJSON(Self.endpoint, headers: ["Authorization": "Bearer \(apiKey)", "HTTP-Referer": "https://github.com/davidwebber10/mossad",
                                                                "X-OpenRouter-Title": "Mossad"], body: body, session: session)
        } catch SummaryError.http(let code, let text) {
            throw ProviderError.http("OpenRouter", code, text)
        }
        if let u = reply["usage"] as? [String: Any] {
            let cached = (u["prompt_tokens_details"] as? [String: Any])?["cached_tokens"] as? Int ?? 0
            usage?.record(service: .openrouter, purpose: purpose, model: reply["model"] as? String ?? model,
                          inputTokens: (u["prompt_tokens"] as? Int).map { $0 - cached }, outputTokens: u["completion_tokens"] as? Int,
                          cacheReadTokens: cached, costUSD: u["cost"] as? Double)
        }
        return reply
    }

    private static func choice(_ reply: [String: Any]) throws -> (message: [String: Any], finish: String?) {
        guard let c = (reply["choices"] as? [[String: Any]])?.first, let message = c["message"] as? [String: Any] else {
            throw ProviderError.failed("OpenRouter", (reply["error"] as? [String: Any])?["message"] as? String ?? "the reply had no message")
        }
        if let refusal = message["refusal"] as? String, !refusal.isEmpty { throw SummaryError.refused }
        if c["finish_reason"] as? String == "length" { throw ProviderError.failed("OpenRouter", "the reply was cut off before it finished") }
        return (message, c["finish_reason"] as? String)
    }

    public func json<Output: Decodable>(system: String, user: String, schema: [String: Any], effort: Effort,
                                        purpose: UsageEvent.Purpose, as: Output.Type) async throws -> Output {
        let reply = try await send([
            "messages": [["role": "system", "content": system], ["role": "user", "content": user]],
            "response_format": ["type": "json_schema", "json_schema": ["name": "output", "strict": true, "schema": schema]],
            "reasoning": ["effort": effort.rawValue],
        ], purpose: purpose)
        return try decodeOutput(try Self.choice(reply).message["content"] as? String, as: Output.self)
    }

    public func runTools(system: String, history: [ChatMessage], question: String, tools: [ToolSpec], purpose: UsageEvent.Purpose,
                         execute: @escaping @Sendable (String, [String: Any]) -> String) async throws -> String {
        var messages: [[String: Any]] = [["role": "system", "content": system]]
        messages += history.map { ["role": $0.role.rawValue, "content": $0.text] }
        messages.append(["role": "user", "content": question])
        let definitions = tools.map {
            ["type": "function", "function": ["name": $0.name, "description": $0.description, "parameters": $0.schema] as [String: Any]] as [String: Any]
        }
        for _ in 0..<Self.maxRounds {
            // Tools go with every request; the assistant turn, reasoning included, goes back unchanged.
            let reply = try await send(["messages": messages, "tools": definitions, "reasoning": ["effort": "medium"]], purpose: purpose)
            let (message, _) = try Self.choice(reply)
            let calls = message["tool_calls"] as? [[String: Any]] ?? []
            guard !calls.isEmpty else { return message["content"] as? String ?? "" }
            messages.append(message)
            messages += calls.map { call in
                let function = call["function"] as? [String: Any] ?? [:]
                let arguments = (function["arguments"] as? String).flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) } as? [String: Any] ?? [:]
                return ["role": "tool", "tool_call_id": call["id"] as? String ?? "", "content": execute(function["name"] as? String ?? "", arguments)]
            }
        }
        throw ChatError.tooManySteps
    }
}
