import XCTest
@testable import MossadCore

final class SummarizerTests: XCTestCase {
    func summarizer() -> ClaudeSummarizer {
        ClaudeSummarizer(apiKey: "ant-key", session: StubURLProtocol.session())
    }

    func reply(_ text: String, stop: String = "end_turn") -> Data {
        json(["id": "msg_1", "type": "message", "role": "assistant", "stop_reason": stop,
              "content": [["type": "thinking", "thinking": "", "signature": "x"], ["type": "text", "text": text]]])
    }

    func testSendsModelHeadersAndSchema() async throws {
        StubURLProtocol.handler = { _ in (200, self.reply(#"{"summary":"S","action_items":[]}"#)) }
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
        let content = ((body["messages"] as? [[String: Any]])?.first?["content"] as? String) ?? ""
        XCTAssertTrue(content.contains("Weekly Ops Sync") && content.contains("David Webber: Hi"))
    }

    func testParsesSummaryAndActionItems() async throws {
        StubURLProtocol.handler = { _ in
            (200, self.reply(#"{"summary":"Agreed to ship cushions Friday.","action_items":["Alex Rivera: confirm freight","David Webber: update forecast"]}"#))
        }
        let result = try await summarizer().summarize(transcript: "t", title: "x")
        XCTAssertEqual(result.summary, "Agreed to ship cushions Friday.")
        XCTAssertEqual(result.actionItems, ["Alex Rivera: confirm freight", "David Webber: update forecast"])
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
