import XCTest
@testable import MossadCore

final class CommitmentTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    private let cal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/Chicago")!
        return c
    }()

    private func item(_ text: String, due: Date? = nil, call: String? = "c1", updated: Date? = nil) -> Commitment {
        var c = Commitment(text: text, to: "Jon", callID: call, callTitle: "Budget", madeAt: t0, due: due, created: t0)
        c.updated = updated ?? t0
        return c
    }

    func testStatusFollowsTheDueDayAndDone() {
        let now = t0.addingTimeInterval(3 * 86_400)
        XCTAssertEqual(item("A", due: t0).status(now: now, calendar: cal), .overdue)
        XCTAssertEqual(item("B", due: now).status(now: now, calendar: cal), .dueToday)
        XCTAssertEqual(item("C", due: now.addingTimeInterval(86_400)).status(now: now, calendar: cal), .upcoming)
        XCTAssertEqual(item("D").status(now: now, calendar: cal), .noDate)
        var done = item("E", due: t0)
        done.done = now
        XCTAssertEqual(done.status(now: now, calendar: cal), .done)
    }

    func testBookAddsFoundCommitmentsOncePerCallAndMarksTheCallChecked() {
        var book = CommitmentBook()
        book.add(found: [item("Send the forecast"), item("send the forecast ")], callID: "c1", at: t0)
        book.add(found: [item("Send the forecast")], callID: "c1", at: t0)
        XCTAssertEqual(book.visible.map(\.text), ["Send the forecast"])
        XCTAssertTrue(book.checked.contains("c1"))
    }

    func testEditsDoneAndDeleteBumpTheChangeDate() {
        var book = CommitmentBook()
        book.add(found: [item("Send the forecast")], callID: "c1", at: t0)
        let id = book.visible[0].id
        book.update(id, at: t0.addingTimeInterval(10)) { $0.done = t0.addingTimeInterval(10) }
        XCTAssertNotNil(book.visible[0].done)
        book.update(id, at: t0.addingTimeInterval(20)) { $0.done = nil; $0.text = "Send the '27 forecast" }
        XCTAssertEqual(book.visible[0].text, "Send the '27 forecast")
        book.delete(id, at: t0.addingTimeInterval(30))
        XCTAssertTrue(book.visible.isEmpty)
        XCTAssertEqual(book.items.count, 1, "A deleted commitment stays as a marker so another device does not bring it back")
    }

    func testMergeKeepsTheNewerCopyOfEachCommitmentAndAllCheckedCalls() {
        var mac = CommitmentBook()
        mac.add(found: [item("Send the forecast")], callID: "c1", at: t0)
        var phone = mac
        let id = mac.visible[0].id
        phone.update(id, at: t0.addingTimeInterval(50)) { $0.done = t0.addingTimeInterval(50) }
        mac.add(found: [item("Book the room", call: "c2")], callID: "c2", at: t0.addingTimeInterval(60))
        let merged = mac.merged(with: phone)
        XCTAssertEqual(Set(merged.visible.map(\.text)), ["Send the forecast", "Book the room"])
        XCTAssertNotNil(merged.visible.first { $0.id == id }?.done)
        XCTAssertEqual(merged.checked, ["c1", "c2"])
        var deleted = phone
        deleted.delete(id, at: t0.addingTimeInterval(70))
        XCTAssertFalse(mac.merged(with: deleted).visible.contains { $0.id == id })
    }

    func testBookSavesAndLoads() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        var book = CommitmentBook()
        book.add(found: [item("Send the forecast", due: t0)], callID: "c1", at: t0)
        try book.save(to: dir)
        XCTAssertEqual(try CommitmentBook.load(from: dir), book)
        XCTAssertEqual(try CommitmentBook.load(from: dir.appendingPathComponent("none")), CommitmentBook())
    }

    // MARK: Finding them

    private func reply(_ text: String) -> Data {
        json(["stop_reason": "end_turn", "content": [["type": "text", "text": text]]])
    }

    func testFinderReadsTheOwnersPromisesWithDueDates() async throws {
        let out: [String: Any] = ["commitments": [
            ["text": "Build the side forecast with the Salsify deltas", "to": "Jon Hueni", "due": "2026-10-27",
             "quote": "I'll have that by Tuesday", "at_seconds": 1962],
            ["text": "Write up the price-increase idea", "to": NSNull(), "due": NSNull(), "quote": "I'll write that up", "at_seconds": NSNull()],
        ]]
        StubURLProtocol.handler = { _ in (200, self.reply(String(decoding: json(out), as: UTF8.self))) }
        var r = CallRecord(id: "c9", platform: .meet, bundleID: "", start: t0, end: t0.addingTimeInterval(1800), status: .written)
        r.calendarTitle = "Budget"
        r.speakerNames = ["me:A": "David Webber"]
        r.utterances = [Utterance(track: .me, speakerLabel: "A", start: 1962, end: 1965, text: "I'll have that by Tuesday"),
                        Utterance(track: .me, speakerLabel: "A", start: 2100, end: 2104, text: "Sure, I'll write that up for you.")]
        let finder = CommitmentFinder(llm: AnthropicModel(apiKey: "k", model: "m", session: StubURLProtocol.session(), usage: nil), ownerName: "David Webber")
        let found = try await finder.find(in: r)
        XCTAssertEqual(found.count, 2)
        XCTAssertEqual(found[0].to, "Jon Hueni")
        XCTAssertEqual(found[0].callID, "c9")
        XCTAssertEqual(found[0].madeAt, t0.addingTimeInterval(1962))
        XCTAssertEqual(found[0].due.map { Calendar.current.dateComponents([.year, .month, .day], from: $0) },
                       DateComponents(year: 2026, month: 10, day: 27))
        XCTAssertNil(found[1].due)
        let body = String(decoding: try XCTUnwrap(StubURLProtocol.requests.first).body, as: UTF8.self)
        XCTAssertTrue(body.contains("I'll have that by Tuesday"), "The transcript goes to the model")
    }

    func testRunnerPicksWrittenCallsWithSpeechSinceTheStartNotYetChecked() {
        func rec(_ id: String, _ days: Double, _ status: CallStatus = .written) -> CallRecord {
            var r = CallRecord(id: id, platform: .meet, bundleID: "", start: t0.addingTimeInterval(days * 86_400), end: t0, status: status)
            r.utterances = [Utterance(track: .me, speakerLabel: "A", start: 0, end: 1, text: "Hi")]
            return r
        }
        let records = [rec("old", -20), rec("a", -1), rec("b", -2), rec("rec", -1, .recording), rec("done", -3)]
        let due = CommitmentRunner.pending(records, since: t0.addingTimeInterval(-14 * 86_400), checked: ["done"])
        XCTAssertEqual(due.map(\.id), ["b", "a"])
    }
}

