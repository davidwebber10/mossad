import XCTest
@testable import MossadCore

/// C3 and C5: no word of a moved call stays in a book, and a copy from an older device makes the Mac send its own again.
final class MoveBooksReviewTests: XCTestCase {
    private let x = MoveBooksFixtures.x, y = MoveBooksFixtures.y
    private let t0 = MoveBooksFixtures.t0
    private var d: Date { t0 + 86_400 }

    private func bytes<T: Encodable>(_ value: T) throws -> String { String(decoding: try JSONEncoder.coach.encode(value), as: UTF8.self) }

    private func assertNoWord(_ text: String, _ words: [String], _ what: String, line: UInt = #line) {
        for w in words { XCTAssertFalse(text.lowercased().contains(w.lowercased()), "\(what) keeps “\(w)”", line: line) }
    }

    // MARK: C3a: the points

    private let taskWords = "Send the giraffe forecast"
    private let decisionWords = "Whether the giraffe fund opens"

    private func pointsWithSuggestions() -> NextTimeBook {
        var book = MoveBooksFixtures.points()
        book.answers = [SuggestionAnswer(key: "openItem:\(x):\(PersonNames.key(taskWords))", kind: "openItem", verdict: .keep, date: t0),
                        SuggestionAnswer(key: "pendingDecision:\(x):\(PersonNames.key(decisionWords))", kind: "pendingDecision", verdict: .never, date: t0),
                        SuggestionAnswer(key: "openItem:\(y):\(PersonNames.key("call the bank"))", kind: "openItem", verdict: .dismiss, date: t0)]
        var kept = NextTimePoint(text: "Ask Sam about: \(taskWords)", personID: "p-sam", personName: "Sam Carter", rank: 9, created: t0)
        kept.id = UUID(uuidString: "00000000-0000-0000-0000-000000000031")!
        kept.suggestion = "openItem:\(x):\(PersonNames.key(taskWords))"
        book.points.append(kept)
        return book
    }

    func testThePointsKeepNoSuggestionOfTheCall() throws {
        let before = pointsWithSuggestions()
        var after = before
        after.forget(callID: x, at: d)
        assertNoWord(try bytes(after), ["giraffe"], "the points")
        XCTAssertEqual(after.answers.map(\.key), ["openItem:\(y):\(PersonNames.key("call the bank"))"])
        let marker = try XCTUnwrap(after.points.last)
        XCTAssertTrue(marker.deleted)
        XCTAssertEqual(marker.text, "")
        XCTAssertNil(marker.suggestion)
        for merged in [after.merged(with: before), before.merged(with: after)] {
            assertNoWord(try bytes(merged), ["giraffe"], "a merge with an older copy")
            XCTAssertEqual(merged.movedCalls, [x])
        }
    }

    // MARK: C3b: the coach

    private let reason = "I never discuss the giraffe enclosure"
    private let statement = "Sam runs the giraffe program"

    private func coachWithWhatTheCallMade() -> CoachProfile {
        var p = MoveBooksFixtures.coach()
        let card = CoachFinding(id: "card-z", callID: x, date: t0, kind: .missed, text: "You skipped the giraffe budget", skill: "asks")
        p.answers.append(FindingAnswer(card, verdict: .no, date: t0))
        p.explain("card-z", note: reason, at: t0)
        var q = CoachQuestion(statement: statement, kind: .role, evidence: "said so", callID: x, at: 12, asked: t0)
        q.id = UUID(uuidString: "00000000-0000-0000-0000-000000000099")!
        p.questions.append(q)
        p.answer(q.id, .confirmed, note: nil, at: t0)
        return p
    }

    func testTheCoachKeepsNothingThatTheCallsAnswersMade() throws {
        let before = coachWithWhatTheCallMade()
        XCTAssertTrue(try bytes(before).contains("giraffe"), "the test puts the words in")
        var after = before
        after.forgetMoved(callID: x)
        assertNoWord(try bytes(after), ["giraffe", "Zebra budget"], "the coach")
        for coaching in [false, true] {
            assertNoWord(try bytes(after.merged(with: before, takeCoaching: coaching)), ["giraffe", "Zebra budget"], "a merge")
            assertNoWord(try bytes(before.merged(with: after, takeCoaching: coaching)), ["giraffe", "Zebra budget"], "a merge")
        }
    }

    // MARK: C3c: a person

    func testAForgottenPersonLeavesNoWordsInForgotten() throws {
        var p = CoachProfile()
        var sam = CoachPerson(note: "Likes the giraffe charts", calls: 3, lastSeen: t0)
        sam.person = "p1"
        p.people = ["Sam Carter": sam]
        p.facts = [CoachFact(kind: .relationship, text: "Sam Carter is my giraffe manager", date: t0, person: "p1")]
        p.guidance = [CoachGuidance(text: "Be brief with Sam about giraffes", date: t0, person: "p1")]
        let before = p
        p.forget(person: "p1", name: "Sam Carter")
        XCTAssertEqual(p.movedPeople, ["p1"])
        assertNoWord(try bytes(p), ["giraffe", "Sam Carter"], "the coach after the person went")
        // A copy with a later date does not bring a fact back: no clock rule decides it.
        var later = before
        later.facts[0].date = d + 3600
        for merged in [p.merged(with: later), later.merged(with: p), p.merged(with: before, takeCoaching: true)] {
            XCTAssertFalse(merged.facts.contains { $0.person == "p1" })
            XCTAssertFalse(merged.guidance.contains { $0.person == "p1" })
            XCTAssertEqual(merged.movedPeople, ["p1"])
        }
        XCTAssertNil(try JSONDecoder.coach.decode(CoachProfile.self, from: JSONEncoder.coach.encode(MoveBooksFixtures.coach())).movedPeople)
        XCTAssertFalse(try bytes(MoveBooksFixtures.coach()).contains("movedPeople"))
    }

