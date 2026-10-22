import XCTest
@testable import MossadCore

final class LanguageModelTests: XCTestCase {
    private struct Out: Decodable, Equatable { let title: String }
    private let schema: [String: Any] = ["type": "object", "properties": ["title": ["type": "string"]], "required": ["title"], "additionalProperties": false]
    private let tools = [ToolSpec(name: "find_meetings", description: "d", schema: ["type": "object", "properties": [:] as [String: Any]])]

    private func body(_ i: Int) throws -> [String: Any] {
        try JSONSerialization.jsonObject(with: StubURLProtocol.requests[i].body) as! [String: Any]
    }

    // MARK: OpenAI

    func testOpenAIStructuredOutputUsesTheResponsesFormat() async throws {
        StubURLProtocol.handler = { _ in
            (200, json(["status": "completed", "model": "gpt-6.1-sol",
                        "output": [["type": "reasoning", "id": "rs_1", "summary": []],
                                   ["type": "message", "role": "assistant", "content": [["type": "output_text", "text": #"{"title":"T"}"#]]]],
                        "usage": ["input_tokens": 100, "output_tokens": 20, "input_tokens_details": ["cached_tokens": 40]]]))
        }
        let log = UsageLog(directory: tempDirectory())
        let llm = OpenAIModel(apiKey: "sk", model: "gpt-6.1-sol", session: StubURLProtocol.session(), usage: log)
        let out = try await llm.json(system: "S", user: "U", schema: schema, effort: .high, purpose: .summary, as: Out.self)
        XCTAssertEqual(out, Out(title: "T"))
        let r = StubURLProtocol.requests[0]
        XCTAssertEqual(r.url.absoluteString, "https://api.openai.com/v1/responses")
        XCTAssertEqual(r.headers["Authorization"] ?? r.headers["authorization"], "Bearer sk")
        let b = try body(0)
        XCTAssertEqual(b["instructions"] as? String, "S")
        XCTAssertEqual(b["input"] as? String, "U")
        XCTAssertEqual((b["reasoning"] as? [String: Any])?["effort"] as? String, "high")
        let format = (b["text"] as? [String: Any])?["format"] as? [String: Any]
        XCTAssertEqual(format?["type"] as? String, "json_schema")
        XCTAssertEqual(format?["strict"] as? Bool, true)
        XCTAssertNotNil(format?["name"])
        let e = try XCTUnwrap(log.all().first)
        XCTAssertEqual(e.service, .openai)
        XCTAssertEqual(e.inputTokens, 60)
        XCTAssertEqual(e.cacheReadTokens, 40)
    }

    func testOpenAIRefusalAndTruncationThrow() async {
        StubURLProtocol.handler = { _ in
            (200, json(["status": "completed", "output": [["type": "message", "content": [["type": "refusal", "refusal": "No."]]]]]))
        }
        let llm = OpenAIModel(apiKey: "sk", model: "m", session: StubURLProtocol.session())
        do { _ = try await llm.json(system: "", user: "", schema: schema, effort: .low, purpose: .summary, as: Out.self); XCTFail() } catch {}
        StubURLProtocol.handler = { _ in (200, json(["status": "incomplete", "incomplete_details": ["reason": "max_output_tokens"], "output": []])) }
        do { _ = try await llm.json(system: "", user: "", schema: schema, effort: .low, purpose: .summary, as: Out.self); XCTFail() } catch {}
    }

    func testOpenAIToolLoopSendsBackTheItemsAndTheOutputs() async throws {
        var round = 0
        StubURLProtocol.handler = { _ in
            round += 1
            if round == 1 {
                return (200, json(["status": "completed", "output": [
                    ["type": "reasoning", "id": "rs_1", "summary": [], "encrypted_content": "enc"],
                    ["type": "function_call", "id": "fc_1", "call_id": "call_1", "name": "find_meetings", "arguments": #"{"people":["Jen"]}"#],
                ]]))
            }
            return (200, json(["status": "completed", "output": [["type": "message", "content": [["type": "output_text", "text": "Done."]]]]]))
        }
        let llm = OpenAIModel(apiKey: "sk", model: "m", session: StubURLProtocol.session())
        let seen = Box()
        let answer = try await llm.runTools(system: "S", history: [ChatMessage(role: .user, text: "Q0"), ChatMessage(role: .assistant, text: "A0")],
                                            question: "Q1", tools: tools, purpose: .question) { name, input in
            seen.value = "\(name) \(input["people"] as? [String] ?? [])"
            return "call_id: x"
        }
        XCTAssertEqual(answer, "Done.")
        XCTAssertEqual(seen.value, "find_meetings [\"Jen\"]")
        let first = try body(0)
        XCTAssertEqual(first["store"] as? Bool, false)
        let declared = (first["tools"] as? [[String: Any]])?.first
        XCTAssertEqual(declared?["type"] as? String, "function")
        XCTAssertEqual(declared?["name"] as? String, "find_meetings")
        let input = try XCTUnwrap(body(1)["input"] as? [[String: Any]])
        XCTAssertEqual(input.compactMap { $0["role"] as? String }, ["user", "assistant", "user"])
        XCTAssertEqual(input.compactMap { $0["type"] as? String }.suffix(3), ["reasoning", "function_call", "function_call_output"])
        XCTAssertEqual(input.last?["call_id"] as? String, "call_1")
        XCTAssertEqual(input.last?["output"] as? String, "call_id: x")
    }

    // MARK: OpenRouter

    func testOpenRouterStructuredOutputRecordsTheChargedCost() async throws {
        StubURLProtocol.handler = { _ in
            (200, json(["model": "google/gemini-x", "choices": [["finish_reason": "stop", "message": ["role": "assistant", "content": #"{"title":"T"}"#]]],
                        "usage": ["prompt_tokens": 100, "completion_tokens": 10, "cost": 0.0123]]))
        }
        let log = UsageLog(directory: tempDirectory())
        let llm = OpenRouterModel(apiKey: "or", model: "google/gemini-x", session: StubURLProtocol.session(), usage: log)
        let out = try await llm.json(system: "S", user: "U", schema: schema, effort: .medium, purpose: .coach, as: Out.self)
        XCTAssertEqual(out, Out(title: "T"))
        XCTAssertEqual(StubURLProtocol.requests[0].url.absoluteString, "https://openrouter.ai/api/v1/chat/completions")
        let b = try body(0)
        XCTAssertEqual((b["messages"] as? [[String: Any]])?.map { $0["role"] as! String }, ["system", "user"])
        XCTAssertEqual(((b["response_format"] as? [String: Any])?["json_schema"] as? [String: Any])?["strict"] as? Bool, true)
        XCTAssertEqual((b["provider"] as? [String: Any])?["require_parameters"] as? Bool, true)
        XCTAssertEqual(log.all().first?.costUSD, 0.0123)
        XCTAssertEqual(Pricing.cost(log.all().first!), 0.0123)
    }

    func testOpenRouterToolLoopUsesToolMessages() async throws {
        var round = 0
        StubURLProtocol.handler = { _ in
            round += 1
            if round == 1 {
                return (200, json(["choices": [["finish_reason": "tool_calls", "message": [
                    "role": "assistant", "content": NSNull(), "reasoning_details": [["type": "reasoning.text", "text": "x"]],
                    "tool_calls": [["id": "call_a", "type": "function", "function": ["name": "find_meetings", "arguments": "{}"]]],
                ]]]]))
            }
            return (200, json(["choices": [["finish_reason": "stop", "message": ["role": "assistant", "content": "Done."]]]]))
        }
        let llm = OpenRouterModel(apiKey: "or", model: "m", session: StubURLProtocol.session())
        let answer = try await llm.runTools(system: "S", history: [], question: "Q", tools: tools, purpose: .question) { _, _ in "result" }
        XCTAssertEqual(answer, "Done.")
        let messages = try XCTUnwrap(body(1)["messages"] as? [[String: Any]])
        XCTAssertEqual(messages.map { $0["role"] as! String }, ["system", "user", "assistant", "tool"])
        XCTAssertNotNil(messages[2]["reasoning_details"], "reasoning goes back unchanged")
        XCTAssertEqual(messages[3]["tool_call_id"] as? String, "call_a")
        XCTAssertEqual(messages[3]["content"] as? String, "result")
        XCTAssertNotNil(try body(1)["tools"], "tools go with every request")
    }

    // MARK: Model lists

    func testModelListsParseEachProvider() {
        let anthropic = ModelCatalog.parseAnthropic(json(["data": [["id": "claude-opus-5-5", "display_name": "Claude Opus 5.5"]]]))
        XCTAssertEqual(anthropic, [ModelInfo(id: "claude-opus-5-5", name: "Claude Opus 5.5")])
        let openAI = ModelCatalog.parseOpenAI(json(["data": [["id": "gpt-6.1-sol"], ["id": "whisper-1"], ["id": "text-embedding-3"], ["id": "gpt-6-astra"]]]))
        XCTAssertEqual(openAI.map(\.id), ["gpt-6-astra", "gpt-6.1-sol"])
        let router = ModelCatalog.parseOpenRouter(json(["data": [
            ["id": "a/x", "name": "X", "supported_parameters": ["tools", "structured_outputs"]],
            ["id": "b/y", "name": "Y", "supported_parameters": ["tools"]],
        ]]))
        XCTAssertEqual(router.map(\.id), ["a/x"])
    }
}

private final class Box: @unchecked Sendable { var value = "" }
