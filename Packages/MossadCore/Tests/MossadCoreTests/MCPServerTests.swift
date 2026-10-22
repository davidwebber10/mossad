import XCTest
@testable import MossadCore

final class MCPServerTests: XCTestCase {
    private func server() throws -> MCPServer {
        let paths = Paths(root: tempDirectory())
        try paths.ensureDirectories()
        var r = CallRecord(id: "c1", platform: .meet, bundleID: "", start: Date(timeIntervalSince1970: 1_800_000_000),
                           end: Date(timeIntervalSince1970: 1_800_001_800), status: .written)
        r.calendarTitle = "Launch sync"
        r.speakerNames = ["me:A": "David Webber", "them:A": "Austin Ray"]
        r.utterances = [Utterance(track: .them, speakerLabel: "A", start: 30, end: 40, text: "I will send the deck by Friday.")]
        r.markdownPath = "/notes/Launch sync.md"
        try FileManager.default.createDirectory(at: paths.callDirectory("c1"), withIntermediateDirectories: true)
        try r.save(to: paths.callDirectory("c1"))
        return MCPServer(paths: paths, owner: "David Webber")
    }

    private func reply(_ s: MCPServer, _ request: [String: Any]) throws -> [String: Any]? {
        let line = String(decoding: try JSONSerialization.data(withJSONObject: request), as: UTF8.self)
        return s.handle(line).flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
    }

    func testInitializeEchoesTheProtocolVersionAndOffersTools() throws {
        let r = try XCTUnwrap(reply(try server(), ["jsonrpc": "2.0", "id": 1, "method": "initialize",
                                                   "params": ["protocolVersion": "2025-06-18", "capabilities": [:], "clientInfo": ["name": "t", "version": "1"]]]))
        let result = r["result"] as? [String: Any]
        XCTAssertEqual(r["id"] as? Int, 1)
        XCTAssertEqual(result?["protocolVersion"] as? String, "2025-06-18")
        XCTAssertNotNil((result?["capabilities"] as? [String: Any])?["tools"])
        XCTAssertEqual((result?["serverInfo"] as? [String: Any])?["name"] as? String, "mossad")
    }

    func testNotificationsGetNoReply() throws {
        XCTAssertNil(try reply(try server(), ["jsonrpc": "2.0", "method": "notifications/initialized"]))
    }

    func testListsTheMeetingTools() throws {
        let r = try XCTUnwrap(reply(try server(), ["jsonrpc": "2.0", "id": "a", "method": "tools/list"]))
        let tools = (r["result"] as? [String: Any])?["tools"] as? [[String: Any]] ?? []
        XCTAssertEqual(Set(tools.map { $0["name"] as! String }), ["find_meetings", "search_transcripts", "read_meeting", "action_items"])
        XCTAssertNotNil(tools.first?["inputSchema"])
        XCTAssertEqual(r["id"] as? String, "a")
    }

    func testCallsAToolAndIncludesTheNotePath() throws {
        let s = try server()
        let found = try XCTUnwrap(reply(s, ["jsonrpc": "2.0", "id": 2, "method": "tools/call", "params": ["name": "find_meetings", "arguments": ["people": ["Austin"]]]]))
        let text = (((found["result"] as? [String: Any])?["content"] as? [[String: Any]])?.first?["text"] as? String) ?? ""
        XCTAssertTrue(text.contains("call_id: c1"), text)
        XCTAssertTrue(text.contains("/notes/Launch sync.md"), text)
        let read = try XCTUnwrap(reply(s, ["jsonrpc": "2.0", "id": 3, "method": "tools/call", "params": ["name": "read_meeting", "arguments": ["call_id": "c1"]]]))
        let body = (((read["result"] as? [String: Any])?["content"] as? [[String: Any]])?.first?["text"] as? String) ?? ""
        XCTAssertTrue(body.contains("I will send the deck by Friday."))
    }

    func testUnknownMethodsAndToolsAreErrors() throws {
        let s = try server()
        let unknown = try XCTUnwrap(reply(s, ["jsonrpc": "2.0", "id": 4, "method": "resources/list"]))
        XCTAssertEqual((unknown["error"] as? [String: Any])?["code"] as? Int, -32601)
        let badTool = try XCTUnwrap(reply(s, ["jsonrpc": "2.0", "id": 5, "method": "tools/call", "params": ["name": "delete_everything", "arguments": [:]]]))
        XCTAssertEqual((badTool["result"] as? [String: Any])?["isError"] as? Bool, true)
        XCTAssertEqual(((try reply(s, ["jsonrpc": "2.0", "id": 6, "method": "ping"]))?["result"] as? [String: Any])?.isEmpty, true)
    }

    func testABadLineIsAParseError() throws {
        let r = try server().handle("not json").flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
        XCTAssertEqual((r?["error"] as? [String: Any])?["code"] as? Int, -32700)
    }
}
