import XCTest
@testable import MossadCore

final class LatestModelTests: XCTestCase {
    /// Anthropic lists the newest first.
    private let anthropic = [
        ModelInfo(id: "claude-fable-5-1", name: "Claude Fable 5.1"),
        ModelInfo(id: "claude-opus-5-5-20261015", name: "Claude Opus 5.5"),
        ModelInfo(id: "claude-sonnet-5-5", name: "Claude Sonnet 5.5"),
        ModelInfo(id: "claude-haiku-5-5", name: "Claude Haiku 5.5"),
        ModelInfo(id: "claude-opus-5", name: "Claude Opus 5"),
        ModelInfo(id: "claude-sonnet-5", name: "Claude Sonnet 5"),
        ModelInfo(id: "claude-3-opus-20240229", name: "Claude Opus 3"),
    ]

    /// OpenAI lists by id; `created` says which is newest.
    private let openAI = [
        ModelInfo(id: "gpt-5-mini", name: "gpt-5-mini", created: 1_754_000_000),
        ModelInfo(id: "gpt-5.4-mini", name: "gpt-5.4-mini", created: 1_770_000_000),
        ModelInfo(id: "gpt-5.4-nano", name: "gpt-5.4-nano", created: 1_770_000_000),
        ModelInfo(id: "gpt-5.5-pro", name: "gpt-5.5-pro", created: 1_790_000_000),
        ModelInfo(id: "gpt-6-astra", name: "gpt-6-astra", created: 1_780_000_000),
        ModelInfo(id: "gpt-6.1-sol", name: "gpt-6.1-sol", created: 1_785_000_000),
        ModelInfo(id: "gpt-6.1-sol-2026-09-01", name: "gpt-6.1-sol-2026-09-01", created: 1_785_000_000),
        ModelInfo(id: "gpt-6.2-realtime", name: "gpt-6.2-realtime", created: 1_799_000_000),
        ModelInfo(id: "gpt-6.2-transcribe", name: "gpt-6.2-transcribe", created: 1_799_000_000),
    ]

    func testAnthropicFamiliesPickTheFirstListedModel() {
        XCTAssertEqual(LatestModel.resolve("latest:opus", in: anthropic), "claude-opus-5-5-20261015")
        XCTAssertEqual(LatestModel.resolve("latest:fable", in: anthropic), "claude-fable-5-1")
        XCTAssertEqual(LatestModel.resolve("latest:sonnet", in: anthropic), "claude-sonnet-5-5")
        XCTAssertEqual(LatestModel.resolve("latest:haiku", in: anthropic), "claude-haiku-5-5")
    }

    func testOpenAIFamiliesPickTheNewestByCreated() {
        XCTAssertEqual(LatestModel.resolve("latest:gpt", in: openAI), "gpt-6.1-sol", "the undated id wins a tie; excluded and pro models never count")
        XCTAssertEqual(LatestModel.resolve("latest:gpt-mini", in: openAI), "gpt-5.4-mini")
        XCTAssertEqual(LatestModel.resolve("latest:gpt-nano", in: openAI), "gpt-5.4-nano")
    }

    func testNoMatchOrUnknownAliasIsNil() {
        XCTAssertNil(LatestModel.resolve("latest:fable", in: [ModelInfo(id: "claude-opus-5-5", name: "Opus")]))
        XCTAssertNil(LatestModel.resolve("latest:gpt", in: anthropic))
        XCTAssertNil(LatestModel.resolve("latest:mystery", in: anthropic))
        XCTAssertNil(LatestModel.resolve("claude-opus-5-5", in: anthropic))
    }

    func testAliasesPerProvider() {
        XCTAssertEqual(LatestModel.aliases(for: .anthropic).map(\.name), ["Opus Latest", "Fable Latest", "Sonnet Latest", "Haiku Latest"])
        XCTAssertEqual(LatestModel.aliases(for: .openai).map(\.id), ["latest:gpt", "latest:gpt-mini", "latest:gpt-nano"])
        XCTAssertEqual(LatestModel.aliases(for: .openai).map(\.name), ["GPT Latest", "GPT Mini Latest", "GPT Nano Latest"])
        XCTAssertTrue(LatestModel.aliases(for: .openrouter).isEmpty)
    }

    func testFallbacksBeforeTheListIsKnown() {
        let cache = LatestModelCache(defaults: freshDefaults())
        XCTAssertEqual(AIProvider.anthropic.resolvedModel("latest:opus", cache: cache), "claude-opus-5-5")
        XCTAssertEqual(AIProvider.anthropic.resolvedModel("latest:fable", cache: cache), "claude-fable-5-2")
        XCTAssertEqual(AIProvider.anthropic.resolvedModel("latest:sonnet", cache: cache), "claude-sonnet-5-5")
        XCTAssertEqual(AIProvider.anthropic.resolvedModel("latest:haiku", cache: cache), "claude-haiku-5-5")
        XCTAssertEqual(AIProvider.openai.resolvedModel("latest:gpt", cache: cache), AIProvider.openai.defaultModel)
        XCTAssertEqual(AIProvider.openai.resolvedModel("latest:gpt-mini", cache: cache), AIProvider.openai.defaultModel)
        XCTAssertEqual(AIProvider.openai.resolvedModel("latest:gpt-nano", cache: cache), AIProvider.openai.defaultModel)
    }