    // MARK: C5: a copy from an older device makes the Mac send its own again

    func testACopyThatStillNamesAMovedCallIsSentAgain() throws {
        var mac = pointsWithSuggestions()
        mac.forget(callID: x, at: d)
        // An iPhone of today's release: its merge keeps its own entries, and it saves no `movedCalls`.
        var phone = pointsWithSuggestions()
        phone.checked.insert(x)
        let old = try JSONDecoder.coach.decode(NextTimeBook.self, from: Data(try bytes(phone).utf8))
        let merged = mac.merged(with: old)
        XCTAssertEqual(merged, mac, "the merge equals the Mac's file: before this rule, nothing was sent")
        XCTAssertTrue(merged.pushesAgain(after: old))
        // A clean copy with the same list: no push, so two Macs do not send each other the book for ever.
        XCTAssertFalse(merged.pushesAgain(after: mac))
        XCTAssertFalse(NextTimeBook().pushesAgain(after: NextTimeBook()))

        var coach = coachWithWhatTheCallMade()
        coach.forgetMoved(callID: x)
        let oldCoach = coachWithWhatTheCallMade()
        XCTAssertTrue(coach.merged(with: oldCoach).pushesAgain(after: oldCoach))
        XCTAssertFalse(coach.merged(with: coach).pushesAgain(after: coach))

        var tasks = MoveBooksFixtures.commitments()
        tasks.forget(callID: x, at: d)
        let oldTasks = MoveBooksFixtures.commitments()
        XCTAssertTrue(tasks.merged(with: oldTasks).pushesAgain(after: oldTasks))
        XCTAssertFalse(tasks.merged(with: tasks).pushesAgain(after: tasks))
        XCTAssertFalse(MoveBooksFixtures.commitments().pushesAgain(after: MoveBooksFixtures.commitments()))
    }

    /// The whole trace of the review: the Mac forgets and sends; an iPhone of today's release sends its own copy with the
    /// words and no list; the Mac's merge equals its file, and it sends its clean book again all the same.
    func testAnOlderPhonesCopyMakesTheMacSendTheCleanBookAgain() async throws {
        func temp() -> Paths {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("MoveBooksReviewTests-\(UUID().uuidString)")
            addTeardownBlock { try? FileManager.default.removeItem(at: url) }
            return Paths(root: url)
        }
        // The points sync through the owner's server only (a store that wants the meeting view).
        let store = MemoryStore(view: true)
        let mac = temp(), phone = temp(), reader = temp()
        var macBook = pointsWithSuggestions()
        macBook.forget(callID: x, at: d)
        try macBook.save(to: mac.nextTime)
        let macSync = CloudSync(paths: mac, store: store)
        try await macSync.pushShared()
        // The iPhone of today's release: its own copy, with the words, and no list.
        try pointsWithSuggestions().save(to: phone.nextTime)
        try await CloudSync(paths: phone, store: store).pushShared()
        try await macSync.pull(includeMeetings: true)
        XCTAssertEqual(try NextTimeBook.load(from: mac.nextTime), macBook, "the Mac's file did not change")
        try await macSync.pushShared()
        try await CloudSync(paths: reader, store: store).pull(includeMeetings: false)
        let inStore = try NextTimeBook.load(from: reader.nextTime)
        XCTAssertEqual(inStore.movedCalls, [x])
        assertNoWord(try bytes(inStore), ["giraffe"], "the store")
    }

    /// A damaged file on the Mac is set aside, and the Mac's book starts empty: the merge has no list, so the copy that
    /// comes in is kept as it is and nothing is sent again. The forget of that book is then lost until the move's
    /// ledger runs it again (Task 8).
    func testADamagedLocalBookHasNoListToCleanWith() throws {
        let old = pointsWithSuggestions()
        let merged = NextTimeBook().merged(with: old)
        XCTAssertNil(merged.movedCalls)
        XCTAssertFalse(merged.pushesAgain(after: old))
        XCTAssertTrue(try bytes(merged).contains("giraffe"))
    }

    /// The iPhone with this release runs the same merges: it drops the entries and keeps the lists.
    func testThePhonesMergeDropsTheEntriesAndKeepsTheLists() throws {
        var mac = pointsWithSuggestions()
        mac.forget(callID: x, at: d)
        let phone = pointsWithSuggestions()
        let onPhone = phone.merged(with: mac)
        XCTAssertEqual(onPhone.movedCalls, [x])
        assertNoWord(try bytes(onPhone), ["giraffe"], "the phone's merge")

        var coach = coachWithWhatTheCallMade()
        coach.forgetMoved(callID: x)
        coach.forget(person: "p-sam", name: "Sam Carter")
        let phoneCoach = coachWithWhatTheCallMade().merged(with: coach, takeCoaching: true)
        XCTAssertEqual(phoneCoach.movedCalls, [x])
        XCTAssertEqual(phoneCoach.movedPeople, ["p-sam"])
        assertNoWord(try bytes(phoneCoach), ["giraffe", "Zebra budget"], "the phone's coach")
    }
}
