import CryptoKit
import XCTest
@testable import MossadCore

final class MoveBooksTests: XCTestCase {
    private let x = "20261101-100000", y = "20261102-090000", w = "20261025-090000"
    private let t0 = Date(timeIntervalSince1970: 1_793_520_000)
    private var d: Date { t0 + 86_400 }

    private func text<T: Encodable>(_ value: T, _ encoder: JSONEncoder = .coach) throws -> String {
        String(decoding: try encoder.encode(value), as: UTF8.self)
    }

    // MARK: Commitments

    func testACommitmentOfTheCallKeepsNoWord() throws {
        let before = MoveBooksFixtures.commitments()
        var book = before
        XCTAssertEqual(book.forget(callID: x, at: d), 2)
        for item in book.items where item.callID == x {
            XCTAssertTrue(item.deleted)
            XCTAssertEqual(item.text, "")
            XCTAssertNil(item.to)
            XCTAssertNil(item.toID)
            XCTAssertNil(item.callTitle)
            XCTAssertNil(item.quote)
            XCTAssertNil(item.at)
            XCTAssertNil(item.due)
            XCTAssertEqual(item.updated, d)
        }
        XCTAssertEqual(book.items.last, before.items.last, "the other call's task is the same")
        XCTAssertEqual(book.checked, before.checked, "the id never comes back, so its place in checked stays")
        // A copy from the iPhone that changed a task of the call after the forget (it ticked it done): the marker wins.
        var phone = before
        phone.update(phone.items[0].id, at: d + 60) { $0.done = d + 60 }
        for merged in [book.merged(with: before), before.merged(with: book), book.merged(with: phone), phone.merged(with: book)] {
            XCTAssertEqual(merged.items.filter { $0.callID == x }, book.items.filter { $0.callID == x })
            let json = try text(merged, JSONEncoder())
            XCTAssertFalse(json.lowercased().contains("zebra"))
            XCTAssertFalse(json.contains("Sam Carter"))
        }
    }

    func testACommitmentBookIsSavedAsTodayWithNoForget() throws {
        let book = MoveBooksFixtures.commitments()
        var same = book
        XCTAssertEqual(same.forget(callID: "20200101-000000", at: d), 0)
        XCTAssertEqual(same, book)
    }

    // MARK: Points

    func testAPointTheCallClosedIsOpenAndNoPointNamesTheCall() throws {
        var book = MoveBooksFixtures.points()
        XCTAssertTrue(book.forget(callID: x, at: d))
        XCTAssertTrue(book.points[0].isOpen)
        XCTAssertEqual(book.points[1].carried, [w])
        XCTAssertEqual(book.points[2].mentions?.map(\.callID), [y])
        XCTAssertNil(book.points[3].reopened)
        XCTAssertTrue(book.points.allSatisfy { $0.updated == d })
        XCTAssertEqual(book.checked, [y])
        XCTAssertEqual(book.movedCalls, [x])
        let json = try text(book)
        XCTAssertEqual(json.components(separatedBy: x).count - 1, 1, "the id is only in movedCalls")
        // The point's own text is the owner's; the meeting's words were its quotes.
        XCTAssertFalse(json.contains("the zebra budget is fine"))
        XCTAssertFalse(json.contains("the zebra office"))
    }

    func testAForgottenCallDoesNotComeBackInAMerge() throws {
        let before = MoveBooksFixtures.points()
        var after = before
        after.forget(callID: x, at: d)
        for merged in [after.merged(with: before), before.merged(with: after)] {
            XCTAssertEqual(merged.points, after.points)
            XCTAssertEqual(merged.checked, after.checked)
            XCTAssertEqual(merged.movedCalls, after.movedCalls)
        }
        // A copy from an older build or the iPhone, changed later, with no `movedCalls`: the call stays forgotten.
        var phone = before
        phone.update(phone.points[2].id, at: d + 60) { $0.text = "Office move, again" }
        let old = try JSONDecoder.coach.decode(NextTimeBook.self, from: Data(try text(phone).utf8))
        XCTAssertNil(old.movedCalls)
        for merged in [after.merged(with: old), old.merged(with: after)] {
            XCTAssertEqual(merged.points.first { $0.text == "Office move, again" }?.mentions?.map(\.callID), [y])
            XCTAssertTrue(merged.points[0].isOpen)
            XCTAssertFalse(merged.checked.contains(x))
            XCTAssertEqual(merged.movedCalls, [x])
            XCTAssertEqual(try text(merged).components(separatedBy: x).count - 1, 1)
        }
    }

    // MARK: The coach

