import XCTest
@testable import MossadCore

/// An OpenAI-compatible server on this Mac, such as Ollama or LM Studio.
final class LocalServerModelTests: XCTestCase {
    private struct Out: Decodable, Equatable { let title: String; let owner: String? }
    private let schema = Schema.object(["title": Schema.string, "owner": Schema.nullableString])
    private let tools = [ToolSpec(name: "find_meetings", description: "d", schema: ["type": "object", "properties": [:] as [String: Any]])]
    private let ollama = URL(string: "http://localhost:11434/v1")!

    override func setUp() {
        LocalServerModel.resetSchemaSupport()
    }

    private func body(_ i: Int) throws -> [String: Any] {
        try JSONSerialization.jsonObject(with: StubURLProtocol.requests[i].body) as! [String: Any]
    }

    private func reply(_ content: String, finish: String = "stop") -> Data {
        json(["model": "qwen2.5:32b", "choices": [["finish_reason": finish, "message": ["role": "assistant", "content": content]]],
              "usage": ["prompt_tokens": 120, "completion_tokens": 30]])
    }

    func testSchemaModeSendsResponseFormatToTheConfiguredServerWithoutAKey() async throws {
        StubURLProtocol.handler = { [self] _ in (200, reply(#"{"title":"T","owner":null}"#)) }
        let log = UsageLog(directory: tempDirectory())
        let llm = LocalServerModel(baseURL: ollama, model: "qwen2.5:32b", apiKey: nil, session: StubURLProtocol.session(), usage: log)
        let out = try await llm.json(system: "S", user: "U", schema: schema, effort: .high, purpose: .summary, as: Out.self)
        XCTAssertEqual(out, Out(title: "T", owner: nil))
        let r = StubURLProtocol.requests[0]
        XCTAssertEqual(r.url.absoluteString, "http://localhost:11434/v1/chat/completions")
        XCTAssertNil(r.headers["Authorization"] ?? r.headers["authorization"], "no key, no header")
        let b = try body(0)
        XCTAssertEqual(b["model"] as? String, "qwen2.5:32b")
        XCTAssertEqual(b["stream"] as? Bool, false)
        XCTAssertEqual((b["messages"] as? [[String: Any]])?.map { $0["role"] as! String }, ["system", "user"])
        let format = try XCTUnwrap(b["response_format"] as? [String: Any])
        XCTAssertEqual(format["type"] as? String, "json_schema")
        XCTAssertNotNil((format["json_schema"] as? [String: Any])?["schema"])
        let e = try XCTUnwrap(log.all().first)
        XCTAssertEqual(e.service, .local)
        XCTAssertEqual(e.inputTokens, 120)
        XCTAssertEqual(Pricing.cost(e), 0)
    }

    func testAnOptionalKeyGoesAsABearerToken() async throws {
        StubURLProtocol.handler = { [self] _ in (200, reply(#"{"title":"T","owner":"Dana"}"#)) }
        let llm = LocalServerModel(baseURL: URL(string: "http://localhost:1234/v1/")!, model: "m", apiKey: "lm-key", session: StubURLProtocol.session())
        _ = try await llm.json(system: "S", user: "U", schema: schema, effort: .low, purpose: .summary, as: Out.self)
        let r = StubURLProtocol.requests[0]
        XCTAssertEqual(r.url.absoluteString, "http://localhost:1234/v1/chat/completions")
        XCTAssertEqual(r.headers["Authorization"] ?? r.headers["authorization"], "Bearer lm-key")
    }

    func testAServerWithoutSchemaSupportGetsTheSchemaInTheInstructionsAndTheReplyIsRepaired() async throws {
        StubURLProtocol.handler = { r in
            let b = (try? JSONSerialization.jsonObject(with: r.body)) as? [String: Any] ?? [:]
            if b["response_format"] != nil {
                return (400, Data(#"{"error":{"message":"response_format json_schema is not supported"}}"#.utf8))
            }
            // A fence, words around it, a trailing comma, and the nullable field left out.
            return (200, json(["choices": [["finish_reason": "stop", "message": ["role": "assistant",
                "content": "Sure! Here it is:\n```json\n{\"title\": \"Budget review\",}\n```"]]]]))
        }
        let llm = LocalServerModel(baseURL: ollama, model: "m", apiKey: nil, session: StubURLProtocol.session())
        let out = try await llm.json(system: "S", user: "U", schema: schema, effort: .low, purpose: .summary, as: Out.self)
        XCTAssertEqual(out, Out(title: "Budget review", owner: nil))
        XCTAssertEqual(StubURLProtocol.requests.count, 2)
        let second = try body(1)
        XCTAssertNil(second["response_format"])
        let system = try XCTUnwrap((second["messages"] as? [[String: Any]])?.first?["content"] as? String)
        XCTAssertTrue(system.hasPrefix("S"))
        XCTAssertTrue(system.contains("JSON Schema"))
        XCTAssertTrue(system.contains("\"title\""))

        // The next request skips the format the server refused.
        _ = try await llm.json(system: "S", user: "U", schema: schema, effort: .low, purpose: .summary, as: Out.self)
        XCTAssertEqual(StubURLProtocol.requests.count, 3)
        XCTAssertNil(try body(2)["response_format"])
    }

    func testAReplyThatFailsTheSchemaIsAskedForOnceMore() async throws {
        var calls = 0
        StubURLProtocol.handler = { [self] _ in
            calls += 1
            return calls == 1 ? (200, reply(#"{"name":"wrong key"}"#)) : (200, reply(#"{"title":"Fixed","owner":null}"#))
        }
        let llm = LocalServerModel(baseURL: ollama, model: "m", apiKey: nil, session: StubURLProtocol.session())
        let out = try await llm.json(system: "S", user: "U", schema: schema, effort: .low, purpose: .summary, as: Out.self)
        XCTAssertEqual(out.title, "Fixed")
        XCTAssertEqual(StubURLProtocol.requests.count, 2)
        let messages = try XCTUnwrap(body(1)["messages"] as? [[String: Any]])
        XCTAssertEqual(messages.map { $0["role"] as! String }, ["system", "user", "assistant", "user"])
        XCTAssertTrue((messages[3]["content"] as? String ?? "").contains("title"), "the correction names the missing field")
    }

    func testAReplyThatStaysWrongThrowsMalformed() async {
        StubURLProtocol.handler = { [self] _ in (200, reply("I cannot do that.")) }
        let llm = LocalServerModel(baseURL: ollama, model: "m", apiKey: nil, session: StubURLProtocol.session())
        do {
            _ = try await llm.json(system: "S", user: "U", schema: schema, effort: .low, purpose: .summary, as: Out.self)
            XCTFail("expected malformed")
        } catch SummaryError.malformed {
        } catch { XCTFail("\(error)") }
    }

    func testToolCallsUseTheChatCompletionsToolsAPI() async throws {
        var round = 0
        StubURLProtocol.handler = { _ in
            round += 1
            if round == 1 {
                return (200, json(["choices": [["finish_reason": "tool_calls", "message": [
                    "role": "assistant", "content": "",
                    "tool_calls": [["id": "call_a", "type": "function", "function": ["name": "find_meetings", "arguments": #"{"people":["Jen"]}"#]]],
                ]]]]))
            }
            return (200, json(["choices": [["finish_reason": "stop", "message": ["role": "assistant", "content": "Done."]]]]))
        }
        let llm = LocalServerModel(baseURL: ollama, model: "m", apiKey: nil, session: StubURLProtocol.session())
        let seen = LocalBox()
        let answer = try await llm.runTools(system: "S", history: [ChatMessage(role: .user, text: "Q0"), ChatMessage(role: .assistant, text: "A0")],
                                            question: "Q1", tools: tools, purpose: .question) { name, input in
            seen.value = "\(name) \(input["people"] as? [String] ?? [])"
            return "result"
        }
        XCTAssertEqual(answer, "Done.")
        XCTAssertEqual(seen.value, "find_meetings [\"Jen\"]")
        let first = try body(0)
        XCTAssertEqual(((first["tools"] as? [[String: Any]])?.first?["function"] as? [String: Any])?["name"] as? String, "find_meetings")
        let messages = try XCTUnwrap(body(1)["messages"] as? [[String: Any]])
        XCTAssertEqual(messages.map { $0["role"] as! String }, ["system", "user", "assistant", "user", "assistant", "tool"])
        XCTAssertEqual(messages.last?["tool_call_id"] as? String, "call_a")
        XCTAssertEqual(messages.last?["content"] as? String, "result")
    }

    func testAServerThatIsNotRunningSaysSo() async {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [RefusingURLProtocol.self]
        let llm = LocalServerModel(baseURL: ollama, model: "m", apiKey: nil, session: URLSession(configuration: config))
        do {
            _ = try await llm.json(system: "S", user: "U", schema: schema, effort: .low, purpose: .summary, as: Out.self)
            XCTFail("expected an error")
        } catch let error as LocalServerError {
            XCTAssertEqual(error, .notRunning("http://localhost:11434/v1"))
            let friendly = FriendlyError(error, context: .summarizing)
            XCTAssertEqual(friendly.kind, .localServerDown)
            XCTAssertTrue(friendly.title.contains("isn't running"), friendly.title)
            XCTAssertEqual(FriendlyError(reason: error.description, context: .summarizing).kind, .localServerDown)
        } catch { XCTFail("\(error)") }
        do {
            _ = try await ModelCatalog.fetch(.localServer, apiKey: nil, serverURL: ollama, session: URLSession(configuration: config))
            XCTFail("expected an error")
        } catch { XCTAssertEqual(error as? LocalServerError, .notRunning("http://localhost:11434/v1")) }
    }

    func testTheModelListComesFromTheServer() async throws {
        StubURLProtocol.handler = { _ in
            (200, json(["object": "list", "data": [["id": "qwen2.5:32b", "object": "model"], ["id": "llama3.3:70b", "object": "model"]]]))
        }
        let models = try await ModelCatalog.fetch(.localServer, apiKey: nil, serverURL: ollama, session: StubURLProtocol.session())
        XCTAssertEqual(models.map(\.id), ["llama3.3:70b", "qwen2.5:32b"])
        XCTAssertEqual(StubURLProtocol.requests[0].url.absoluteString, "http://localhost:11434/v1/models")
    }

    func testOnlyThisMacCountsAsLocal() {
        XCTAssertTrue(LocalServer.isOnThisMac(URL(string: "http://localhost:11434/v1")!))
        XCTAssertTrue(LocalServer.isOnThisMac(URL(string: "http://127.0.0.1:1234/v1")!))
        XCTAssertTrue(LocalServer.isOnThisMac(URL(string: "http://[::1]:1234/v1")!))
        XCTAssertFalse(LocalServer.isOnThisMac(URL(string: "http://192.168.1.20:11434/v1")!))
        XCTAssertFalse(LocalServer.isOnThisMac(URL(string: "https://example.com/v1")!))
        XCTAssertFalse(LocalServer.isOnThisMac(URL(string: "http://mac-studio.local:11434/v1")!))
        XCTAssertEqual(LocalServer.url(from: " localhost:11434/v1 ")?.absoluteString, "http://localhost:11434/v1")
        XCTAssertEqual(LocalServer.url(from: "http://localhost:1234")?.absoluteString, "http://localhost:1234/v1")
        XCTAssertNil(LocalServer.url(from: ""))
        XCTAssertNil(LocalServer.url(from: "ftp://x"))
    }
}

/// JSON pulled out of a weaker model's reply, mended, and checked against the schema.
final class JSONRepairTests: XCTestCase {
    func testTheObjectIsFoundInsideFencesThinkingAndWords() {
        XCTAssertEqual(JSONRepair.extract("<think>{not this}</think>\nOK: ```json\n{\"a\": \"}\"}\n``` done"), #"{"a": "}"}"#)
        XCTAssertEqual(JSONRepair.extract(#"{"a":[1,2,],}"#), #"{"a":[1,2]}"#)
        XCTAssertEqual(JSONRepair.extract(#"{"a":{"b":"cut off"#), #"{"a":{"b":"cut off"}}"#)
    }

    func testMissingNullableAndListFieldsAreFilledAndOtherProblemsReported() {
        let schema = Schema.object(["title": Schema.string, "owner": Schema.nullableString, "tags": Schema.array(Schema.string),
                                    "kind": Schema.oneOf(["a", "b"])])
        var value: Any = ["title": "T", "kind": "c"] as [String: Any]
        let problems = SchemaCheck.fill(&value, schema: schema)
        let object = value as! [String: Any]
        XCTAssertTrue(object["owner"] is NSNull)
        XCTAssertEqual(object["tags"] as? [String], [])
        XCTAssertEqual(problems, ["kind must be one of: a, b"])
        var wrong: Any = ["owner": 3] as [String: Any]
        XCTAssertEqual(Set(SchemaCheck.fill(&wrong, schema: schema)),
                       ["title is missing", "owner must be a string or null", "kind is missing"])
    }
}

private final class LocalBox: @unchecked Sendable { var value = "" }

/// A server that is not running: the connection is refused.
final class RefusingURLProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() { client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost)) }
    override func stopLoading() {}
}
