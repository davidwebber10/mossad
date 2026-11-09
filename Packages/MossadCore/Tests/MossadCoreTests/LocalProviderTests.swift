import XCTest
@testable import MossadCore

/// The two providers that run without a cloud: a local server and Apple's on-device model.
final class LocalProviderTests: XCTestCase {
    func testNeitherNeedsAKey() {
        XCTAssertFalse(AIProvider.localServer.requiresKey)
        XCTAssertEqual(AIProvider.localServer.key, .localServer, "an optional key, for a server that asks for one")
        XCTAssertFalse(AIProvider.apple.requiresKey)
        XCTAssertNil(AIProvider.apple.key)
        for cloud in [AIProvider.anthropic, .openai, .openrouter] {
            XCTAssertTrue(cloud.requiresKey)
            XCTAssertFalse(cloud.isLocal)
        }
        XCTAssertTrue(AIProvider.localServer.isLocal)
        XCTAssertTrue(AIProvider.apple.isLocal)
        XCTAssertNil(KeyCheck.Service(AIProvider.localServer))
        XCTAssertNil(KeyCheck.Service(AIProvider.apple))
    }

    func testTheyCostNothing() {
        XCTAssertEqual(Pricing.cost(UsageEvent(date: Date(), callID: nil, service: .local, purpose: .summary, model: "qwen2.5:32b",
                                               inputTokens: 1_000_000, outputTokens: 1_000_000)), 0)
        XCTAssertEqual(Pricing.hourEstimate(transcription: .local, ai: .localServer, model: "qwen2.5:32b"), 0)
        XCTAssertEqual(Pricing.hourEstimate(transcription: .local, ai: .apple, model: ""), 0)
        XCTAssertEqual(Rating.model("qwen2.5:32b", provider: .localServer)?.free, true)
        XCTAssertEqual(Rating.model(AppleModelInfo.id, provider: .apple)?.free, true)
    }

    func testTheLatestAliasesDoNotApply() {
        XCTAssertTrue(LatestModel.aliases(for: .localServer).isEmpty)
        XCTAssertTrue(LatestModel.aliases(for: .apple).isEmpty)
        XCTAssertEqual(AIProvider.apple.resolvedModel(""), AppleModelInfo.id)
        XCTAssertEqual(AIProvider.localServer.resolvedModel(""), "", "a server's model must be picked from its list")
        XCTAssertEqual(AIProvider.localServer.resolvedModel("qwen2.5:32b"), "qwen2.5:32b")
    }

    func testAppleListsOneModel() async throws {
        let models = try await ModelCatalog.fetch(.apple, apiKey: nil)
        XCTAssertEqual(models, [ModelInfo(id: AppleModelInfo.id, name: "Apple on-device")])
    }

    func testTheAppleNoteSaysWhatItTrades() {
        let note = AIProvider.apple.note ?? ""
        XCTAssertTrue(note.contains("free and private"), note)
        XCTAssertTrue(note.contains("lower quality"), note)
        XCTAssertTrue(note.contains("slower on long meetings"), note)
    }

    func testTheFactoryBuildsTheRightModel() {
        let server = AIProvider.localServer.model("m", apiKey: nil, usage: nil, serverURL: URL(string: "http://localhost:1234/v1")!)
        XCTAssertTrue(server is LocalServerModel)
        XCTAssertEqual((server as? LocalServerModel)?.baseURL.absoluteString, "http://localhost:1234/v1")
        let apple = AIProvider.apple.model("", apiKey: nil, usage: nil)
        XCTAssertTrue(apple is any ContextLimitedModel)
    }
}

/// Long meetings for a small context: the transcript goes in parts that end on a speaker's turn.
final class ChunkPlannerTests: XCTestCase {
    private let words: (String) -> Int = { $0.split(separator: " ").count }

