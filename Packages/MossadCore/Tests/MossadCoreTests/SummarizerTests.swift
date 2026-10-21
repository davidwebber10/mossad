import XCTest
@testable import MossadCore

final class SummarizerTests: XCTestCase {
    func summarizer() -> ClaudeSummarizer {
        ClaudeSummarizer(apiKey: "ant-key", session: StubURLProtocol.session())
    }

    func testPromptNamesTheOwnerAndOrganization() {
        XCTAssertTrue(ClaudeSummarizer.systemPrompt(owner: "Jordan Lee", organization: "Acme").contains("internal Acme meeting transcripts for Jordan Lee"))
        XCTAssertTrue(ClaudeSummarizer.systemPrompt(owner: "Jordan Lee", organization: "").contains("meeting transcripts for Jordan Lee"))
        XCTAssertFalse(ClaudeSummarizer.systemPrompt(owner: "Jordan Lee", organization: "").contains("internal"))
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
                       ["summary", "topics", "action_items", "decisions", "headline", "kind", "has_outcomes"])
        let topic = ((schema?["properties"] as? [String: Any])?["topics"] as? [String: Any])?["items"] as? [String: Any]
        XCTAssertEqual(Set(topic?["required"] as? [String] ?? []), ["title", "summary"])
        let props = schema?["properties"] as? [String: Any]
        let item = (props?["action_items"] as? [String: Any])?["items"] as? [String: Any]
        XCTAssertEqual(Set(item?["required"] as? [String] ?? []), ["owner", "task"])
        let content = ((body["messages"] as? [[String: Any]])?.first?["content"] as? String) ?? ""
        XCTAssertTrue(content.contains("Weekly Ops Sync") && content.contains("David Webber: Hi"))
    }

    func testParsesSummaryAndActionItems() async throws {
        StubURLProtocol.handler = { _ in
            (200, self.reply(#"{"summary":"Agreed to ship cushions **Friday**.","topics":[{"title":"Freight","summary":"Rates went up **8%**."}],"action_items":[{"owner":"Alex Rivera","task":"confirm freight"},{"owner":null,"task":"update forecast"}],"decisions":["Ship Friday"],"headline":"Cushions ship Friday.","kind":"Planning","has_outcomes":true}"#))
        }
        let result = try await summarizer().summarize(transcript: "t", title: "x")
        XCTAssertEqual(result.summary, "Agreed to ship cushions **Friday**.")
        XCTAssertEqual(result.topics, [SummaryTopic(title: "Freight", summary: "Rates went up **8%**.")])
        XCTAssertEqual(result.actionItems, [ActionItem(owner: "Alex Rivera", task: "confirm freight"), ActionItem(owner: nil, task: "update forecast")])
        XCTAssertEqual(result.decisions, ["Ship Friday"])
        XCTAssertEqual(result.headline, "Cushions ship Friday.")
        XCTAssertEqual(result.kind, "Planning")
        XCTAssertEqual(result.hasOutcomes, true)
    }

    func testPromptAsksForAShortOverviewTopicsDecisionsAndHeadline() {
        let p = ClaudeSummarizer.systemPrompt(owner: "Jordan Lee", organization: "")
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
}
