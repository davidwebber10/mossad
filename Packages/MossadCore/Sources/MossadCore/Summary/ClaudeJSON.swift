import Foundation

/// One Claude Messages API call whose reply is JSON that matches a schema (raw HTTP; there is no Swift SDK).
struct ClaudeJSON: Sendable {
    static let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!

    let apiKey: String
    let model: String
    let session: URLSession
    var usage: UsageLog?
    var purpose: UsageEvent.Purpose

    func call<Output: Decodable>(system: String, user: String, schema: [String: Any], effort: String = "medium",
                                 as: Output.Type) async throws -> Output {
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
            "system": system,
            "output_config": ["effort": effort, "format": ["type": "json_schema", "schema": schema]],
            "messages": [["role": "user", "content": user]],
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw SummaryError.http(status, String(decoding: data.prefix(500), as: UTF8.self))
        }
        let message = try JSONDecoder().decode(Message.self, from: data)
        if let u = message.usage {
            usage?.record(service: .claude, purpose: purpose, model: message.model ?? model, inputTokens: u.input_tokens,
                          outputTokens: u.output_tokens, cacheReadTokens: u.cache_read_input_tokens, cacheWriteTokens: u.cache_creation_input_tokens)
        }
        if message.stop_reason == "refusal" { throw SummaryError.refused }
        guard let text = message.content.first(where: { $0.type == "text" })?.text,
              let result = try? JSONDecoder().decode(Output.self, from: Data(text.utf8)) else {
            throw SummaryError.malformed
        }
        return result
    }

    private struct Message: Decodable {
        let stop_reason: String?
        let content: [Block]
        /// The model that answered; a fallback can differ from the one asked for.
        let model: String?
        let usage: Usage?
    }

    private struct Usage: Decodable {
        let input_tokens: Int?
        let output_tokens: Int?
        let cache_read_input_tokens: Int?
        let cache_creation_input_tokens: Int?
    }

    private struct Block: Decodable {
        let type: String
        let text: String?
    }
}

/// Builders for the JSON schema dictionaries, so each schema reads like its shape.
enum Schema {
    static var string: [String: Any] { ["type": "string"] }
    static var nullableString: [String: Any] { ["anyOf": [["type": "string"], ["type": "null"]]] }
    static func array(_ items: [String: Any]) -> [String: Any] { ["type": "array", "items": items] }
    static func object(_ properties: [String: [String: Any]]) -> [String: Any] {
        ["type": "object", "properties": properties, "required": Array(properties.keys).sorted(), "additionalProperties": false]
    }
    static func oneOf(_ values: [String]) -> [String: Any] { ["type": "string", "enum": values] }
}
