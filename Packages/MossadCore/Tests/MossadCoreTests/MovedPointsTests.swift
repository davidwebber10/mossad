import XCTest
@testable import MossadCore

/// Which points for next time go with a meeting that moves to another profile, what each carries, and how the target
/// takes them in. Pure.
final class MovedPointsTests: XCTestCase {
    private let x = "20261101-100000", y = "20261102-090000"
    private let t0 = Date(timeIntervalSince1970: 1_793_520_000)
    private let planned = Date(timeIntervalSince1970: 1_793_519_900)

    private func detail(_ title: String = "Budget chat", at start: Date? = nil) -> MeetingDetail {
        let s = start ?? planned
        return MeetingDetail(title: title, start: s, end: s + 1800, event: NextTimeMeeting.event("uid-1"), people: ["p-sam"], invited: 1)
    }

    private var record: CallRecord {
        var r = CallRecord(id: x, platform: .meet, bundleID: "", start: planned + 60, end: planned + 1800, status: .written)
        r.calendarTitle = "Budget chat"
        r.plannedStart = planned
        return r
    }

    private func point(_ text: String, _ n: Int, _ change: (inout NextTimePoint) -> Void = { _ in }) -> NextTimePoint {
        var p = NextTimePoint(text: text, rank: Double(n), created: t0 + Double(n))
        p.id = UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", n))!
        change(&p)
        return p
    }

    /// One row for each kind of point: whether it goes with the meeting `x`.
    private var table: [(name: String, point: NextTimePoint, goes: Bool)] {
        [
            ("a meeting point the check found in the call", point("Found by the check", 1) { $0.meeting = NextTimeMeeting(self.detail(), calls: [self.x]) }, true),
            ("a meeting point of a call marked during the call (matched by its invite)", point("Matched by the invite", 2) { $0.meeting = NextTimeMeeting(self.detail()) }, true),
            ("a meeting point with no detail on this Mac, by its recording", point("No detail", 3) { $0.meeting = NextTimeMeeting(nil, calls: [self.x]) }, true),
            ("a meeting point of another meeting", point("Another meeting", 4) { $0.meeting = NextTimeMeeting(self.detail("Lunch"), calls: [self.y]) }, false),
            ("a point the check moved from the call to the person", point("Moved by the check", 5) {
                $0.meeting = NextTimeMeeting(self.detail(), calls: [self.x])
                $0.personID = "p-sam"
                $0.personName = "Sam Carter"
                $0.carried = [self.x]
            }, true),
            ("a meeting point the owner moved to the person by hand", point("Moved by hand", 6) {
                $0.meeting = NextTimeMeeting(self.detail(), calls: [self.x])
                $0.personID = "p-sam"
                $0.personName = "Sam Carter"
            }, false),
            ("a person point the owner made for the person", point("For Sam", 7) {
                $0.personID = "p-sam"
                $0.personName = "Sam Carter"
            }, false),
            ("a series point the call carried", point("Series point", 8) {
                $0.seriesID = "cal:series-1"
                $0.seriesKeys = ["cal:series-1"]
                $0.carried = [self.x]
            }, false),
            ("a meeting point that followed its invite into a series", point("Followed into a series", 9) {
                $0.meeting = NextTimeMeeting(self.detail(), calls: [self.x])
                $0.seriesID = "cal:series-1"
                $0.seriesKeys = ["cal:series-1"]
            }, false),
            ("a series point moved by hand to a person after the call carried it", point("Series to person", 10) {
                $0.meeting = NextTimeMeeting(self.detail())
                $0.personID = "p-sam"
                $0.personName = "Sam Carter"
                $0.carried = [self.x]
            }, false),
            ("a meeting point the owner deleted", point("Deleted by hand", 11) {
                $0.meeting = NextTimeMeeting(self.detail(), calls: [self.x])
                $0.deleted = true
            }, false),
        ]
    }

