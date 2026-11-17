import XCTest
@testable import MossadCore

/// A meeting that left (its ledger `removing` or `done`) and a call marked during its recording are not readable from
/// the first profile's tools (the app's chat, `--mcp`) or its digest; a written meeting that only waits is still its own.
final class MoveToolsHoldTests: XCTestCase {
    private let id = "20261101-100000"
    private let work = "1a2b3c4d"
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    private func temp() -> Paths {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("MoveToolsHoldTests-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return Paths(root: url)
    }

    private func ledger(_ a: Paths, _ state: MoveOut.State) throws {
        var out = MoveOut(callID: id, to: work, started: t0)
        out.state = state
        try out.save(a)
    }

    private func tools(_ a: Paths) -> ChatTools {
        ChatTools(records: ProcessingQueue(paths: a).allRecords(), owner: "Avery Webb", paths: a, settings: ToolSettings(), now: t0)
    }

    private let reads: [(String, [String: Any])] = [
        ("read_meeting", ["call_id": "20261101-100000"]),
        ("find_meetings", ["query": "Zebra"]),
        ("search_transcripts", ["query": "zebra crossing"]),
        ("action_items", [:]),
        ("bookmarks", [:]),
        ("list_screens", [:]),
        ("meeting_analytics", ["call_id": "20261101-100000"]),
        ("stats", [:]),
    ]

    private func answers(_ a: Paths) -> [String] { reads.map { tools(a).run($0.0, input: $0.1) } }

    private func digest(_ a: Paths) -> String {
        (ServerDigest.parts(tools(a), personasInMCP: true) ?? []).map { String(decoding: $0.data, as: UTF8.self) }.joined()
    }

    func testARemovingLedgerHidesTheMeeting() throws {
        for state in [MoveOut.State.removing, .done] {
            let a = temp()
            try writtenCall(in: a)
            XCTAssertTrue(tools(a).run("read_meeting", input: ["call_id": id]).contains("Zebra"))
            XCTAssertTrue(digest(a).contains(id))
            try ledger(a, state)
            for (name, answer) in zip(reads.map(\.0), answers(a)) {
                XCTAssertFalse(answer.contains(id) || answer.lowercased().contains("zebra"), "\(state) \(name): \(answer)")
            }
            XCTAssertFalse(digest(a).contains(id), "\(state)")
        }
    }

    func testAWaitingLedgerKeepsAWrittenMeeting() throws {
        let a = temp()
        var r = try writtenCall(in: a)
        r.moveTo = work
        try r.save(to: a.callDirectory(id))
        try ledger(a, .waiting)
        XCTAssertTrue(tools(a).run("read_meeting", input: ["call_id": id]).contains("Zebra"))
    }

    func testACallMarkedDuringItsRecordingIsHidden() throws {
        let a = temp()
        var r = try writtenCall(in: a)
        r.moveTo = work
        r.status = .recorded
        try r.save(to: a.callDirectory(id))
        for (name, answer) in zip(reads.map(\.0), answers(a)) {
            XCTAssertFalse(answer.contains(id) || answer.lowercased().contains("zebra"), "\(name): \(answer)")
        }
        XCTAssertFalse(digest(a).contains(id))
        // While it records, `current_call` gives nothing of it.
        r.status = .recording
        try r.save(to: a.callDirectory(id))
        XCTAssertEqual(tools(a).run("current_call", input: [:]), LiveOffReason.forOtherProfile.text)
    }

    func testWithNoLedgerNoMarkTheAnswersAreAsBefore() throws {
        let a = temp()
        try writtenCall(in: a)
        let records = ProcessingQueue(paths: a).allRecords()
        let plain = ChatTools(records: records, owner: "Avery Webb", paths: a, settings: ToolSettings(), now: t0, leaving: [])
        for (name, input) in reads {
            XCTAssertEqual(tools(a).run(name, input: input), plain.run(name, input: input), name)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: a.moves.path), "the read makes no folder")
    }
}