    func testPartsEndOnTurnEdgesAndFitTheBudget() {
        let lines = (0..<10).map { "[00:00:0\($0)] Dana: one two three four" }  // 6 words each
        let parts = ChunkPlanner.plan(lines, budget: 20, tokens: words)
        XCTAssertEqual(parts.map(\.count), [3, 3, 3, 1])
        XCTAssertEqual(parts.flatMap { $0 }, lines, "every line once, in order")
        for part in parts { XCTAssertLessThanOrEqual(part.map(words).reduce(0, +), 20) }
    }

    func testAnOversizedTurnIsSplitAtWords() {
        let long = "[00:01:00] Sam: " + (1...25).map(String.init).joined(separator: " ")
        let parts = ChunkPlanner.plan(["[00:00:00] Dana: hi there", long, "[00:02:00] Dana: bye"], budget: 10, tokens: words)
        XCTAssertEqual(parts.first, ["[00:00:00] Dana: hi there"])
        for part in parts { XCTAssertLessThanOrEqual(part.map(words).reduce(0, +), 10, "\(part)") }
        let prefix = "[00:01:00] Sam: "
        let spoken = parts.flatMap { $0 }.filter { $0.hasPrefix(prefix) }.flatMap { $0.dropFirst(prefix.count).split(separator: " ").map(String.init) }
        XCTAssertEqual(spoken, (1...25).map(String.init), "no word lost or repeated")
        XCTAssertTrue(parts.dropFirst().first?.first?.hasPrefix("[00:01:00] Sam:") == true)
        XCTAssertTrue(parts.flatMap { $0 }.filter { $0.contains("13") }.first?.hasPrefix("[00:01:00] Sam:") == true,
                      "each piece of a split turn keeps its speaker")
    }

    func testTheBudgetLeavesRoomForTheInstructionsAndTheReply() {
        XCTAssertEqual(ChunkPlanner.budget(context: 4096, fixed: 1000, reply: 1024), 2072)
        XCTAssertEqual(ChunkPlanner.budget(context: 2000, fixed: 1800, reply: 500), 256, "never below a floor")
        XCTAssertEqual(ChunkPlanner.replyReserve(context: 4096), 1024)
        XCTAssertEqual(ChunkPlanner.replyReserve(context: 8192), 2048)
    }
}

/// A short meeting goes in one request; a long one is summarized in parts and the parts combined into the same schema.
final class MapReduceSummaryTests: XCTestCase {
    private func transcript(_ lines: Int) -> String {
        (0..<lines).map { i in String(format: "[00:%02d:%02d] %@: %@", i / 60, i % 60, i % 2 == 0 ? "Dana" : "Sam",
                                      "we talked about item \(i) and what comes next for it") }.joined(separator: "\n")
    }

    func testAShortMeetingIsOneRequest() async throws {
        let model = StubSmallModel(context: 100_000)
        let summary = try await LLMSummarizer(llm: model).summarize(transcript: transcript(5), title: "Sync")
        XCTAssertEqual(model.calls.count, 1)
        XCTAssertEqual(summary.summary, "part")
    }

    func testALongMeetingIsSummarizedInPartsThenCombinedWithTheSameSchema() async throws {
        let model = StubSmallModel(context: 1500)
        let summary = try await LLMSummarizer(llm: model).summarize(transcript: transcript(200), title: "Planning")
        let calls = model.calls
        XCTAssertGreaterThan(calls.count, 2)
        let maps = calls.filter { $0.user.contains("Part ") && $0.user.contains("Transcript") }
        XCTAssertGreaterThan(maps.count, 1)
        for call in calls {
            XCTAssertEqual(Set((call.schema["properties"] as? [String: Any] ?? [:]).keys),
                           Set((LLMSummarizer.schema["properties"] as? [String: Any] ?? [:]).keys), "every request uses the cloud summary's schema")
            XCTAssertLessThanOrEqual(call.tokens, 1500, "every request fits the context")
        }
        let last = try XCTUnwrap(calls.last)
        XCTAssertTrue(last.user.contains("Notes on each part"), last.user)
        XCTAssertEqual(summary.summary, "combined")
        XCTAssertEqual(summary.title, "Combined title")
        // Action items and decisions from every part, once each.
        XCTAssertEqual(summary.actionItems.map(\.task), ["Send the deck"])
        XCTAssertEqual(summary.decisions.map(\.text), ["Ship it"])
        XCTAssertEqual(summary.hasOutcomes, true)
    }