    private func nothing(of call: String, in p: CoachProfile) -> Bool {
        !p.rated.contains { $0.callID == call } && !p.questions.contains { $0.callID == call } && !p.answers.contains { $0.callID == call }
            && !p.observations.contains { $0.callID == call } && !p.history.contains { $0.callID == call } && !p.advice.contains { $0.callID == call }
    }

    func testTheCoachForgetsAMovedCallForGood() throws {
        let before = MoveBooksFixtures.coach()
        var after = before
        after.forgetMoved(callID: x)
        XCTAssertTrue(nothing(of: x, in: after))
        XCTAssertEqual(after.movedCalls, [x])
        XCTAssertEqual(after.rated.filter { $0.callID == y }, before.rated.filter { $0.callID == y })
        XCTAssertEqual(after.questions.filter { $0.callID == y }, before.questions.filter { $0.callID == y })
        XCTAssertEqual(after.answers.filter { $0.callID == y }, before.answers.filter { $0.callID == y })
        XCTAssertEqual(after.history.filter { $0.callID == y }, before.history.filter { $0.callID == y })
        XCTAssertFalse(try text(after).contains("Zebra"))
        for takeCoaching in [false, true] {
            XCTAssertTrue(nothing(of: x, in: after.merged(with: before, takeCoaching: takeCoaching)))
            XCTAssertTrue(nothing(of: x, in: before.merged(with: after, takeCoaching: takeCoaching)))
            XCTAssertEqual(before.merged(with: after, takeCoaching: takeCoaching).movedCalls, [x])
        }
        // A copy that an older build saved: no `movedCalls`, and the call's words.
        let old = try JSONDecoder.coach.decode(CoachProfile.self, from: Data(try text(before).utf8))
        XCTAssertNil(old.movedCalls)
        XCTAssertTrue(nothing(of: x, in: old.merged(with: after, takeCoaching: true)))
    }

    func testABookWithNoMovedCallIsSavedAsToday() throws {
        // Saved as a build of before saves them: no key "movedCalls"; and a file with no such key reads nil.
        let book = MoveBooksFixtures.points(), profile = MoveBooksFixtures.coach()
        XCTAssertFalse(try text(book).contains("movedCalls"))
        XCTAssertFalse(try text(profile).contains("movedCalls"))
        XCTAssertNil(try JSONDecoder.coach.decode(NextTimeBook.self, from: Data(try text(book).utf8)).movedCalls)
        XCTAssertNil(try JSONDecoder.coach.decode(CoachProfile.self, from: Data(try text(profile).utf8)).movedCalls)
        // The same bytes as a merge and a forget of nothing give.
        XCTAssertEqual(try text(book.merged(with: NextTimeBook())), try text(NextTimeBook().merged(with: book)))
        XCTAssertFalse(try text(book.merged(with: book)).contains("movedCalls"))
        XCTAssertFalse(try text(profile.merged(with: profile)).contains("movedCalls"))
    }

    /// The SHA-256 and size of each file that the code of before (main at 278a769) saves for these fixtures.
    private let today = [CommitmentBook.fileName: ("575b4d6cdda9db2f48aadecf83f3ff468f7417fb3e9dfba21be3ff8bac82a54a", 1230),
                         NextTimeBook.fileName: ("5cbdf2e8b647de58ff710dde8b795e9b51da179ec8b311d562166c4c5202f4f1", 1954),
                         CoachProfile.fileName: ("f01028ee105c87965176a0588092aaa2381dcb84a2df193b12541e892e3f5456", 2525)]

