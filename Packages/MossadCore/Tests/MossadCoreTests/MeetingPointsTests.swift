import XCTest
@testable import MossadCore

/// The owner's points on one meeting that is not part of a series: how a point finds its meeting again, what the
/// check after it does, where a point of a meeting that was never recorded goes, and the file an older build saves.
final class MeetingPointsTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let owner = "Dana Lee"

    private var people: [Person] {
        let me = Person(id: PersonID(rawValue: "p-dana"), displayName: owner, isOwner: true, origin: .owner, at: .distantPast)
        var sam = Person(id: PersonID(rawValue: "p-sam"), displayName: "Sam Carter", origin: .voiceNaming, at: .distantPast)
        sam.emails = [EmailIdentity(address: "sam@example.com", state: .verified, source: .owner, at: .distantPast)]
        let jo = Person(id: PersonID(rawValue: "p-jo"), displayName: "Jo Park", origin: .voiceNaming, at: .distantPast)
        return [me, sam, jo]
    }

    private var refs: PersonReferences { PersonReferences(people: people) }
    private var directory: PersonDirectory {
        PersonDirectory([.init(name: owner, email: "dana@example.com"), .init(name: "Sam Carter", email: "sam@example.com"), .init(name: "Jo Park", email: nil)])
    }

    private func invite(_ title: String = "Budget chat", inHours: Double = 24, attendees: [String] = ["Dana Lee", "Sam Carter"], uid: String? = "uid-1",
                        recurring: Bool = false) -> UpcomingMeeting {
        UpcomingMeeting(title: title, start: now.addingTimeInterval(inHours * 3600), end: now.addingTimeInterval(inHours * 3600 + 1800),
                        attendees: attendees, platform: .meet, link: nil, isRecurring: recurring, uid: uid)
    }

    private func record(_ id: String, of u: UpcomingMeeting, status: CallStatus = .written, lines: [(Int, Double, String)] = [(0, 5, "Hello Sam, good to see you"), (1, 20, "Hi Dana, thanks")]) -> CallRecord {
        var r = CallRecord(id: id, platform: .meet, bundleID: "", start: u.start.addingTimeInterval(90), end: u.end, status: status)
        r.calendarTitle = u.title
        r.plannedStart = u.start
        r.plannedEnd = u.end
        r.attendees = u.attendees
        r.speakerNames = ["me:A": owner, "them:B": "Sam Carter"]
        r.utterances = lines.map { s, at, text in Utterance(track: s == 0 ? .me : .them, speakerLabel: s == 0 ? "A" : "B", start: at, end: at + 10, text: text) }
        return r
    }

    private func bookWithPoint(for u: UpcomingMeeting, text: String = "Ask about the Q3 budget") -> (NextTimeBook, NextTimePoint) {
        var book = NextTimeBook()
        let p = book.add(text, meeting: NextTimeMeeting(u, people: NextTimeInvite.personIDs(u.attendees, people: refs)), at: now.addingTimeInterval(-3600))!
        return (book, p)
    }

    // MARK: Its own list

    func testAPointForOneMeetingIsInThatMeetingsListOnly() {
        let u = invite()
        let (book, p) = bookWithPoint(for: u)
        XCTAssertTrue(p.isForMeeting)
        XCTAssertFalse(p.isForPerson)
        XCTAssertEqual(p.meeting?.detail?.people, ["p-sam"])
        XCTAssertEqual(book.points(forMeeting: u).map(\.id), [p.id])
        XCTAssertTrue(book.points(forPerson: "p-sam").isEmpty)
        // The prep page: the meeting's own, then each person's, never twice.
        XCTAssertEqual(book.points(for: nil, meeting: u, people: ["p-sam"]).map(\.id), [p.id])
        XCTAssertTrue(book.points(for: nil, people: ["p-sam"]).isEmpty)
        XCTAssertTrue(book.points(forMeeting: invite("Budget chat", inHours: 48, uid: "uid-2")).isEmpty)
    }

    func testAMovedInviteIsTheSameMeetingByItsUID() {
        let u = invite()
        var (book, p) = bookWithPoint(for: u)
        var moved = invite(inHours: 30)
        moved.title = "Budget chat (moved)"
        XCTAssertTrue(p.meeting!.matches(moved))
        // A repeated event has one UID for every meeting: then only the title and the start count.
        XCTAssertFalse(p.meeting!.matches(invite("Budget chat (moved)", inHours: 30, recurring: true)))
        // The point follows the invite's new times, which a recording of it then has.
        XCTAssertTrue(book.followMeetings(upcoming: [moved], series: [], records: [], at: now))
        XCTAssertEqual(book.points[0].meeting?.detail?.start, moved.start)
        XCTAssertEqual(book.points[0].updated, p.updated)
        XCTAssertTrue(book.points[0].meeting!.matches(record("c", of: moved)))
        XCTAssertFalse(book.followMeetings(upcoming: [moved], series: [], records: [], at: now))
        p = book.points[0]
        XCTAssertTrue(p.isForMeeting)
    }

    func testARecordingOfTheMeetingIsFoundByItsInvite() {
        let u = invite()
        let (_, p) = bookWithPoint(for: u)
        XCTAssertTrue(p.meeting!.matches(record("c", of: u)))
        XCTAssertFalse(p.meeting!.matches(record("d", of: invite("Budget chat", inHours: 72, uid: "uid-9"))))
        var noInvite = record("e", of: u)
        noInvite.calendarTitle = nil
        XCTAssertFalse(p.meeting!.matches(noInvite))
    }

    // MARK: During the call

    func testTheLiveListHasTheMeetingsOwnPoints() {
        let u = invite()
        var (book, p) = bookWithPoint(for: u)
        let other = book.add("For Sam", personID: "p-sam", personName: "Sam Carter", at: now)!
        let live = record("c", of: u, status: .recording)
        XCTAssertEqual(LivePoints.list(book, series: nil, people: ["p-sam"], callID: "c", record: live).map(\.id), [p.id, other.id])
        XCTAssertEqual(LivePoints.list(book, series: nil, people: ["p-sam"], callID: "c").map(\.id), [other.id])
        // A tick in this call keeps it in the list, to take back.
        book.update(p.id, at: now) { $0.done = .init(callID: "c", at: 30, quote: nil, date: now, byOwner: true) }
        XCTAssertEqual(LivePoints.list(book, series: nil, people: [], callID: "c", record: live).map(\.id), [p.id])
        p = book.points[0]
        XCTAssertFalse(p.isOpen)
    }

    // MARK: The check after the call

    func testTheCheckReadsTheMeetingsOwnPointsOnlyInThatMeeting() {
        let u = invite()
        let (book, p) = bookWithPoint(for: u)
        XCTAssertEqual(NextTimeRules.points(for: record("c", of: u), in: book, series: nil, people: refs).map(\.id), [p.id])
        XCTAssertTrue(NextTimeRules.points(for: record("d", of: invite("Lunch", uid: "x")), in: book, series: nil, people: refs).isEmpty)
    }

    func testARaisedPointIsDiscussedWithItsQuote() {
        let u = invite()
        var (book, p) = bookWithPoint(for: u)
        let r = record("c", of: u)
        NextTimeRules.apply([.init(point: p.id, at: 5, quote: "Hello Sam good to see you")], checked: [p], call: r, to: &book, at: now,
                            onlyOther: ("p-sam", "Sam Carter"))
        p = book.points[0]
        XCTAssertEqual(p.done?.callID, "c")
        XCTAssertEqual(p.done?.quote, "Hello Sam good to see you")
        XCTAssertTrue(p.isForMeeting)
        XCTAssertEqual(book.discussed(in: "c").map(\.id), [p.id])
    }

    func testAPointNotRaisedInAOneOnOneMovesToThatPerson() {
        let u = invite()
        var (book, p) = bookWithPoint(for: u)
        let r = record("c", of: u)
        let other = NextTimeRules.onlyOther(r, owner: owner, directory: directory, ownerEmails: ["dana@example.com"], people: refs)
        XCTAssertEqual(other?.id, "p-sam")
        NextTimeRules.apply([], checked: [p], call: r, to: &book, at: now, onlyOther: other)
        p = book.points[0]
        XCTAssertTrue(p.isOpen)
        XCTAssertTrue(p.isForPerson)
        XCTAssertFalse(p.isForMeeting)
        XCTAssertEqual(p.personName, "Sam Carter")
        XCTAssertEqual(p.carried, ["c"])
        XCTAssertEqual(p.meeting?.calls, ["c"])
        XCTAssertEqual(book.points(forPerson: "p-sam").map(\.id), [p.id])
        XCTAssertTrue(book.leftOpen(in: "c", record: r).isEmpty)
        XCTAssertTrue(book.checked.contains("c"))
    }

    func testAPointNotRaisedInAGroupStaysWithTheMeeting() {
        let u = invite(attendees: ["Dana Lee", "Sam Carter", "Jo Park"])
        var (book, p) = bookWithPoint(for: u)
        let r = record("c", of: u)
        XCTAssertNil(NextTimeRules.onlyOther(r, owner: owner, directory: directory, ownerEmails: ["dana@example.com"], people: refs))
        NextTimeRules.apply([], checked: [p], call: r, to: &book, at: now)
        p = book.points[0]
        XCTAssertTrue(p.isOpen)
        XCTAssertTrue(p.isForMeeting)
        XCTAssertNil(p.carried)
        XCTAssertEqual(book.leftOpen(in: "c").map(\.id), [p.id])
        // Its recording is found: it is not among the meetings that were not recorded.
        XCTAssertTrue(book.unrecorded(records: [r], now: now.addingTimeInterval(3 * 86_400)).isEmpty)
    }

    func testAOneOnOneWithSomeoneNotSurelySavedIsNotAOneOnOne() {
        let u = invite(attendees: ["Dana Lee", "riley@example.org"])
        XCTAssertNil(NextTimeRules.onlyOther(record("c", of: u), owner: owner, directory: directory, ownerEmails: ["dana@example.com"], people: refs))
    }

    func testTheOwnerCanMoveAPointThatStayed() {
        let u = invite(attendees: ["Dana Lee", "Sam Carter", "Jo Park"])
        var (book, p) = bookWithPoint(for: u)
        book.move(p.id, toPerson: "p-jo", name: "Jo Park", at: now)
        p = book.points[0]
        XCTAssertTrue(p.isForPerson)
        XCTAssertTrue(book.points(forMeeting: u).isEmpty)
        XCTAssertEqual(book.points(forPerson: "p-jo").map(\.id), [p.id])
    }

    // MARK: A meeting that was never recorded

    func testAPointOfAMeetingThatWasNotRecordedWaitsInOnePlace() {
        let u = invite(inHours: 1)
        let (book, p) = bookWithPoint(for: u)
        // Before the meeting is over it belongs to the meeting.
        XCTAssertTrue(book.unrecorded(records: [], now: now).isEmpty)
        let later = now.addingTimeInterval(86_400)
        XCTAssertEqual(book.unrecorded(records: [], now: later).map(\.id), [p.id])
        // A recording that is still being processed holds it; one the owner missed does not.
        XCTAssertTrue(book.unrecorded(records: [record("c", of: u, status: .transcribed)], now: later).isEmpty)
        var notes = record("n", of: u)
        notes.source = CallRecord.geminiNotesSource
        notes.speakerNames = ["them:B": "Sam Carter"]
        notes.utterances = [Utterance(track: .them, speakerLabel: "B", start: 5, end: 9, text: "Hello all")]
        XCTAssertTrue(NextTimeRules.ownerMissed(notes))
        XCTAssertEqual(book.unrecorded(records: [notes], now: later).map(\.id), [p.id])
        // It is never closed by itself.
        XCTAssertTrue(book.points[0].isOpen)
    }

    // MARK: A meeting that becomes a series

    func testAPointJoinsTheSeriesOnceTheMeetingHasOne() {
        let u = invite()
        var (book, p) = bookWithPoint(for: u)
        let earlier = record("a", of: invite(inHours: -7 * 24, uid: "uid-0"))
        var next = u
        next.isRecurring = true
        let all = SeriesCatalog.build(records: [earlier], upcoming: [next], owner: owner, directory: directory)
        let s = SeriesCatalog.series(of: next, in: all)!
        XCTAssertTrue(book.followMeetings(upcoming: [next], series: all, records: [earlier], at: now))
        p = book.points[0]
        XCTAssertFalse(p.isForMeeting)
        XCTAssertTrue(p.belongs(to: s))
        XCTAssertEqual(p.updated, now)
        XCTAssertEqual(book.points(of: s).open.map(\.id), [p.id])
        XCTAssertTrue(book.points(forMeeting: next).isEmpty)
        XCTAssertNotNil(p.meeting)
    }

    // MARK: From words

    func testAPointFromWordsLandsOnTheOneMeeting() {
        let u = invite()
        var book = NextTimeBook()
        guard case .added(let p) = NextTimeAdd.add("Ask about the Q3 budget", to: PointTarget.place(u, in: []), people: refs, book: &book, at: now) else {
            return XCTFail()
        }
        XCTAssertTrue(p.isForMeeting)
        XCTAssertEqual(p.meeting?.detail?.people, ["p-sam"])
        XCTAssertEqual(book.points(forMeeting: u).map(\.id), [p.id])
    }

    // MARK: The file

    func testAnOlderBuildNeitherLosesNorMisreadsAMeetingPoint() throws {
        let u = invite()
        var (mac, p) = bookWithPoint(for: u)
        mac.update(p.id, at: now) { $0.meeting?.calls = ["c"] }
        // An older build decodes with the fields it knows, and saves an edit.
        var older = try JSONDecoder.coach.decode(OldBook.self, from: JSONEncoder.coach.encode(mac))
        older.points[0].text = "Ask about the Q3 budget, and hiring"
        older.points[0].updated = now.addingTimeInterval(1000)
        let saved = try JSONDecoder.coach.decode(NextTimeBook.self, from: JSONEncoder.coach.encode(older))
        XCTAssertEqual(saved.version, 1)
        XCTAssertNil(saved.points[0].meeting)
        // In the older build's lists it is in none: not a person's, not a series'.
        XCTAssertFalse(saved.points[0].isForPerson)
        XCTAssertNil(saved.points[0].seriesID)
        XCTAssertTrue(saved.points[0].isOpen)
        for merged in [mac.merged(with: saved), saved.merged(with: mac)] {
            XCTAssertEqual(merged.points[0].text, "Ask about the Q3 budget, and hiring")
            XCTAssertEqual(merged.points[0].meeting?.detail?.title, "Budget chat")
            XCTAssertEqual(merged.points[0].meeting?.calls, ["c"])
            XCTAssertTrue(merged.points[0].isForMeeting)
        }
        p = mac.points[0]
        XCTAssertEqual(NextTimeBook.currentVersion, 1)
    }

    func testAMovedPointStaysMovedWhenAnOlderCopyMerges() throws {
        let u = invite()
        var (mac, p) = bookWithPoint(for: u)
        let before = mac
        NextTimeRules.apply([], checked: [p], call: record("c", of: u), to: &mac, at: now, onlyOther: ("p-sam", "Sam Carter"))
        for merged in [mac.merged(with: before), before.merged(with: mac)] {
            p = merged.points[0]
            XCTAssertTrue(p.isForPerson)
            XCTAssertFalse(p.isForMeeting)
        }
    }
}

/// `next-time.json` as builds before the meeting points read and write it.
private struct OldBook: Codable {
    var version: Int
    var points: [OldPoint]
    var answers: [SuggestionAnswer]
    var checked: [String]
    var movedCalls: [String]?
}

private struct OldPoint: Codable {
    var id: UUID
    var text: String
    var seriesID: String?
    var seriesKeys: [String]?
    var seriesTitle: String?
    var personID: String?
    var personName: String?
    var rank: Double
    var done: NextTimePoint.Discussed?
    var carried: [String]?
    var reopened: [String]?
    var mentions: [NextTimePoint.Mention]?
    var suggestion: String?
    var deleted: Bool
    var created: Date
    var updated: Date
}
