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

    /// The same request as `send`, streamed: `onText` gets the reply's text so far after each piece.
    private func sendStreaming(_ body: [String: Any], purpose: UsageEvent.Purpose, onText: @Sendable (String) -> Void) async throws -> [String: Any] {
        var body = body
        body["model"] = model
        body["max_tokens"] = 16_000
        body["stream"] = true
        if !model.hasPrefix("claude-haiku") { body["fallbacks"] = "default" }
        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 600
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        for (k, v) in headers { request.setValue(v, forHTTPHeaderField: k) }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (bytes, response) = try await session.bytes(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            var data = Data()
            for try await byte in bytes {
                data.append(byte)
                if data.count >= 500 { break }
            }
            throw SummaryError.http(status, data.snippet)
        }
        var stream = AnthropicStream()
        for try await line in bytes.lines {
            if let text = try stream.feed(line: line) { onText(text) }
        }
        let reply = stream.reply
        if let u = reply["usage"] as? [String: Any] {
            usage?.record(service: .claude, purpose: purpose, model: reply["model"] as? String ?? model,
                          inputTokens: u["input_tokens"] as? Int, outputTokens: u["output_tokens"] as? Int,
                          cacheReadTokens: u["cache_read_input_tokens"] as? Int, cacheWriteTokens: u["cache_creation_input_tokens"] as? Int)
        }
        // A stream cut before its end has no stop reason: its text is not a whole answer.
        guard let stop = reply["stop_reason"] as? String else { throw SummaryError.cutOff }
        if stop == "refusal" { throw SummaryError.refused }
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

    public func streamTools(system: String, history: [ChatMessage], question: String, tools: [ToolSpec], purpose: UsageEvent.Purpose,
                            execute: @escaping @Sendable (String, [String: Any]) -> String,
                            onText: @escaping @Sendable (String) -> Void) async throws -> String {
        var messages: [[String: Any]] = history.map { ["role": $0.role.rawValue, "content": $0.text] }
        messages.append(["role": "user", "content": question])
        let definitions = tools.map { ["name": $0.name, "description": $0.description, "input_schema": $0.schema] as [String: Any] }
        for _ in 0..<Self.maxRounds {
            var body: [String: Any] = ["system": system, "output_config": ["effort": "low"], "messages": messages]
            if !definitions.isEmpty { body["tools"] = definitions }
            let reply = try await sendStreaming(body, purpose: purpose, onText: onText)
            let content = reply["content"] as? [[String: Any]] ?? []
            let calls = content.filter { $0["type"] as? String == "tool_use" }
            guard reply["stop_reason"] as? String == "tool_use", !calls.isEmpty else { return Self.text(reply) }
            messages.append(["role": "assistant", "content": content])
            messages.append(["role": "user", "content": calls.map { call in
                ["type": "tool_result", "tool_use_id": call["id"] as? String ?? "",
                 "content": execute(call["name"] as? String ?? "", call["input"] as? [String: Any] ?? [:])]
            }])
        }
        throw ChatError.tooManySteps
    }
}

/// Builds one Messages API reply from its server-sent events, in the shape of a reply that was not streamed, so the
/// tool loop reads both the same way.
struct AnthropicStream {
    private var blocks: [Int: [String: Any]] = [:]
    private var partialJSON: [Int: String] = [:]
    private var stopReason: String?
    private var model: String?
    private var usage: [String: Any] = [:]

    /// Reads one line of the stream. Returns the reply's text so far when the line added text.
    mutating func feed(line: String) throws -> String? {
        guard line.hasPrefix("data:") else { return nil }
        let json = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
        guard let event = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any] else { return nil }
        let index = event["index"] as? Int ?? 0
        switch event["type"] as? String {
        case "message_start":
            let message = event["message"] as? [String: Any]
            model = message?["model"] as? String
            usage.merge(message?["usage"] as? [String: Any] ?? [:]) { $1 }
        case "content_block_start":
            blocks[index] = event["content_block"] as? [String: Any] ?? [:]
        case "content_block_delta":
            let delta = event["delta"] as? [String: Any] ?? [:]
            switch delta["type"] as? String {
            case "text_delta":
                blocks[index, default: ["type": "text"]]["text"] = (blocks[index]?["text"] as? String ?? "") + (delta["text"] as? String ?? "")
                return text
            case "input_json_delta":
                partialJSON[index, default: ""] += delta["partial_json"] as? String ?? ""
            case "thinking_delta":
                blocks[index, default: ["type": "thinking"]]["thinking"] = (blocks[index]?["thinking"] as? String ?? "") + (delta["thinking"] as? String ?? "")
            case "signature_delta":
                blocks[index]?["signature"] = delta["signature"]
            default: break
            }
        case "content_block_stop":
            if blocks[index]?["type"] as? String == "tool_use" {
                let raw = partialJSON[index] ?? ""
                let input = raw.isEmpty ? [:] : (try? JSONSerialization.jsonObject(with: Data(raw.utf8))) as? [String: Any]
                blocks[index]?["input"] = input ?? [:]
            }
        case "message_delta":
            if let reason = (event["delta"] as? [String: Any])?["stop_reason"] as? String { stopReason = reason }
            usage.merge(event["usage"] as? [String: Any] ?? [:]) { $1 }
        case "error":
            let error = event["error"] as? [String: Any]
            throw SummaryError.http(error?["type"] as? String == "overloaded_error" ? 529 : 500, error?["message"] as? String ?? "Stream error")
        default: break
        }
        return nil
    }

    private var content: [[String: Any]] { blocks.keys.sorted().compactMap { blocks[$0] } }

    var text: String {
        content.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }.joined(separator: "\n\n")
    }

    var reply: [String: Any] {
        var out: [String: Any] = ["content": content, "usage": usage]
        if let stopReason { out["stop_reason"] = stopReason }
        if let model { out["model"] = model }
        return out
    }
}