    func testEachBookWithNoMovedCallIsSavedByteForByteAsToday() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("MoveBooksTests-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        func check(_ name: String, _ save: (URL) throws -> Void, _ line: UInt = #line) throws {
            let sub = dir.appendingPathComponent(UUID().uuidString)
            try save(sub)
            let data = try Data(contentsOf: sub.appendingPathComponent(name))
            let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            XCTAssertEqual(hash, today[name]?.0, name, line: line)
            XCTAssertEqual(data.count, today[name]?.1, name, line: line)
        }
        let c = MoveBooksFixtures.commitments(), n = MoveBooksFixtures.points(), p = MoveBooksFixtures.coach()
        try check(CommitmentBook.fileName) { try c.save(to: $0) }
        try check(NextTimeBook.fileName) { try n.save(to: $0) }
        try check(CoachProfile.fileName) { try p.save(to: $0) }
        // A merge with a copy of itself, and a forget of a call that is not there, change no byte.
        try check(CommitmentBook.fileName) { try c.merged(with: c).save(to: $0) }
        try check(NextTimeBook.fileName) { try n.merged(with: n).save(to: $0) }
        // The coach's merge sorts rated points of one date in no fixed order, as it does on main: its bytes are not
        // pinned, only that it adds no key.
        let mergedCoach = try JSONSerialization.jsonObject(with: JSONEncoder.coach.encode(p.merged(with: p))) as? [String: Any]
        XCTAssertNil(mergedCoach?["movedCalls"])
        var c2 = c
        XCTAssertEqual(c2.forget(callID: "20200101-000000", at: MoveBooksFixtures.t0 + 9), 0)
        try check(CommitmentBook.fileName) { try c2.save(to: $0) }
    }

    func testTheKeysAreTheKeysOfBefore() throws {
        // Every key that a book of today writes, and no other: an older build reads each file whole.
        func keys(_ data: Data) throws -> Set<String> { Set(try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any]).keys) }
        XCTAssertEqual(try keys(JSONEncoder.coach.encode(MoveBooksFixtures.points())), ["version", "points", "answers", "checked"])
        var moved = MoveBooksFixtures.points()
        moved.forget(callID: x, at: d)
        XCTAssertEqual(try keys(JSONEncoder.coach.encode(moved)), ["version", "points", "answers", "checked", "movedCalls"])
        XCTAssertEqual(try JSONDecoder.coach.decode(NextTimeBook.self, from: JSONEncoder.coach.encode(moved)).version, 1)
        let coachKeys = try keys(JSONEncoder.coach.encode(MoveBooksFixtures.coach()))
        XCTAssertFalse(coachKeys.contains("movedCalls"))
        var movedCoach = MoveBooksFixtures.coach()
        movedCoach.forgetMoved(callID: x)
        XCTAssertEqual(try keys(JSONEncoder.coach.encode(movedCoach)), coachKeys.union(["movedCalls"]))
    }

    func testTheCoachForgetsAPerson() throws {
        var p = CoachProfile()
        var sam = CoachPerson(note: "Likes numbers", calls: 3, lastSeen: t0)
        sam.person = "p1"
        var mira = CoachPerson(note: "Likes pictures", calls: 2, lastSeen: t0)
        mira.person = "p2"
        var samOld = CoachPerson(note: "Under an older name", calls: 1, lastSeen: t0)
        samOld.person = "p1"
        p.people = ["Sam Carter": sam, "S. Carter": samOld, "Mira Stone": mira]
        p.facts = [CoachFact(kind: .relationship, text: "Sam Carter is my manager", date: t0, person: "p1"),
                   CoachFact(kind: .relationship, text: "Mira Stone reports to me", date: t0, person: "p2")]
        p.guidance = [CoachGuidance(text: "Be brief with Sam", date: t0, person: "p1"), CoachGuidance(text: "Show Mira the chart", date: t0, person: "p2")]
        let before = p
        p.forget(person: "p1", name: "Sam Carter")
        XCTAssertEqual(Set(p.people.keys), ["Mira Stone"])
        XCTAssertEqual(p.facts.map(\.person), ["p2"])
        XCTAssertEqual(p.guidance.map(\.person), ["p2"])
        XCTAssertTrue(p.forgotten.isEmpty, "no words of the person are kept")
        XCTAssertEqual(p.movedPeople, ["p1"])
        XCTAssertEqual(p.people["Mira Stone"], before.people["Mira Stone"])
        let merged = p.merged(with: before)
        XCTAssertFalse(merged.facts.contains { $0.person == "p1" })
        XCTAssertFalse(merged.guidance.contains { $0.person == "p1" })
        XCTAssertNil(merged.people["Sam Carter"])
    }

    // MARK: The note's copy

    func testTheReferenceBackupOfANoteGoes() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MoveBooksTests-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let paths = Paths(root: root)
        try FileManager.default.createDirectory(at: paths.meetings, withIntermediateDirectories: true)
        let note = paths.meetings.appendingPathComponent("2026-11-01 1000 - Zebra budget.md")
        try Data("# Zebra budget\n".utf8).write(to: note)
        XCTAssertTrue(ReferenceBackup.keep(note: note.path, paths: paths))
        let copy = ReferenceBackup.folder(paths).appendingPathComponent("notes/\(note.lastPathComponent)")
        XCTAssertTrue(FileManager.default.fileExists(atPath: copy.path))
        ReferenceBackup.forget(note: note.path, paths: paths)
        XCTAssertFalse(FileManager.default.fileExists(atPath: copy.path))
        ReferenceBackup.forget(note: paths.meetings.appendingPathComponent("none.md").path, paths: paths)
    }
}