    /// Review C1: a call in the slot of another meeting's invite, matched only as a guess, takes no point of that
    /// meeting along and empties none. A point that the check found in the call (`meeting.calls`) still goes.
    func testAGuessedInviteTakesNoPointAlongAndEmptiesNone() {
        var guessed = record
        guessed.inviteNotSure = true
        let byInvite = point("Matched by the invite", 2) { $0.meeting = NextTimeMeeting(self.detail()) }
        let found = point("Found by the check", 1) { $0.meeting = NextTimeMeeting(self.detail(), calls: [self.x]) }
        XCTAssertFalse(NextTimeBook.goesWithMove(byInvite, callID: x, record: guessed))
        XCTAssertTrue(NextTimeBook.goesWithMove(found, callID: x, record: guessed))
        var book = NextTimeBook()
        book.points = [found, byInvite]
        XCTAssertEqual(book.moved(callID: x, record: guessed)?.points.map(\.text), ["Found by the check"])
        book.forget(callID: x, record: guessed, went: Set(book.going(callID: x, record: guessed).map(\.id)), at: t0 + 100)
        XCTAssertTrue(NextTimeBook.forgotten(book.points[0]))
        XCTAssertEqual(book.points[1].text, "Matched by the invite", "the point keeps its words")
        XCTAssertFalse(book.points[1].deleted)
        XCTAssertNotNil(book.points[1].meeting?.detail)
        // A ledger of an older build (no list) empties none by a guessed invite either.
        var old = NextTimeBook()
        old.points = [byInvite]
        old.forget(callID: x, record: guessed, at: t0 + 100)
        XCTAssertEqual(old.points[0].text, "Matched by the invite")
    }

    /// A ledger of an older build (no list of the points that went): `forget` empties what it emptied before this
    /// branch, and nothing more (a point the check moved to a person who stays keeps its words: it did not go).
    func testAnOlderLedgerEmptiesWhatItEmptiedBefore() {
        var book = NextTimeBook()
        book.points = table.map(\.point)
        book.forget(callID: x, record: record, at: t0 + 100)
        let words = Set(table.map(\.point).filter { p in book.points.first { $0.id == p.id }.map(NextTimeBook.forgotten) == true }.map(\.text))
        XCTAssertEqual(words, ["Found by the check", "Matched by the invite", "No detail", "Deleted by hand"])
    }

    func testWhichPointsGoWithTheMeeting() {
        for row in table {
            XCTAssertEqual(NextTimeBook.goesWithMove(row.point, callID: x, record: record), row.goes && !row.point.deleted, row.name)
        }
        var book = NextTimeBook()
        book.points = table.map(\.point)
        let moved = book.moved(callID: x, record: record)
        XCTAssertEqual(moved?.points.map(\.text), table.filter(\.goes).map(\.point.text))
    }

    /// The first profile keeps nothing of a point that goes: each one is the empty marker after `forget` with the
    /// ledger's list, and every point that stays keeps its words.
    func testEveryPointThatGoesIsEmptiedAndNoOtherIs() {
        var book = NextTimeBook()
        book.points = table.map(\.point)
        let going = Set(book.going(callID: x, record: record).map(\.id))
        book.forget(callID: x, record: record, went: going, at: t0 + 100)
        for row in table where !row.point.deleted {
            let after = book.points.first { $0.id == row.point.id }!
            XCTAssertEqual(NextTimeBook.forgotten(after), going.contains(row.point.id), row.name)
            if !going.contains(row.point.id) { XCTAssertEqual(after.text, row.point.text, row.name) }
        }
    }

    /// Review I3: a point the owner moved by hand to a person who goes with the meeting goes too, as an open point of the
    /// meeting. A person who stays keeps it.
    func testAPointMovedByHandToAPersonWhoGoesGoesWithTheMeeting() throws {
        let byHand = table.first { $0.name.hasPrefix("a meeting point the owner moved") }!.point
        XCTAssertFalse(NextTimeBook.goesWithMove(byHand, callID: x, record: record))
        XCTAssertTrue(NextTimeBook.goesWithMove(byHand, callID: x, record: record, gone: ["p-sam"]))
        XCTAssertFalse(NextTimeBook.goesWithMove(byHand, callID: x, record: record, gone: ["p-jo"]))
        var book = NextTimeBook()
        book.points = [byHand]
        let moved = try XCTUnwrap(book.moved(callID: x, record: record, gone: ["p-sam"]))
        XCTAssertEqual(moved.points.map(\.text), ["Moved by hand"])
        XCTAssertNil(moved.points[0].done)
        XCTAssertEqual(book.going(callID: x, record: record, gone: ["p-sam"]).map(\.id), [byHand.id])
    }