    func testTheCombinedListsWinWhenTheCombineStepKeepsThem() {
        let part = LLMSummarizer.Output(summary: "p", topics: [], action_items: [ActionItem(owner: "Sam", task: "Model rail")],
                                        decisions: [], headline: "", kind: "", has_outcomes: true, tags: ["Freight"], title: nil)
        let combined = LLMSummarizer.Output(summary: "c", topics: [], action_items: [ActionItem(owner: "Sam", task: "Model the rail option")],
                                            decisions: [], headline: "", kind: "", has_outcomes: true, tags: nil, title: "T")
        let merged = LLMSummarizer.merged(combined, parts: [part, part])
        XCTAssertEqual(merged.action_items.map(\.task), ["Model the rail option"])
        XCTAssertEqual(merged.tags, ["Freight"])
    }
}

/// A model with a small context that counts a token per word and answers with fixed JSON.
final class StubSmallModel: ContextLimitedModel, @unchecked Sendable {
    struct Call { var system: String; var user: String; var schema: [String: Any]; var tokens: Int }
    private let lock = NSLock()
    private var recorded: [Call] = []
    let context: Int

    init(context: Int) { self.context = context }

    var calls: [Call] { lock.withLock { recorded } }

    func contextTokens() async -> Int { context }
    func tokenCount(_ text: String) async -> Int { text.split(whereSeparator: \.isWhitespace).count }

    func json<Output: Decodable>(system: String, user: String, schema: [String: Any], effort: Effort,
                                 purpose: UsageEvent.Purpose, as: Output.Type) async throws -> Output {
        let schemaText = String(decoding: try JSONSerialization.data(withJSONObject: schema), as: UTF8.self)
        let tokens = await tokenCount(system) + tokenCount(user) + tokenCount(schemaText) + ChunkPlanner.replyReserve(context: context)
        lock.withLock { recorded.append(Call(system: system, user: user, schema: schema, tokens: tokens)) }
        let combining = user.contains("Notes on each part")
        let object: [String: Any] = [
            "summary": combining ? "combined" : "part",
            "topics": [["title": "Topic", "summary": "S"]],
            "action_items": combining ? [] : [["owner": "Dana", "task": "Send the deck"]],
            "decisions": combining ? [] : [["text": "Ship it", "at_seconds": NSNull()]],
            "headline": "H", "kind": "Planning", "has_outcomes": !combining, "tags": ["Budget"],
            "title": combining ? "Combined title" : "Part title",
        ]
        return try JSONDecoder().decode(Output.self, from: JSONSerialization.data(withJSONObject: object))
    }

    func runTools(system: String, history: [ChatMessage], question: String, tools: [ToolSpec], purpose: UsageEvent.Purpose,
                  execute: @escaping @Sendable (String, [String: Any]) -> String) async throws -> String { "" }
}

#if canImport(FoundationModels)
/// Every schema Mossad sends converts to a guided-generation schema, and the chat tools' arguments do too.
final class GuidedSchemaTests: XCTestCase {
    func testMossadsSchemasConvert() throws {
        for schema in [LLMSummarizer.schema, LLMCoach.schema, CommitmentFinder.schema, Schema.object(["title": Schema.string])] {
            XCTAssertNoThrow(try GuidedSchema.make(schema))
        }
        for tool in ChatTools.allDefinitions {
            XCTAssertNoThrow(try GuidedSchema.make(tool.schema, lenient: true), tool.name)
        }
    }

    func testAUnionThatIsNotNullableIsLeftToTheInstructions() {
        XCTAssertThrowsError(try GuidedSchema.make(["anyOf": [["type": "string"], ["type": "number"]]]))
    }
}
#endif
