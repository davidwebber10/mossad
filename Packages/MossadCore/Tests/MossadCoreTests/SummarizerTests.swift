import XCTest
@testable import MossadCore

final class SummarizerTests: XCTestCase {
    func summarizer() -> LLMSummarizer {
        LLMSummarizer(apiKey: "ant-key", session: StubURLProtocol.session())
    }

    func testPromptNamesTheOwnerAndOrganization() {
        XCTAssertTrue(LLMSummarizer.systemPrompt(owner: "Jordan Lee", organization: "Acme").contains("internal Acme meeting transcripts for Jordan Lee"))
        XCTAssertTrue(LLMSummarizer.systemPrompt(owner: "Jordan Lee", organization: "").contains("meeting transcripts for Jordan Lee"))
        XCTAssertFalse(LLMSummarizer.systemPrompt(owner: "Jordan Lee", organization: "").contains("internal"))
    }

    func reply(_ text: String, stop: String = "end_turn") -> Data {
        json(["id": "msg_1", "type": "message", "role": "assistant", "stop_reason": stop,
              "content": [["type": "thinking", "thinking": "", "signature": "x"], ["type": "text", "text": text]]])
    }

    func testSendsModelHeadersAndSchema() async throws {
        StubURLProtocol.handler = { _ in (200, self.reply(#"{"summary":"S","topics":[],"action_items":[],"decisions":[],"headline":"H","kind":"Status update","has_outcomes":false}"#)) }
        _ = try await summarizer().summarize(transcript: "[00:00:01] David Webber: Hi", title: "Weekly Ops Sync")
        let r = try XCTUnwrap(StubURLProtocol.requests.first)
        XCTAssertEqual(r.url.absoluteString, "https://api.anthropic.com/v1/messages")
        let headers = Dictionary(uniqueKeysWithValues: r.headers.map { ($0.key.lowercased(), $0.value) })
        XCTAssertEqual(headers["x-api-key"], "ant-key")
        XCTAssertEqual(headers["anthropic-version"], "2023-06-01")
        XCTAssertEqual(headers["anthropic-beta"], "server-side-fallback-2026-07-01")
        let body = try JSONSerialization.jsonObject(with: r.body) as! [String: Any]
        XCTAssertEqual(body["model"] as? String, "claude-opus-5-5")
        XCTAssertEqual(body["fallbacks"] as? String, "default")
        let format = (body["output_config"] as? [String: Any])?["format"] as? [String: Any]
        XCTAssertEqual(format?["type"] as? String, "json_schema")
        let schema = format?["schema"] as? [String: Any]
        XCTAssertEqual(Set(schema?["required"] as? [String] ?? []),
                       ["summary", "topics", "action_items", "decisions", "headline", "kind", "has_outcomes", "tags", "title"])
        let topic = ((schema?["properties"] as? [String: Any])?["topics"] as? [String: Any])?["items"] as? [String: Any]
        XCTAssertEqual(Set(topic?["required"] as? [String] ?? []), ["title", "summary"])
        let props = schema?["properties"] as? [String: Any]
        let decision = (props?["decisions"] as? [String: Any])?["items"] as? [String: Any]
        XCTAssertEqual(Set(decision?["required"] as? [String] ?? []), ["text", "at_seconds"])
        let item = (props?["action_items"] as? [String: Any])?["items"] as? [String: Any]
        XCTAssertEqual(Set(item?["required"] as? [String] ?? []), ["owner", "task"])
        let content = ((body["messages"] as? [[String: Any]])?.first?["content"] as? String) ?? ""
        XCTAssertTrue(content.contains("Weekly Ops Sync") && content.contains("David Webber: Hi"))
    }

    func testParsesSummaryAndActionItems() async throws {
        StubURLProtocol.handler = { _ in
            (200, self.reply(#"{"summary":"Agreed to ship cushions **Friday**.","topics":[{"title":"Freight","summary":"Rates went up **8%**."}],"action_items":[{"owner":"Alex Rivera","task":"confirm freight"},{"owner":null,"task":"update forecast"}],"decisions":[{"text":"Ship Friday","at_seconds":3128},{"text":"Hire two","at_seconds":null}],"headline":"Cushions ship Friday.","kind":"Planning","has_outcomes":true,"title":" Freight rates with Alex "}"#))
        }
        let result = try await summarizer().summarize(transcript: "t", title: "x")
        XCTAssertEqual(result.title, "Freight rates with Alex")
        XCTAssertEqual(result.summary, "Agreed to ship cushions **Friday**.")
        XCTAssertEqual(result.topics, [SummaryTopic(title: "Freight", summary: "Rates went up **8%**.")])
        XCTAssertEqual(result.actionItems, [ActionItem(owner: "Alex Rivera", task: "confirm freight"), ActionItem(owner: nil, task: "update forecast")])
        XCTAssertEqual(result.decisions, [Decision(text: "Ship Friday", at: 3128), Decision(text: "Hire two", at: nil)])
        XCTAssertEqual(result.headline, "Cushions ship Friday.")
        XCTAssertEqual(result.kind, "Planning")
        XCTAssertEqual(result.hasOutcomes, true)
    }

    func testPromptAsksForAShortOverviewTopicsDecisionsAndHeadline() {
        let p = LLMSummarizer.systemPrompt(owner: "Jordan Lee", organization: "")
        XCTAssertTrue(p.contains("3 to 4 plain sentences"))
        XCTAssertTrue(p.contains("topics"))
        XCTAssertTrue(p.contains("**bold**"))
        XCTAssertTrue(p.contains("kind"))
        XCTAssertTrue(p.contains("decision"))
        XCTAssertTrue(p.contains("140"))
    }

    func testMalformedReplyThrows() async {
        StubURLProtocol.handler = { _ in (200, self.reply("not json")) }
        do {
            _ = try await summarizer().summarize(transcript: "t", title: "x")
            XCTFail("expected error")
        } catch {}
    }

    func testRefusalThrows() async {
        StubURLProtocol.handler = { _ in (200, self.reply("", stop: "refusal")) }
        do {
            _ = try await summarizer().summarize(transcript: "t", title: "x")
            XCTFail("expected error")
        } catch {
            XCTAssertTrue("\(error)".contains("refus"))
        }
    }

    func testHTTPErrorThrows() async {
        StubURLProtocol.handler = { _ in (529, Data(#"{"type":"error"}"#.utf8)) }
        do {
            _ = try await summarizer().summarize(transcript: "t", title: "x")
            XCTFail("expected error")
        } catch {
            XCTAssertTrue("\(error)".contains("529"))
        }
    }

    func testLogsTokensWithTheModelThatAnswered() async throws {
        StubURLProtocol.handler = { _ in
            (200, json(["stop_reason": "end_turn", "model": "claude-opus-5-5",
                        "usage": ["input_tokens": 1200, "output_tokens": 300, "cache_read_input_tokens": 10, "cache_creation_input_tokens": 20],
                        "content": [["type": "text", "text": #"{"summary":"S","topics":[],"action_items":[],"decisions":[],"headline":"H","kind":"K","has_outcomes":false}"#]]]))
        }
        let log = UsageLog(directory: tempDirectory())
        let s = LLMSummarizer(apiKey: "k", session: StubURLProtocol.session(), usage: log)
        _ = try await UsageContext.$callID.withValue("call-2") { try await s.summarize(transcript: "x", title: "T") }
        let e = try XCTUnwrap(log.all().first)
        XCTAssertEqual(e.callID, "call-2")
        XCTAssertEqual(e.purpose, .summary)
        XCTAssertEqual(e.model, "claude-opus-5-5")
        XCTAssertEqual(e.inputTokens, 1200)
        XCTAssertEqual(e.outputTokens, 300)
        XCTAssertEqual(e.cacheReadTokens, 10)
        XCTAssertEqual(e.cacheWriteTokens, 20)
    }

    func testPromptGivesBookmarkedMomentsWeight() {
        XCTAssertTrue(LLMSummarizer.systemPrompt(owner: "David Webber", organization: "").contains("★ Bookmarked"))
    }

    func testSendsKnownTagsAndParsesTags() async throws {
        StubURLProtocol.handler = { _ in (200, self.reply(#"{"summary":"S","topics":[],"action_items":[],"decisions":[],"headline":"H","kind":"K","has_outcomes":false,"tags":["Databricks"," Budget ",""]}"#)) }
        let result = try await summarizer().summarize(transcript: "t", title: "x", knownTags: ["Databricks", "Triple Whale"])
        XCTAssertEqual(result.tags, ["Databricks", "Budget"])
        let body = try JSONSerialization.jsonObject(with: XCTUnwrap(StubURLProtocol.requests.first).body) as! [String: Any]
        let content = ((body["messages"] as? [[String: Any]])?.first?["content"] as? String) ?? ""
        XCTAssertTrue(content.contains("Known tags: Databricks, Triple Whale"), content)
    }

    private func reply(summary: String, topicText: String) -> [String: Any] {
        ["summary": summary, "topics": [["title": "Carrier rules", "summary": topicText]],
         "action_items": [["owner": "Alex Rivera", "task": "Pull the data"]], "decisions": [],
         "headline": "Alex and Sam tuned the carrier rules.", "kind": "Working session", "has_outcomes": true,
         "tags": ["Carriers"], "title": ""]
    }

    // A 35-minute call came back with action items but no overview, no topic text, and no decisions; it replaced
    // a good summary. A reply like that is not a summary.
    func testAReplyWithoutAnOverviewIsNotASummary() async {
        let s = LLMSummarizer(llm: FakeModel(output: reply(summary: " ", topicText: "Ten days for the slow carrier.")))
        do {
            _ = try await s.summarize(transcript: "[00:00:01] Alex Rivera: Hi", title: "Google Meet call")
            XCTFail("A blank overview was accepted")
        } catch {
            guard case SummaryError.malformed = error else { return XCTFail("Unexpected error: \(error)") }
        }
    }

    func testATopicWithoutTextIsNotASummary() async {
        let s = LLMSummarizer(llm: FakeModel(output: reply(summary: "Alex and Sam tuned the rules.", topicText: "")))
        do {
            _ = try await s.summarize(transcript: "[00:00:01] Alex Rivera: Hi", title: "Google Meet call")
            XCTFail("A topic without text was accepted")
        } catch {
            guard case SummaryError.malformed = error else { return XCTFail("Unexpected error: \(error)") }
        }
    }

    func testACompleteReplyIsKept() async throws {
        let s = LLMSummarizer(llm: FakeModel(output: reply(summary: "Alex and Sam tuned the rules.", topicText: "Ten days for the slow carrier.")))
        let out = try await s.summarize(transcript: "[00:00:01] Alex Rivera: Hi", title: "Google Meet call")
        XCTAssertEqual(out.summary, "Alex and Sam tuned the rules.")
        XCTAssertEqual(out.topics.map(\.summary), ["Ten days for the slow carrier."])
    }
}