    /// Review I2: the removal empties exactly the points that went (the ledger's ids), as they are at the removal. A
    /// point that became the meeting's after the copy keeps its words and only loses the call.
    func testTheRemovalEmptiesExactlyThePointsThatWent() {
        var book = NextTimeBook()
        book.points = table.map(\.point)
        let went: Set<UUID> = [table[0].point.id, table[5].point.id]
        book.forget(callID: x, record: record, went: went, at: t0 + 100)
        for row in table where !row.point.deleted {
            let after = book.points.first { $0.id == row.point.id }!
            XCTAssertEqual(NextTimeBook.forgotten(after), went.contains(row.point.id), row.name)
        }
        let kept = book.points.first { $0.id == table[1].point.id }!
        XCTAssertEqual(kept.text, "Matched by the invite", "a point of the meeting that did not go keeps its words")
        XCTAssertFalse(book.points.first { $0.id == table[2].point.id }!.meeting?.calls?.contains(x) ?? false, "and loses the call")
        // An empty list (nothing went, or the target did not take the points) empties nothing.
        var none = NextTimeBook()
        none.points = table.map(\.point)
        none.forget(callID: x, record: record, went: [], at: t0 + 100)
        XCTAssertFalse(none.points.contains(where: NextTimeBook.forgotten))
    }

    func testNoPointsIsNoFile() {
        var book = NextTimeBook()
        book.points = table.filter { !$0.goes }.map(\.point)
        XCTAssertNil(book.moved(callID: x, record: record))
        XCTAssertNil(NextTimeBook().moved(callID: x, record: nil))
    }

    func testWhatAPointCarries() throws {
        var book = NextTimeBook()
        book.points = [
            point("Discussed", 2) {
                $0.meeting = NextTimeMeeting(self.detail(), calls: [self.x])
                $0.done = .init(callID: self.x, at: 42, quote: "the budget for the third quarter is fine", date: self.t0 + 500, byOwner: false)
                $0.suggestion = "openItem:\(self.y):Send the budget"
            },
            point("Open", 1) { $0.meeting = NextTimeMeeting(self.detail(), calls: [self.x]) },
            point("Reopened", 3) {
                $0.meeting = NextTimeMeeting(self.detail(), calls: [self.x])
                $0.reopened = [self.y, self.x]
            },
            point("Moved to Sam", 4) {
                $0.meeting = NextTimeMeeting(self.detail(), calls: [self.x])
                $0.personID = "p-sam"
                $0.personName = "Sam Carter"
                $0.carried = [self.x]
            },
            point("Done by hand", 5) {
                $0.meeting = NextTimeMeeting(self.detail(), calls: [self.x])
                $0.done = .init(callID: nil, at: nil, quote: nil, date: self.t0 + 600, byOwner: true)
            },
            point("Done in a meeting that stays", 6) {
                $0.meeting = NextTimeMeeting(self.detail(), calls: [self.x])
                $0.done = .init(callID: self.y, at: 7, quote: "a line of the meeting that stays here", date: self.t0 + 700, byOwner: false)
            },
        ]
        book.checked = [x]
        let moved = try XCTUnwrap(book.moved(callID: x, record: record))
        XCTAssertTrue(moved.checked)
        XCTAssertEqual(moved.points.map(\.text), ["Open", "Discussed", "Reopened", "Moved to Sam", "Done by hand", "Done in a meeting that stays"], "in their order")
        XCTAssertEqual(moved.points.map(\.rank), [1, 2, 3, 4, 5, 6])
        XCTAssertEqual(moved.points[0].created, t0 + 1)
        XCTAssertNil(moved.points[0].done)
        XCTAssertEqual(moved.points[1].done, .init(inThisCall: true, at: 42, quote: "the budget for the third quarter is fine", date: t0 + 500, byOwner: false))
        XCTAssertEqual(moved.points[2].reopened, true)
        XCTAssertNil(moved.points[3].done, "the point the check moved to the person arrives open")
        XCTAssertEqual(moved.points[4].done, .init(inThisCall: false, at: nil, quote: nil, date: t0 + 600, byOwner: true))
        XCTAssertEqual(moved.points[5].done, .init(inThisCall: false, at: nil, quote: nil, date: t0 + 700, byOwner: false), "no moment of a meeting that stays")
        let d = detail()
        XCTAssertEqual(moved.points[0].meeting, .init(title: d.title, start: d.start, end: d.end, event: d.event))

        let text = String(decoding: try JSONEncoder.move.encode(moved), as: UTF8.self)
        for p in book.points { XCTAssertFalse(text.contains(p.id.uuidString), "no point id of the first profile") }
        for word in ["p-sam", "Sam Carter", "series", y, x, "suggestion", "people", "invited", "personID", "carried", "mentions"] {
            XCTAssertFalse(text.contains(word), word)
        }
    }

