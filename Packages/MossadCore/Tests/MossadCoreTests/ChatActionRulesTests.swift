import XCTest
@testable import MossadCore

/// The chat's actions: where "my and Jeff's next meeting" goes, the limit of one message, the owner's words as the
/// only reason to act, the class that needs a click, each inverse, and the saved form an older build still reads.
final class ChatActionRulesTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func person(_ id: String, _ name: String, email: String? = nil, owner: Bool = false) -> Person {
        var p = Person(id: PersonID(rawValue: id), displayName: name, isOwner: owner, origin: .migration, at: now)
        if let email { p.emails = [EmailIdentity(address: email, state: .verified, source: .owner, at: now)] }
        return p
    }

    private var owner: Person { person("id-owner", "Avery Webb", email: "avery@example.com", owner: true) }
    private var jeff: Person { person("id-jeff", "Jeffrey Moore", email: "jeff@example.com") }

    private func invite(_ title: String, days: Double, _ attendees: [String], series: String? = nil) -> UpcomingMeeting {
        UpcomingMeeting(title: title, start: now.addingTimeInterval(days * 86_400), end: now.addingTimeInterval(days * 86_400 + 1800),
                        attendees: attendees, platform: .meet, link: nil, seriesID: series)
    }

    private func series(_ id: String, _ title: String, people: [String], next: UpcomingMeeting? = nil) -> MeetingSeries {
        MeetingSeries(id: id, keys: [id], title: title, meetings: [], upcoming: next.map { [$0] } ?? [], cadence: nil, recurringInCalendar: true,
                      usualPeople: people)
    }

    private func resolve(_ words: String, people: [Person], upcoming: [UpcomingMeeting] = [], series: [MeetingSeries] = []) -> PointTarget.Outcome {
        PointTarget.resolve(with: words, people: people, upcoming: upcoming, series: series, now: now)
    }

    // MARK: "My and Jeff's next meeting"

    func testTheNextMeetingWithExactlyThatPersonWinsAndGoesToItsSeries() {
        let oneOnOne = invite("Jeff / Avery", days: 2, ["jeff@example.com", "avery@example.com"], series: "s1")
        let group = invite("Planning", days: 1, ["jeff@example.com", "sam@example.com"])
        let s = series("cal:s1", "Jeff / Avery", people: ["Jeffrey Moore"], next: oneOnOne)
        guard case .series(let found, let meeting) = resolve("Jeff", people: [owner, jeff], upcoming: [group, oneOnOne], series: [s]) else {
            return XCTFail("\(resolve("Jeff", people: [owner, jeff], upcoming: [group, oneOnOne], series: [s]))")
        }
        XCTAssertEqual(found.id, "cal:s1")
        XCTAssertEqual(meeting?.title, "Jeff / Avery", "the group meeting the day before is not the two of them")
    }

    func testAOneOffMeetingWithThemBecomesTheirPointShownBeforeIt() {
        let oneOff = invite("Coffee", days: 3, ["Jeffrey Moore"])
        guard case .person(let id, let name, let meeting) = resolve("Jeffrey Moore", people: [owner, jeff], upcoming: [oneOff]) else { return XCTFail() }
        XCTAssertEqual(id, "id-jeff")
        XCTAssertEqual(name, "Jeffrey Moore")
        XCTAssertEqual(meeting?.title, "Coffee")
    }

    func testOnePersonInTwoSeriesWithNoMeetingOfTheTwoIsAQuestion() {
        // Both still meet, and their next meetings are not of the two of them alone.
        let group = ["jeff@example.com", "sam@example.com", "avery@example.com"]
        let a = series("cal:a", "Platform review", people: ["Jeffrey Moore", "Sam Lee"], next: invite("Platform review", days: 2, group))
        let b = series("cal:b", "Budget sync", people: ["Jeffrey Moore"], next: invite("Budget sync", days: 3, group))
        guard case .choose(let options) = resolve("Jeffrey Moore", people: [owner, jeff], upcoming: [a.next!, b.next!], series: [a, b]) else { return XCTFail() }
        XCTAssertEqual(Set(options), ["Platform review", "Budget sync"])
    }

    func testAPersonWithNoMeetingAndNoSeriesGetsTheirOwnPoint() {
        guard case .person(let id, _, let meeting) = resolve("jeff@example.com", people: [owner, jeff]) else { return XCTFail() }
        XCTAssertEqual(id, "id-jeff")
        XCTAssertNil(meeting)
    }

    func testTwoPeopleNamedJeffAreAQuestionNeverAGuess() {
        let other = person("id-jeff2", "Jeff Park")
        guard case .choose(let options) = resolve("Jeff", people: [owner, jeff, other]) else { return XCTFail() }
        XCTAssertEqual(Set(options), ["Jeffrey Moore", "Jeff Park"])
    }

    func testANicknameFindsTheOnePersonItCanBe() {
        guard case .person(let id, _, _) = resolve("Jeff", people: [owner, jeff]) else { return XCTFail() }
        XCTAssertEqual(id, "id-jeff")
        guard case .notFound = resolve("Bob", people: [owner, jeff]) else { return XCTFail("nobody named so") }
    }

    func testAMeetingTitleFindsItsSeries() {
        let s = series("cal:w", "Weekly sync", people: ["Sam Lee", "Jeffrey Moore"])
        guard case .series(let found, _) = resolve("Weekly sync", people: [owner, jeff], series: [s]) else { return XCTFail() }
        XCTAssertEqual(found.id, "cal:w")
    }

    func testTheOwnerIsNeverTheOtherPerson() {
        guard case .notFound = resolve("Avery Webb", people: [owner, jeff]) else { return XCTFail() }
    }

    // MARK: The turn's rules

    func testOnlyTheOwnersWordsAreAReasonToAct() {
        var turn = ActionTurn(message: "What did Sam say about the budget?", live: false)
        guard case .propose = turn.admit(ChatActionRequest(.addPoint)) else { return XCTFail("a tool result asked for it, not the owner") }
        var asked = ActionTurn(message: "Please add a note to my and Jeff's next meeting to discuss the budget", live: false)
        XCTAssertEqual(asked.admit(ChatActionRequest(.addPoint)), .run)
        var task = ActionTurn(message: "Remind me to send the deck by Friday", live: false)
        XCTAssertEqual(task.admit(ChatActionRequest(.addTask)), .run)
        guard case .propose = task.admit(ChatActionRequest(.addBookmark)) else { return XCTFail("a task's words do not ask for a bookmark") }
    }

    func testAtMostThreeActionsForOneMessageTheRestBecomeOneCard() {
        var turn = ActionTurn(message: "Add these points for the Weekly sync: a, b, c, d, e", live: false)
        let results = (0..<5).map { _ in turn.admit(ChatActionRequest(.addPoint)) }
        XCTAssertEqual(results.prefix(3).map { $0 }, [.run, .run, .run])
        XCTAssertEqual(results.suffix(2).map { $0 }, [.later, .later])
    }

    func testTheRiskierClassAlwaysWaitsForAClickAndNeverDuringACall() {
        var turn = ActionTurn(message: "Speaker C is Dana Cole, rename the meeting, and tag it Budget", live: false)
        for kind: ChatActionRequest.Kind in [.nameVoice, .renameMeeting, .addTag, .setRecording] {
            guard case .propose = turn.admit(ChatActionRequest(kind)) else { return XCTFail("\(kind)") }
        }
        var live = ActionTurn(message: "Speaker C is Dana Cole", live: true)
        guard case .refuse = live.admit(ChatActionRequest(.nameVoice)) else { return XCTFail() }
        var light = ActionTurn(message: "Bookmark this moment", live: true)
        XCTAssertEqual(light.admit(ChatActionRequest(.bookmarkNow)), .run)
    }

    func testBookmarkingNowNeedsACall() {
        var turn = ActionTurn(message: "Bookmark this moment", live: false)
        guard case .refuse = turn.admit(ChatActionRequest(.bookmarkNow)) else { return XCTFail() }
    }

    // MARK: Each inverse

    func testAnAddedPointIsTakenBackOnlyWhileItIsAsTheActionLeftIt() throws {
        var book = NextTimeBook()
        var r = ChatActionRequest(.addPoint)
        r.text = "Discuss the budget"
        r.personID = "id-jeff"
        r.personName = "Jeffrey Moore"
        let change = try XCTUnwrap(ChatActionApply.run(r, on: &book, now: now))
        XCTAssertEqual(book.visible.map(\.text), ["Discuss the budget"])
        XCTAssertTrue(ChatActionApply.holds(change.after, point: book.points.first))
        var undone = book
        _ = ChatActionApply.run(change.undo, on: &undone, now: now)
        XCTAssertTrue(undone.visible.isEmpty)
        // Edited since: the Undo says it changed and does nothing.
        book.update(book.points[0].id, at: now) { $0.text = "Discuss the budget and hiring" }
        XCTAssertFalse(ChatActionApply.holds(change.after, point: book.points.first))
    }

    func testAnEditATickAndAReopenEachHaveTheirInverse() throws {
        var book = NextTimeBook()
        let p = try XCTUnwrap(book.add("Ask about hiring", personID: "id-jeff", personName: "Jeffrey Moore", at: now))
        var edit = ChatActionRequest(.editPoint)
        edit.pointID = p.id
        edit.text = "Ask about the hiring plan"
        let edited = try XCTUnwrap(ChatActionApply.run(edit, on: &book, now: now))
        XCTAssertEqual(edited.undo.text, "Ask about hiring")
        var tick = ChatActionRequest(.tickPoint)
        tick.pointID = p.id
        let ticked = try XCTUnwrap(ChatActionApply.run(tick, on: &book, now: now))
        XCTAssertNotNil(book.points[0].done)
        XCTAssertEqual(ticked.undo.kind, .reopenPoint)
        var reopen = ChatActionRequest(.reopenPoint)
        reopen.pointID = p.id
        let reopened = try XCTUnwrap(ChatActionApply.run(reopen, on: &book, now: now))
        XCTAssertNil(book.points[0].done)
        XCTAssertEqual(reopened.undo.kind, .tickPoint)
        XCTAssertEqual(reopened.undo.discussed, ticked.after.pointDone == true ? reopened.undo.discussed : nil)
        _ = ChatActionApply.run(reopened.undo, on: &book, now: now)
        XCTAssertEqual(book.points[0].done?.byOwner, true, "the tick of before comes back")
        var remove = ChatActionRequest(.removePoint)
        remove.pointID = p.id
        let removed = try XCTUnwrap(ChatActionApply.run(remove, on: &book, now: now))
        XCTAssertTrue(book.visible.isEmpty)
        _ = ChatActionApply.run(removed.undo, on: &book, now: now)
        XCTAssertEqual(book.visible.count, 1)
    }

    func testTasksAddDoneOpenAndDueEachHaveTheirInverse() throws {
        var book = CommitmentBook()
        var add = ChatActionRequest(.addTask)
        add.text = "Send the deck"
        add.personName = "Jeffrey Moore"
        add.personID = "id-jeff"
        add.date = now
        let added = try XCTUnwrap(ChatActionApply.run(add, on: &book, now: now))
        let id = try XCTUnwrap(book.visible.first?.id)
        XCTAssertEqual(book.visible.first?.toID, "id-jeff")
        var due = ChatActionRequest(.setTaskDue)
        due.taskID = id
        due.date = now.addingTimeInterval(86_400)
        let moved = try XCTUnwrap(ChatActionApply.run(due, on: &book, now: now))
        XCTAssertEqual(moved.undo.date, now)
        var done = ChatActionRequest(.setTaskDone)
        done.taskID = id
        let finished = try XCTUnwrap(ChatActionApply.run(done, on: &book, now: now))
        XCTAssertNotNil(book.visible.first?.done)
        _ = ChatActionApply.run(finished.undo, on: &book, now: now)
        XCTAssertNil(book.visible.first?.done)
        _ = ChatActionApply.run(moved.undo, on: &book, now: now)
        XCTAssertEqual(book.visible.first?.due, now)
        _ = ChatActionApply.run(added.undo, on: &book, now: now)
        XCTAssertTrue(book.visible.isEmpty)
    }

    func testABookmarkComesOffTheRecordAgain() {
        var r = CallRecord(id: "c", platform: .meet, bundleID: "b", start: now, end: now.addingTimeInterval(600), status: .written)
        XCTAssertTrue(r.setBookmarkNote(at: 120, "Budget", markerText: "★"))
        XCTAssertTrue(r.removeBookmark(at: 120.4))
        XCTAssertTrue(r.markers.isEmpty)
        XCTAssertFalse(r.removeBookmark(at: 120), "nothing left to remove")
    }

    // MARK: The saved form

    func testAChatWithActionsReadsInAnOlderBuildAndAnOldChatReadsHere() throws {
        var message = ChatMessage(role: .assistant, text: "Done.")
        var r = ChatActionRequest(.addPoint)
        r.text = "Discuss the budget"
        message.actions = [ChatActionRecord(request: r, state: .done, summary: "Saved for the next Weekly sync: Discuss the budget", date: now)]
        let data = try JSONEncoder().encode(message)
        struct Older: Decodable { var role: String; var text: String; var steps: [String] }
        XCTAssertEqual(try JSONDecoder().decode(Older.self, from: data).text, "Done.")
        let old = #"{"id":"6F9619FF-8B86-D011-B42D-00CF4FC964FF","role":"assistant","text":"Hi","steps":[]}"#
        XCTAssertNil(try JSONDecoder().decode(ChatMessage.self, from: Data(old.utf8)).actions)
        XCTAssertEqual(try JSONDecoder().decode(ChatMessage.self, from: data), message)
        XCTAssertEqual(message.actionLines, ["Done: Saved for the next Weekly sync: Discuss the budget"])
    }
}
