import XCTest
@testable import MossadCore

final class ChatTests: XCTestCase {
    private let base = Date(timeIntervalSince1970: 1_800_000_000)

    private func meeting(_ id: String, day: Double, title: String, people: [String], lines: [String] = ["Let us start.", "Sounds good."],
                         tags: [String] = [], items: [ActionItem] = []) -> CallRecord {
        let start = base.addingTimeInterval(day * 86_400)
        var r = CallRecord(id: id, platform: .meet, bundleID: "", start: start, end: start.addingTimeInterval(1800), status: .written)
        r.calendarTitle = title
        r.speakerNames = ["me:A": "David Webber"]
        for (i, p) in people.enumerated() { r.speakerNames["them:\(Character(UnicodeScalar(UInt8(65 + i))))"] = p }
        let keys = r.speakerNames.keys.sorted()
        r.utterances = lines.enumerated().map { i, text in
            let key = keys[i % keys.count]
            return Utterance(track: key.hasPrefix("me") ? .me : .them, speakerLabel: String(key.split(separator: ":")[1]),
                             start: Double(i * 30), end: Double(i * 30 + 20), text: text)
        }
        r.tags = tags
        r.actionItems = items
        r.summary = "Summary of \(title)."
        r.headline = "Headline of \(title)."
        return r
    }

    private lazy var records = [
        meeting("old", day: 1, title: "Planning", people: ["Jennifer Lee", "Austin Ray"], tags: ["Budget"]),
        meeting("both", day: 5, title: "Launch sync", people: ["Jennifer Lee", "Austin Ray"],
                lines: ["Where are we?", "Austin will send the deck by Friday.", "Jen owns the pricing page."],
                items: [ActionItem(owner: "Austin Ray", task: "send the deck by Friday"), ActionItem(owner: "Jennifer Lee", task: "own the pricing page")]),
        meeting("mitch", day: 9, title: "Data review", people: ["Mitch Haus"], lines: ["Supermetrics renews in December."], tags: ["Supermetrics"]),
    ]

    private var tools: ChatTools { ChatTools(records: records, owner: "David Webber") }

    // MARK: Tools

    func testFindMeetingsByShortNamesNewestFirst() {
        let found = tools.findMeetings(people: ["Jen", "Austin"])
        XCTAssertEqual(found.map(\.id), ["both", "old"])
        XCTAssertEqual(tools.findMeetings(people: ["Mitch"]).map(\.id), ["mitch"])
    }

    func testFindMeetingsByDatesTagAndWords() {
        XCTAssertEqual(tools.findMeetings(from: base.addingTimeInterval(4 * 86_400)).map(\.id), ["mitch", "both"])
        XCTAssertEqual(tools.findMeetings(to: base.addingTimeInterval(2 * 86_400)).map(\.id), ["old"])
        XCTAssertEqual(tools.findMeetings(tag: "budget").map(\.id), ["old"])
        XCTAssertEqual(tools.findMeetings(query: "supermetrics").map(\.id), ["mitch"])
    }

    func testSearchTranscriptsReturnsLinesWithTheirMeetingAndTime() {
        let hits = tools.searchTranscripts(query: "deck")
        XCTAssertEqual(hits.count, 1)
        XCTAssertEqual(hits.first?.callID, "both")
        XCTAssertEqual(hits.first?.at, 30)
        XCTAssertTrue(hits.first?.line.contains("Austin will send the deck by Friday.") == true)
    }

    func testReadMeetingHasTheSummaryItemsAndTheFullTranscript() throws {
        let text = try XCTUnwrap(tools.readMeeting("both"))
        XCTAssertTrue(text.contains("Launch sync"))
        XCTAssertTrue(text.contains("Austin Ray: send the deck by Friday"))
        XCTAssertTrue(text.contains("[00:00:30]"))
        XCTAssertTrue(text.contains("Jen owns the pricing page."))
        XCTAssertNil(tools.readMeeting("nope"))
    }

    func testActionItemsByOwner() {
        let items = tools.actionItems(owner: "austin")
        XCTAssertEqual(items.map(\.task), ["send the deck by Friday"])
        XCTAssertEqual(items.first?.callID, "both")
    }

    func testRunDispatchesByToolNameAndReportsBadInput() {
        XCTAssertTrue(tools.run("find_meetings", input: ["people": ["Mitch"]]).contains("call_id: mitch"))
        XCTAssertTrue(tools.run("read_meeting", input: ["call_id": "zzz"]).contains("No meeting"))
        XCTAssertTrue(tools.run("unknown", input: [:]).contains("Unknown tool"))
    }

    // MARK: Agent loop

    private func reply(_ content: [[String: Any]], stop: String) -> Data {
        json(["stop_reason": stop, "model": "claude-opus-5-5", "usage": ["input_tokens": 10, "output_tokens": 5], "content": content])
    }