    func testAMeetingTheFirstProfileDidNotCheckIsCheckedInTheTarget() throws {
        var book = NextTimeBook()
        book.points = [point("Open", 1) { $0.meeting = NextTimeMeeting(self.detail()) }]
        XCTAssertEqual(book.moved(callID: x, record: record)?.checked, false)
    }

    func testTheTargetTakesThePointsInOnceUnderItsOwnID() throws {
        var a = NextTimeBook()
        a.points = [
            point("Open", 1) { $0.meeting = NextTimeMeeting(self.detail(), calls: [self.x]) },
            point("Discussed", 2) {
                $0.meeting = NextTimeMeeting(self.detail(), calls: [self.x])
                $0.done = .init(callID: self.x, at: 42, quote: "the budget for the third quarter is fine", date: self.t0 + 500, byOwner: false)
            },
            point("Reopened", 3) {
                $0.meeting = NextTimeMeeting(self.detail(), calls: [self.x])
                $0.reopened = [self.x]
            },
            point("Moved to Sam", 4) {
                $0.meeting = NextTimeMeeting(self.detail(), calls: [self.x])
                $0.personID = "p-sam"
                $0.carried = [self.x]
            },
        ]
        a.checked = [x]
        let moved = try XCTUnwrap(a.moved(callID: x, record: record))
        let f = x + "-moved"
        let ids = (0..<moved.points.count).map { _ in UUID() }
        var b = NextTimeBook()
        let kept = b.add("A point of the target", personID: "p-jo", personName: "Jo Park", at: t0)!
        XCTAssertTrue(b.takeIn(moved, as: f, ids: ids, at: t0 + 1000))
        let again = b
        XCTAssertFalse(b.takeIn(moved, as: f, ids: ids, at: t0 + 2000), "a second run adds nothing")
        XCTAssertEqual(b, again)
        XCTAssertEqual(b.points.count, 5)
        XCTAssertEqual(b.points.first, kept)
        XCTAssertTrue(b.checked.contains(f))
        let taken = Array(b.points.dropFirst())
        XCTAssertEqual(taken.map(\.id), ids)
        XCTAssertTrue(taken.allSatisfy { $0.isForMeeting && $0.meeting?.calls == [f] && $0.personID == nil && $0.seriesID == nil && $0.carried == nil })
        XCTAssertTrue(taken.allSatisfy { $0.meeting?.detail == MeetingDetail(title: "Budget chat", start: self.planned, end: self.planned + 1800, event: NextTimeMeeting.event("uid-1")) })
        XCTAssertTrue(taken.allSatisfy { $0.updated == self.t0 + 1000 })
        XCTAssertEqual(taken.map(\.rank), [1, 2, 3, 4])
        XCTAssertEqual(taken[1].done, .init(callID: f, at: 42, quote: "the budget for the third quarter is fine", date: t0 + 500, byOwner: false))
        XCTAssertEqual(taken[2].reopened, [f])
        XCTAssertTrue(taken[3].isOpen)
        XCTAssertEqual(b.leftOpen(in: f).map(\.text), ["Open", "Reopened", "Moved to Sam"])
        XCTAssertEqual(b.discussed(in: f).map(\.text), ["Discussed"])
    }

    func testAnUncheckedMeetingIsLeftForTheTargetsCheck() throws {
        var a = NextTimeBook()
        a.points = [point("Open", 1) { $0.meeting = NextTimeMeeting(self.detail()) }]
        let moved = try XCTUnwrap(a.moved(callID: x, record: record))
        var b = NextTimeBook()
        b.takeIn(moved, as: x, ids: [UUID()], at: t0)
        XCTAssertFalse(b.checked.contains(x))
        var r = record
        r.utterances = [Utterance(track: .me, speakerLabel: "A", start: 1, end: 3, text: "Hello")]
        XCTAssertEqual(NextTimeRules.points(for: r, in: b, series: nil, people: PersonReferences(people: [])).map(\.text), ["Open"])
    }

    func testAFileOfANewerBuildDoesNotRead() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("MovedPointsTests-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(MovedPoints.fileName)
        var m = MovedPoints(checked: true, points: [.init(text: "Open", created: t0, rank: 1)])
        try JSONEncoder.move.encode(m).write(to: url)
        XCTAssertEqual(MovedPoints.read(url), m)
        m.version = MovedPoints.currentVersion + 1
        try JSONEncoder.move.encode(m).write(to: url)
        XCTAssertNil(MovedPoints.read(url))
        try Data("{".utf8).write(to: url)
        XCTAssertNil(MovedPoints.read(url))
    }
}