final class CommitmentSyncTests: XCTestCase {
    func testTheBookTravelsAsOneSharedRecord() {
        var book = CommitmentBook()
        book.add(found: [Commitment(text: "Send it", to: nil, callID: "c", callTitle: "T", madeAt: Date(), due: nil)], callID: "c", at: Date())
        let p = SharedPayload.commitments(book)
        XCTAssertEqual(p.key, "commitments")
        XCTAssertEqual(CloudSync.recordID(p.key).recordName, "commitments")
        XCTAssertEqual(SyncState().planShared([p]).upload.map(\.key), ["commitments"])
    }
}

final class CommitmentGroupTests: XCTestCase {
    func testGroupsGoFromMostUrgentToDone() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "America/Chicago")!
        let now = Date(timeIntervalSince1970: 1_800_000_000) // a Friday
        func c(_ text: String, _ days: Double?, done: Bool = false) -> Commitment {
            var x = Commitment(text: text, to: nil, callID: nil, callTitle: nil, madeAt: now, due: days.map { now.addingTimeInterval($0 * 86_400) })
            if done { x.done = now }
            return x
        }
        let groups = CommitmentGroup.make([c("late", -2), c("today", 0), c("soon", 1), c("later", 20), c("none", nil), c("finished", -1, done: true)],
                                          now: now, calendar: cal)
        XCTAssertEqual(groups.map(\.kind), [.overdue, .today, .thisWeek, .later, .noDate, .done])
        XCTAssertEqual(groups.map { $0.items.map(\.text) }, [["late"], ["today"], ["soon"], ["later"], ["none"], ["finished"]])
    }
}

