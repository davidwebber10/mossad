import XCTest
@testable import MossadCore

/// The action tools over files: a receipt for what ran, a card for what waits, the limit, and Undo after a relaunch.
final class ChatActionToolsTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private var paths: Paths!

    private var people: [Person] {
        let owner = Person(id: PersonID(rawValue: "id-owner"), displayName: "Avery Webb", isOwner: true, origin: .owner, at: now)
        var jeff = Person(id: PersonID(rawValue: "id-jeff"), displayName: "Jeffrey Moore", origin: .migration, at: now)
        jeff.emails = [EmailIdentity(address: "jeff@example.com", state: .verified, source: .owner, at: now)]
        return [owner, jeff]
    }

    private func record() -> CallRecord {
        var r = CallRecord(id: "c1", platform: .meet, bundleID: "b", start: now.addingTimeInterval(-86_400), end: now.addingTimeInterval(-84_600), status: .written)
        r.calendarTitle = "Planning"
        r.speakerNames = ["me:A": "Avery Webb"]
        r.utterances = [Utterance(track: .me, speakerLabel: "A", start: 0, end: 30, text: "Hello."),
                        Utterance(track: .them, speakerLabel: "C", start: 30, end: 60, text: "Hi.")]
        return r
    }

    override func setUpWithError() throws {
        paths = Paths(root: tempDirectory())
        try paths.ensureDirectories()
    }

    private func actions(_ message: String, live: Bool = false, host: ChatActionHost? = nil) -> ChatActions {
        let tools = ChatTools(records: [record()], owner: "Avery Webb", paths: paths, people: people, settings: ToolSettings(), now: now)
        return ChatActions(message: message, tools: tools, host: host ?? ChatActionHost(paths: paths), live: live)
    }

    func testANoteForMyNextMeetingWithJeffIsSavedWithAReceipt() throws {
        let a = actions("Please add a note to my and Jeff's next meeting to discuss the budget")
        let reply = try XCTUnwrap(a.run("add_point", input: ["text": "Discuss the budget", "with": "Jeff"]))
        XCTAssertTrue(reply.hasPrefix("Done: Saved for the next time you see Jeffrey Moore"), reply)
        XCTAssertEqual(NextTimeBook.peek(in: paths.nextTime)?.visible.map(\.personID), ["id-jeff"])
        let receipt = try XCTUnwrap(a.records.first)
        XCTAssertEqual(receipt.state, .done)
        XCTAssertEqual(receipt.place, "mossad://person/id-jeff")
        XCTAssertEqual(receipt.undo?.kind, .removePoint)
    }

    func testUndoWorksAfterARelaunchOnlyWhileTheTargetIsUnchanged() throws {
        let a = actions("Remind me to send the deck to Jeff by Friday")
        _ = a.run("add_task", input: ["text": "Send the deck", "to": "Jeff", "due": "2027-01-16"])
        let receipt = try XCTUnwrap(a.records.first)
        let saved = try JSONDecoder().decode(ChatActionRecord.self, from: JSONEncoder().encode(receipt))
        // A new host, as after a relaunch.
        var book = try CommitmentBook.load(from: paths.commitments)
        book.items[0].text = "Send the deck and the notes"
        try book.save(to: paths.commitments)
        XCTAssertEqual(ChatActionHost(paths: paths).undo(saved, now: now), .changedSince)
        book.items[0].text = "Send the deck"
        try book.save(to: paths.commitments)
        XCTAssertEqual(ChatActionHost(paths: paths).undo(saved, now: now), .undone)
        XCTAssertTrue(try CommitmentBook.load(from: paths.commitments).visible.isEmpty)
    }

    func testAToolResultIsNoReasonToActAndNothingIsWritten() throws {
        let a = actions("What did Jeff say about the budget?")
        let reply = try XCTUnwrap(a.run("add_point", input: ["text": "Discuss the budget", "with": "Jeff"]))
        XCTAssertTrue(reply.hasPrefix("Proposed, not done"), reply)
        XCTAssertEqual(NextTimeBook.peek(in: paths.nextTime)?.visible.count, 0)
        XCTAssertEqual(a.records.first?.state, .proposed)
    }

    func testTheFourthActionJoinsOneCard() {
        let a = actions("Add these points for Jeff: a, b, c, d")
        for t in ["a", "b", "c", "d"] { _ = a.run("add_point", input: ["text": t, "person": "Jeffrey Moore"]) }
        XCTAssertEqual(NextTimeBook.peek(in: paths.nextTime)?.visible.count, 3)
        XCTAssertEqual(a.records.filter { $0.state == .done }.count, 3)
        let card = a.records.last
        XCTAssertEqual(card?.request.kind, .batch)
        XCTAssertEqual(card?.request.items?.map(\.text), ["d"])
    }

    func testTheRiskierOnesWaitForAClickAndAreNotOfferedDuringACall() throws {
        let a = actions("Speaker C is Dana Cole")
        let reply = try XCTUnwrap(a.run("name_voice", input: ["call_id": "c1", "speaker": "Speaker A", "name": "Dana Cole"]))
        XCTAssertTrue(reply.hasPrefix("Proposed, not done: Name Speaker A in Planning as Dana Cole"), reply)
        XCTAssertEqual(a.records.first?.request.speakerKey, "them:C")
        XCTAssertFalse(ChatActions.definitions(live: true).map(\.name).contains("name_voice"))
        XCTAssertTrue(ChatActions.definitions(live: true).map(\.name).contains("bookmark_now"))
        XCTAssertEqual(actions("Speaker C is Dana Cole", live: true).run("name_voice", input: ["call_id": "c1", "speaker": "Speaker A", "name": "Dana Cole"]),
                       "Not done: That waits for the end of the call.")
    }

    func testDuringACallATickIsAtThisMomentAndTheBookmarkGoesThroughTheHost() throws {
        var book = NextTimeBook()
        let p = try XCTUnwrap(book.add("Ask about hiring", personID: "id-jeff", personName: "Jeffrey Moore", at: now))
        try book.save(to: paths.nextTime)
        let marks = Marks()
        let host = ChatActionHost(paths: paths, liveMoment: { ("live", 125) }, bookmarkNow: { note in marks.add(note); return 125 })
        let a = actions("Tick the hiring point and bookmark this moment", live: true, host: host)
        XCTAssertTrue(a.run("change_point", input: ["point_id": p.id.uuidString, "change": "tick"])?.hasPrefix("Done") == true)
        let done = NextTimeBook.peek(in: paths.nextTime)?.points.first?.done
        XCTAssertEqual(done?.callID, "live")
        XCTAssertEqual(done?.at, 125)
        XCTAssertEqual(done?.byOwner, true)
        XCTAssertTrue(a.run("bookmark_now", input: ["note": "Hiring"])?.hasPrefix("Done") == true)
        XCTAssertEqual(marks.notes, ["Hiring"])
        XCTAssertEqual(a.records.last?.place, "mossad://call/live?t=125")
    }

    func testTheChatOffersActionsAndTheMCPKeepsItsOneWrite() {
        let chat = Set(ChatAgent.tools(paths: paths, actions: true).map(\.name))
        XCTAssertTrue(chat.isSuperset(of: ["add_point", "add_task", "name_voice"]))
        XCTAssertFalse(chat.contains("add_next_time_point"))
        let mcp = Set(MCPServer.tools.map(\.name))
        XCTAssertTrue(mcp.isDisjoint(with: ChatActions.names))
        XCTAssertTrue(mcp.contains("add_next_time_point"))
    }

    func testTasksListTheirIdsForTheActions() throws {
        var book = CommitmentBook()
        book.items = [Commitment(text: "Send the deck", to: nil, callID: nil, callTitle: nil, madeAt: now, due: nil)]
        try book.save(to: paths.commitments)
        let tools = ChatTools(records: [record()], owner: "Avery Webb", paths: paths, people: people, settings: ToolSettings(), now: now)
        XCTAssertTrue(tools.run("commitments", input: [:]).contains("task_id: \(book.items[0].id.uuidString)"))
    }
}

private final class Marks: @unchecked Sendable {
    private let lock = NSLock()
    private var list: [String?] = []
    func add(_ note: String?) { lock.withLock { list.append(note) } }
    var notes: [String?] { lock.withLock { list } }
}