    func testResolvedModelLeavesOtherNamesAlone() {
        let cache = LatestModelCache(defaults: freshDefaults())
        XCTAssertEqual(AIProvider.anthropic.resolvedModel("", cache: cache), "claude-opus-5-5")
        XCTAssertEqual(AIProvider.anthropic.resolvedModel("claude-sonnet-5", cache: cache), "claude-sonnet-5")
        XCTAssertEqual(AIProvider.openrouter.resolvedModel("anthropic/claude-opus-5.5", cache: cache), "anthropic/claude-opus-5.5")
        XCTAssertEqual(AIProvider.anthropic.resolvedModel("latest:mystery", cache: cache), "claude-opus-5-5", "an unknown alias uses the default")
        XCTAssertEqual(AIProvider.anthropic.resolvedModel("latest:gpt", cache: cache), "claude-opus-5-5", "another provider's alias uses the default")
    }

    func testTheCacheKeepsTheResolvedIdsAcrossRestarts() {
        let defaults = freshDefaults()
        let cache = LatestModelCache(defaults: defaults)
        XCTAssertTrue(cache.update(.anthropic, models: anthropic))
        XCTAssertFalse(cache.update(.anthropic, models: anthropic), "the same list changes nothing")
        XCTAssertTrue(cache.update(.openai, models: openAI))
        XCTAssertFalse(cache.needsRefresh(.anthropic))
        XCTAssertTrue(cache.needsRefresh(.openrouter))

        let restarted = LatestModelCache(defaults: defaults)
        XCTAssertEqual(AIProvider.anthropic.resolvedModel("latest:opus", cache: restarted), "claude-opus-5-5-20261015")
        XCTAssertEqual(AIProvider.openai.resolvedModel("latest:gpt-mini", cache: restarted), "gpt-5.4-mini")
        XCTAssertFalse(restarted.needsRefresh(.anthropic))
        XCTAssertTrue(restarted.needsRefresh(.anthropic, now: Date().addingTimeInterval(86_400 + 60)), "once a day")
    }

    func testAnEmptyListKeepsTheLastKnownIds() {
        let cache = LatestModelCache(defaults: freshDefaults())
        cache.update(.anthropic, models: anthropic)
        cache.update(.anthropic, models: [])
        XCTAssertEqual(AIProvider.anthropic.resolvedModel("latest:haiku", cache: cache), "claude-haiku-5-5")
    }

    func testTheOpenAIListKeepsCreated() {
        let list = ModelCatalog.parseOpenAI(json(["data": [["id": "gpt-6.1-sol", "created": 1_785_000_000], ["id": "gpt-6-astra"]]]))
        XCTAssertEqual(list.map(\.created), [nil, 1_785_000_000])
    }

    func testAModelFromAnAliasAsksForTheResolvedId() async throws {
        let cache = LatestModelCache(defaults: freshDefaults())
        cache.update(.anthropic, models: anthropic)
        StubURLProtocol.handler = { _ in
            (200, json(["stop_reason": "end_turn",
                        "content": [["type": "text", "text": #"{"title":"T"}"#]],
                        "usage": ["input_tokens": 10, "output_tokens": 2]]))
        }
        let log = UsageLog(directory: tempDirectory())
        let llm = AIProvider.anthropic.model("latest:sonnet", apiKey: "k", usage: log, cache: cache, session: StubURLProtocol.session())
        struct Out: Decodable { let title: String }
        let schema: [String: Any] = ["type": "object", "properties": ["title": ["type": "string"]], "required": ["title"], "additionalProperties": false]
        _ = try await llm.json(system: "S", user: "U", schema: schema, effort: .low, purpose: .summary, as: Out.self)
        let body = try JSONSerialization.jsonObject(with: StubURLProtocol.requests[0].body) as! [String: Any]
        XCTAssertEqual(body["model"] as? String, "claude-sonnet-5-5")
        XCTAssertEqual(log.all().last?.model, "claude-sonnet-5-5")
    }

    /// A write to the defaults tells its observers at once, on the writing thread. SwiftUI is one of them, and it
    /// waits for the main thread, which can be waiting for an id: Settings › AI then never draws.
    func testAnObserverOfTheDefaultsCanReadAnIdWhileTheCacheSaves() {
        let defaults = freshDefaults()
        let cache = LatestModelCache(defaults: defaults)
        let answered = expectation(description: "the cache answers while it saves")
        answered.assertForOverFulfill = false
        let observer = NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: defaults, queue: nil) { _ in
            let done = DispatchSemaphore(value: 0)
            DispatchQueue.global().async {
                _ = cache.id("latest:opus", provider: .anthropic)
                done.signal()
            }
            if done.wait(timeout: .now() + 1) == .success { answered.fulfill() }
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        cache.update(.anthropic, models: [ModelInfo(id: "claude-opus-5-5", name: "Claude Opus 5.5")])
        wait(for: [answered], timeout: 5)
        XCTAssertEqual(LatestModelCache(defaults: defaults).id("latest:opus", provider: .anthropic), "claude-opus-5-5")
    }

    func testPricesUseTheResolvedModel() {
        let alias = Pricing.hourEstimate(transcription: .local, ai: .anthropic, model: "latest:haiku")
        let id = Pricing.hourEstimate(transcription: .local, ai: .anthropic, model: "claude-haiku-5-5")
        XCTAssertEqual(alias, id, accuracy: 0.000_001)
    }

    private func freshDefaults() -> UserDefaults {
        let name = "LatestModelTests-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        return d
    }
}