    func testTheAgentRunsToolsUntilItAnswers() async throws {
        var round = 0
        StubURLProtocol.handler = { _ in
            round += 1
            if round == 1 {
                return (200, self.reply([["type": "thinking", "thinking": "", "signature": "sig"],
                                         ["type": "tool_use", "id": "t1", "name": "find_meetings", "input": ["people": ["Jen"]]]], stop: "tool_use"))
            }
            return (200, self.reply([["type": "text", "text": "Austin will send the deck by Friday. [Launch sync](mossad://call/both?t=30)"]], stop: "end_turn"))
        }
        let log = UsageLog(directory: tempDirectory())
        let agent = ChatAgent(apiKey: "k", session: StubURLProtocol.session(), ownerName: "David Webber", usage: log)
        let steps = StepCollector()
        let answer = try await agent.answer("What did Jen agree to?", history: [], records: records) { steps.add($0) }
        XCTAssertTrue(answer.contains("mossad://call/both?t=30"))
        XCTAssertEqual(steps.all, ["Finding meetings with Jen"])
        XCTAssertEqual(log.all().count, 2)

        let second = try JSONSerialization.jsonObject(with: StubURLProtocol.requests[1].body) as! [String: Any]
        let messages = second["messages"] as! [[String: Any]]
        XCTAssertEqual(messages.map { $0["role"] as! String }, ["user", "assistant", "user"])
        // The assistant turn goes back unchanged, thinking included.
        XCTAssertEqual((messages[1]["content"] as! [[String: Any]]).first?["type"] as? String, "thinking")
        let result = (messages[2]["content"] as! [[String: Any]]).first!
        XCTAssertEqual(result["type"] as? String, "tool_result")
        XCTAssertEqual(result["tool_use_id"] as? String, "t1")
        XCTAssertTrue((result["content"] as? String)?.contains("call_id: both") == true)
        let tools = second["tools"] as! [[String: Any]]
        XCTAssertEqual(Set(tools.map { $0["name"] as! String }), ["find_meetings", "search_transcripts", "read_meeting", "action_items", "current_call"])
    }

    func testEarlierTurnsGoFirst() async throws {
        StubURLProtocol.handler = { _ in (200, self.reply([["type": "text", "text": "Yes."]], stop: "end_turn")) }
        let agent = ChatAgent(apiKey: "k", session: StubURLProtocol.session(), ownerName: "David Webber")
        _ = try await agent.answer("Was there a deadline?", history: [ChatMessage(role: .user, text: "What did Jen agree to?"),
                                                                       ChatMessage(role: .assistant, text: "To own the pricing page.")],
                                   records: records) { _ in }
        let body = try JSONSerialization.jsonObject(with: StubURLProtocol.requests[0].body) as! [String: Any]
        let messages = body["messages"] as! [[String: Any]]
        XCTAssertEqual(messages.map { $0["role"] as! String }, ["user", "assistant", "user"])
        XCTAssertEqual(messages[2]["content"] as? String, "Was there a deadline?")
    }

    func testLinksParseToAMeetingAndTime() {
        XCTAssertEqual(ChatLink.parse(URL(string: "mossad://call/both?t=30")!), ChatLink(callID: "both", at: 30))
        XCTAssertEqual(ChatLink.parse(URL(string: "mossad://call/both")!), ChatLink(callID: "both", at: nil))
        XCTAssertNil(ChatLink.parse(URL(string: "https://example.com")!))
    }

    // MARK: Store

    func testChatsSaveListAndDelete() throws {
        let store = ChatStore(directory: tempDirectory())
        var chat = Chat(title: "Jen and Austin")
        chat.messages = [ChatMessage(role: .user, text: "Hi"), ChatMessage(role: .assistant, text: "Hello")]
        try store.save(chat)
        var later = Chat(title: "Budget")
        later.updated = chat.updated.addingTimeInterval(60)
        try store.save(later)
        XCTAssertEqual(store.all().map(\.title), ["Budget", "Jen and Austin"])
        XCTAssertEqual(store.all().last?.messages.count, 2)
        store.delete(later.id)
        XCTAssertEqual(store.all().map(\.title), ["Jen and Austin"])
    }

    func testATitleComesFromTheFirstQuestion() {
        XCTAssertEqual(Chat.title(from: "What did Jen and Austin agree to do last call, and was there a deadline we agreed on?"),
                       "What did Jen and Austin agree to do last call…")
        XCTAssertEqual(Chat.title(from: "Budget?"), "Budget?")
    }
}

private final class StepCollector: @unchecked Sendable {
    private(set) var all: [String] = []
    func add(_ s: String) { all.append(s) }
}