final class CommitmentOwnerTests: XCTestCase {
    private func record() -> CallRecord {
        var r = CallRecord(id: "c", platform: .meet, bundleID: "", start: Date(), end: Date(), status: .written)
        r.speakerNames = ["me:A": "Dana", "them:A": "Pat"]
        r.utterances = [
            Utterance(track: .them, speakerLabel: "A", start: 10, end: 14, text: "But let me confirm that, I'll check the flight."),
            Utterance(track: .me, speakerLabel: "A", start: 20, end: 26, text: "Okay. I'm gonna give you access to the budget sheet today."),
        ]
        return r
    }

    func testOnlyQuotesFromTheOwnersOwnLinesCount() {
        let r = record()
        XCTAssertEqual(CommitmentFinder.ownerLine(quote: "I'm gonna give you access", at: 99, in: r, owner: "Dana")?.start, 20)
        XCTAssertNil(CommitmentFinder.ownerLine(quote: "But let me confirm that.", at: 20, in: r, owner: "Dana"), "Someone else said it")
        // A quote that is in nobody's line is not proof, wherever it points.
        XCTAssertNil(CommitmentFinder.ownerLine(quote: "I will share the sheet", at: 21, in: r, owner: "Dana"))
        // Without a real quote, the line at the given time decides.
        XCTAssertEqual(CommitmentFinder.ownerLine(quote: "", at: 21, in: r, owner: "Dana")?.start, 20)
        XCTAssertNil(CommitmentFinder.ownerLine(quote: "", at: 11, in: r, owner: "Dana"))
    }

    func testCleaningDropsFoundCommitmentsOthersMadeButKeepsHandAddedOnes() {
        let r = record()
        var book = CommitmentBook()
        book.add(found: [
            Commitment(text: "Give access", to: "Pat", callID: "c", callTitle: "T", madeAt: Date(), at: 20, quote: "give you access", due: nil),
            Commitment(text: "Confirm the flight", to: "Dana", callID: "c", callTitle: "T", madeAt: Date(), at: 10, quote: "let me confirm that", due: nil),
        ], callID: "c", at: Date())
        book.items.append(Commitment(text: "Mine by hand", to: nil, callID: nil, callTitle: nil, madeAt: Date(), due: nil))
        book.dropOthers(records: [r], owner: "Dana", at: Date())
        XCTAssertEqual(book.visible.map(\.text), ["Give access", "Mine by hand"])
    }
}

final class CommitmentEncodingTests: XCTestCase {
    func testTheBookEncodesTheSameWhateverTheOrderCallsWereChecked() throws {
        var a = CommitmentBook(), b = CommitmentBook()
        for id in ["c3", "c1", "c2", "c9", "c5"] { a.checked.insert(id) }
        for id in ["c9", "c2", "c5", "c1", "c3"] { b.checked.insert(id) }
        XCTAssertEqual(SharedPayload.commitments(a).hash, SharedPayload.commitments(b).hash)
        let text = String(decoding: try JSONEncoder.callRecord.encode(a), as: UTF8.self)
        XCTAssertTrue(text.contains(#"["c1","c2","c3","c5","c9"]"#) || text.contains("\"c1\",\n"), text)
    }
}

final class SyncPlanSharedKeysTests: XCTestCase {
    func testMeetingSyncNeverDeletesSharedRecords() {
        var state = SyncState()
        for key in ["call-1", "chat:ABC", "notes:call-1", "profile", "commitments"] { state.uploaded[key] = "h" }
        // No meetings left: only the meeting is deleted, never the chats, notes, memory, or commitments.
        XCTAssertEqual(state.plan([]).delete, ["call-1"])
    }
}
