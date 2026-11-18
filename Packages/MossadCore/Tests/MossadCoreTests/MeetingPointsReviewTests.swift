import XCTest
@testable import MossadCore

/// The review of the meeting points: what the synced book holds, the order of the series join and the check, a
/// meeting that moves to another profile, a 1:1 that the call contradicts, and a meeting that was never recorded.
final class MeetingPointsReviewTests: XCTestCase {
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

    private func invite(_ title: String = "Budget chat", inHours: Double = 24, attendees: [String] = ["Dana Lee", "Sam Carter"], uid: String? = "uid-1") -> UpcomingMeeting {
        UpcomingMeeting(title: title, start: now.addingTimeInterval(inHours * 3600), end: now.addingTimeInterval(inHours * 3600 + 1800),
                        attendees: attendees, platform: .meet, link: nil, uid: uid)
    }

    private func record(_ id: String, of u: UpcomingMeeting, voices: [String] = ["Sam Carter"]) -> CallRecord {
        var r = CallRecord(id: id, platform: .meet, bundleID: "", start: u.start.addingTimeInterval(90), end: u.end, status: .written)
        r.calendarTitle = u.title
        r.plannedStart = u.start
        r.plannedEnd = u.end
        r.attendees = u.attendees
        r.speakerNames["me:A"] = owner
        var lines = [Utterance(track: .me, speakerLabel: "A", start: 5, end: 9, text: "Hello, good to see you")]
        for (i, name) in voices.enumerated() {
            let label = String(UnicodeScalar(UInt8(66 + i)))
            r.speakerNames["them:\(label)"] = name
            lines.append(Utterance(track: .them, speakerLabel: label, start: Double(20 + i * 10), end: Double(25 + i * 10), text: "Hi there"))
        }
        r.utterances = lines
        return r
    }

    // MARK: I1

    func testTheSyncedBookHoldsNothingOfTheUpcomingMeeting() throws {
        let u = invite()
        var book = NextTimeBook()
        book.add("Ask about the Q3 budget", meeting: NextTimeMeeting(u, people: ["p-sam"]), at: now)
        let start = ISO8601DateFormatter().string(from: u.start), end = ISO8601DateFormatter().string(from: u.end)
        for data in [SharedPayload.nextTime(book).data, try JSONEncoder.coach.encode(book)] {
            let text = String(decoding: data, as: UTF8.self)
            XCTAssertFalse(text.contains("Budget chat"), text)
            XCTAssertFalse(text.contains(start), text)
            XCTAssertFalse(text.contains(end), text)
            XCTAssertFalse(text.contains(NextTimeMeeting.event("uid-1")!), text)
            XCTAssertFalse(text.contains("\"invited\""), text)
            XCTAssertFalse(text.contains("p-sam"), text)
            XCTAssertTrue(text.contains("\"meeting\""), text)
        }
    }

    // MARK: I2

    func testAOneOnOneThatMadeASeriesStillMovesItsPointToThePersonWhenTheCatalogRunsFirst() {
        let earlier = record("a", of: invite(inHours: -7 * 24, uid: "uid-0"))
        let u = invite()
        var book = NextTimeBook()
        let p = book.add("Ask about the Q3 budget", meeting: NextTimeMeeting(u, people: ["p-sam"]), at: now)!
        let c = record("c", of: u)
        let all = SeriesCatalog.build(records: [earlier, c], upcoming: [], owner: owner, directory: directory)
        XCTAssertNotNil(SeriesCatalog.series(ofCall: "c", in: all))
        book.followMeetings(upcoming: [], series: all, records: [earlier, c], at: now)
        let checked = NextTimeRules.points(for: c, in: book, series: SeriesCatalog.series(ofCall: "c", in: all), people: refs)
        NextTimeRules.apply([], checked: checked, call: c, to: &book, at: now, onlyOther: ("p-sam", "Sam Carter"))
        XCTAssertTrue(book.points.first { $0.id == p.id }!.isForPerson)
    }

    func testAOneOnOneThatMadeASeriesMovesItsPointToThePersonWhenTheCheckRunsFirst() {
        let earlier = record("a", of: invite(inHours: -7 * 24, uid: "uid-0"))
        let u = invite()
        var book = NextTimeBook()
        let p = book.add("Ask about the Q3 budget", meeting: NextTimeMeeting(u, people: ["p-sam"]), at: now)!
        let c = record("c", of: u)
        let all = SeriesCatalog.build(records: [earlier, c], upcoming: [], owner: owner, directory: directory)
        let checked = NextTimeRules.points(for: c, in: book, series: SeriesCatalog.series(ofCall: "c", in: all), people: refs)
        NextTimeRules.apply([], checked: checked, call: c, to: &book, at: now, onlyOther: ("p-sam", "Sam Carter"))
        book.followMeetings(upcoming: [], series: all, records: [earlier, c], at: now)
        XCTAssertTrue(book.points.first { $0.id == p.id }!.isForPerson)
    }

    func testAPointThatStayedWithAGroupMeetingStaysUnderItsSummary() {
        let group = ["Dana Lee", "Sam Carter", "Jo Park"]
        let earlier = record("a", of: invite(inHours: -7 * 24, attendees: group, uid: "uid-0"), voices: ["Sam Carter", "Jo Park"])
        let u = invite(attendees: group)
        var book = NextTimeBook()
        let p = book.add("Ask about the Q3 budget", meeting: NextTimeMeeting(u, people: ["p-sam", "p-jo"]), at: now)!
        let c = record("c", of: u, voices: ["Sam Carter", "Jo Park"])
        NextTimeRules.apply([], checked: [p], call: c, to: &book, at: now)
        let all = SeriesCatalog.build(records: [earlier, c], upcoming: [], owner: owner, directory: directory)
        book.followMeetings(upcoming: [], series: all, records: [earlier, c], at: now)
        XCTAssertEqual(book.leftOpen(in: "c").map(\.id), [p.id])
    }

    // MARK: I3

    func testAMeetingThatMovesAwayTakesItsMeetingPointsWithIt() {
        let u = invite()
        var book = NextTimeBook()
        let p = book.add("Ask about the Q3 budget", meeting: NextTimeMeeting(u, people: ["p-sam"]), at: now)!
        book.update(p.id, at: now) { $0.meeting?.calls = ["c"]; $0.done = .init(callID: "c", at: 5, quote: "q", date: now, byOwner: false) }
        book.forget(callID: "c", at: now)
        let after = book.points.first { $0.id == p.id }!
        XCTAssertTrue(NextTimeBook.forgotten(after))
        XCTAssertTrue(after.deleted)
        XCTAssertEqual(after.text, "")
    }

    func testAMeetingMarkedForAnotherProfileDuringTheCallTakesItsPointsByItsInvite() {
        let u = invite()
        var book = NextTimeBook()
        let p = book.add("Ask about the Q3 budget", meeting: NextTimeMeeting(u, people: ["p-sam"]), at: now)!
        let other = book.add("Not this one", meeting: NextTimeMeeting(invite("Lunch", uid: "uid-7")), at: now)!
        book.forget(callID: "c", record: record("c", of: u), at: now)
        XCTAssertTrue(NextTimeBook.forgotten(book.points.first { $0.id == p.id }!))
        XCTAssertNil(book.points.first { $0.id == p.id }!.meeting?.detail)
        XCTAssertFalse(book.points.first { $0.id == other.id }!.deleted)
    }

    /// The owner's decision: the points go with the meeting, also one the check moved from it to the person, whether
    /// that person stays here or not. A point the owner moved to the person by hand stays with a person who stays.
    func testAPointTheCheckMovedToAPersonGoesWithTheMeeting() {
        let u = invite()
        var book = NextTimeBook()
        let p = book.add("Ask about the Q3 budget", meeting: NextTimeMeeting(u, people: ["p-sam"]), at: now)!
        let c = record("c", of: u)
        NextTimeRules.apply([], checked: [p], call: c, to: &book, at: now, onlyOther: ("p-sam", "Sam Carter"))
        var kept = book
        kept.forget(callID: "c", record: c, at: now)
        XCTAssertTrue(NextTimeBook.forgotten(kept.points[0]), "Sam stays here, and the point went with the meeting")
        book.forget(callID: "c", record: c, gone: ["p-sam"], at: now)
        XCTAssertTrue(NextTimeBook.forgotten(book.points[0]))

        var byHand = NextTimeBook()
        let q = byHand.add("Ask about the Q3 budget", meeting: NextTimeMeeting(u, people: ["p-sam"]), at: now)!
        NextTimeRules.apply([], checked: [q], call: c, to: &byHand, at: now)
        byHand.move(q.id, toPerson: "p-sam", name: "Sam Carter", at: now)
        var stays = byHand
        stays.forget(callID: "c", record: c, at: now)
        XCTAssertTrue(stays.points[0].isOpen, "Sam stays here: the point the owner gave Sam stays with Sam")
        byHand.forget(callID: "c", record: c, gone: ["p-sam"], at: now)
        XCTAssertTrue(NextTimeBook.forgotten(byHand.points[0]), "a person who goes takes it, as before")
    }

    func testAMeetingThatWaitsForAMoveDoesNotListItsPointsAsNotRecorded() {
        let u = invite()
        var book = NextTimeBook()
        book.add("Ask about the Q3 budget", meeting: NextTimeMeeting(u, people: ["p-sam"]), at: now)
        var c = record("c", of: u)
        c.moveTo = "work"
        XCTAssertTrue(book.unrecorded(records: [c], now: now.addingTimeInterval(3 * 86_400)).isEmpty)
    }

    // MARK: I4

    private func onlyOther(_ r: CallRecord) -> (id: String, name: String)? {
        NextTimeRules.onlyOther(r, owner: owner, directory: directory, ownerEmails: ["dana@example.com"], people: refs)
    }

    func testAThirdVoiceOnTheCallIsNoOneOnOne() {
        XCTAssertNil(onlyOther(record("c", of: invite(), voices: ["Sam Carter", "Jo Park"])))
        // Two voices with no name are two people too.
        XCTAssertNil(onlyOther(record("c", of: invite(), voices: ["Speaker B", "Speaker C"])))
    }

    func testAnInviteThatWasNotSurelyTheCallsIsNoOneOnOne() {
        var r = record("c", of: invite())
        XCTAssertEqual(onlyOther(r)?.id, "p-sam")
        r.inviteNotSure = true
        XCTAssertNil(onlyOther(r))
    }

    func testASizeThatIsKnownAndNotAOneOnOneIsNoOneOnOne() {
        // One voice on the call audio, and a second person in the room with the owner: three people, not a 1:1.
        var r = record("c", of: invite())
        r.speakerNames["me:B"] = "Jo Park"
        r.utterances = [Utterance(track: .me, speakerLabel: "A", start: 0, end: 200, text: "Hello, good to see you"),
                        Utterance(track: .them, speakerLabel: "B", start: 200, end: 400, text: "Hi there"),
                        Utterance(track: .me, speakerLabel: "B", start: 400, end: 600, text: "And from the room, hello")]
        XCTAssertNil(onlyOther(r))
        // A size that is not known, with no other voice: the invite decides.
        r.utterances = []
        r.speakerNames = [:]
        XCTAssertEqual(onlyOther(r)?.id, "p-sam")
    }

    func testTheOneOtherVoiceAndTheInviteAgree() {
        XCTAssertEqual(onlyOther(record("c", of: invite()))?.id, "p-sam")
    }

    // MARK: I5

    func testAPointOfASureOneOnOneThatWasNotRecordedGoesToThePerson() {
        let u = invite(inHours: 1)
        var book = NextTimeBook()
        let p = book.add("Ask about the offsite", meeting: NextTimeMeeting(u, people: ["p-sam"], invited: 1), at: now)!
        let later = now.addingTimeInterval(86_400)
        // Before it is over, nothing moves.
        XCTAssertFalse(book.followMeetings(upcoming: [u], series: [], records: [], at: now, name: refs.name(of:)))
        XCTAssertTrue(book.followMeetings(upcoming: [], series: [], records: [], at: later, name: refs.name(of:)))
        let after = book.points.first { $0.id == p.id }!
        XCTAssertTrue(after.isForPerson)
        XCTAssertEqual(after.personName, "Sam Carter")
        XCTAssertEqual(after.meeting?.detail?.title, "Budget chat")
        XCTAssertNil(after.meeting?.calls)
        XCTAssertTrue(book.unrecorded(records: [], now: later).isEmpty)
    }

    func testAPointOfAGroupOrAnUnsureOneOnOneThatWasNotRecordedWaits() {
        let later = now.addingTimeInterval(86_400)
        var book = NextTimeBook()
        // Two people invited, one of them saved: not a sure 1:1.
        let a = book.add("Group", meeting: NextTimeMeeting(invite(inHours: 1, attendees: ["Dana Lee", "Sam Carter", "riley@example.org"]), people: ["p-sam"], invited: 2), at: now)!
        // One person invited who is not saved.
        let b = book.add("Unsure", meeting: NextTimeMeeting(invite("Intro", inHours: 1, attendees: ["Dana Lee", "riley@example.org"]), people: [], invited: 1), at: now)!
        book.followMeetings(upcoming: [], series: [], records: [], at: later, name: refs.name(of:))
        XCTAssertEqual(Set(book.unrecorded(records: [], now: later).map(\.id)), [a.id, b.id])
    }

    func testAOneOnOneThatWasRecordedIsNotSettledAsNotRecorded() {
        let u = invite(inHours: 1)
        var book = NextTimeBook()
        book.add("Ask about the offsite", meeting: NextTimeMeeting(u, people: ["p-sam"], invited: 1), at: now)
        XCTAssertFalse(book.followMeetings(upcoming: [], series: [], records: [record("c", of: u)], at: now.addingTimeInterval(86_400), name: refs.name(of:)))
        XCTAssertTrue(book.points[0].isForMeeting)
    }

    func testAWaitingPointIsOfferedToTheNextMeetingWithItsTitle() {
        let old = invite(inHours: -48)
        var book = NextTimeBook()
        let p = book.add("Ask about the offsite", meeting: NextTimeMeeting(old, people: ["p-sam", "p-jo"], invited: 2), at: now.addingTimeInterval(-3 * 86_400))!
        let waiting = book.unrecorded(records: [], now: now)
        XCTAssertEqual(waiting.map(\.id), [p.id])
        let next = invite(inHours: 24, uid: "uid-2"), after = invite(inHours: 24 * 8, uid: "uid-3")
        XCTAssertEqual(book.waiting(for: next, upcoming: [after, next], waiting: waiting).map(\.id), [p.id])
        XCTAssertTrue(book.waiting(for: after, upcoming: [after, next], waiting: waiting).isEmpty)
        book.give(p.id, to: MeetingDetail(next), at: now)
        XCTAssertEqual(book.points(forMeeting: next).map(\.id), [p.id])
        XCTAssertTrue(book.unrecorded(records: [], now: now).isEmpty)
    }

    // MARK: I1, this Mac's file

    func testTheDetailLivesInThisMacsFileAndComesBackOnLoad() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("meeting-local-\(UUID())")
        defer { try? FileManager.default.removeItem(at: dir) }
        let u = invite()
        try NextTimeBook.change(in: dir) { _ = $0.add("Ask about the Q3 budget", meeting: NextTimeMeeting(u, people: ["p-sam"], invited: 1)) }
        let synced = try String(contentsOf: dir.appendingPathComponent(NextTimeBook.fileName), encoding: .utf8)
        XCTAssertFalse(synced.contains("Budget chat"))
        let local = try String(contentsOf: dir.appendingPathComponent(MeetingPointsLocal.fileName), encoding: .utf8)
        XCTAssertTrue(local.contains("Budget chat"))
        XCTAssertEqual(try NextTimeBook.load(from: dir).points(forMeeting: u).count, 1)
        XCTAssertEqual(NextTimeBook.peek(in: dir)?.points(forMeeting: u).count, 1)
        // A merge with the server's copy, which has no detail, keeps it.
        let server = try JSONDecoder.coach.decode(NextTimeBook.self, from: SharedPayload.nextTime(try NextTimeBook.load(from: dir)).data)
        XCTAssertNil(server.points[0].meeting?.detail)
        XCTAssertEqual(try NextTimeBook.load(from: dir).merged(with: server).points(forMeeting: u).count, 1)
        XCTAssertEqual(server.merged(with: try NextTimeBook.load(from: dir)).points(forMeeting: u).count, 1)
    }

    func testAPointWhoseMeetingThisMacDoesNotKnowWaitsAndIsNeverInvisible() {
        var book = NextTimeBook()
        book.add("From another Mac", meeting: NextTimeMeeting(), at: now)
        XCTAssertEqual(book.unrecorded(records: [], now: now).map(\.text), ["From another Mac"])
        // With a call it is under that meeting.
        book.update(book.points[0].id, at: now) { $0.meeting?.calls = ["c"] }
        XCTAssertTrue(book.unrecorded(records: [], now: now).isEmpty)
        XCTAssertEqual(book.leftOpen(in: "c").count, 1)
    }

    func testADetailFileThatDoesNotReadIsSetAsideAndOneOfANewerBuildIsNeverSaved() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("meeting-local-\(UUID())")
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent(MeetingPointsLocal.fileName)
        try Data("not json".utf8).write(to: file)
        try NextTimeBook.change(in: dir) { _ = $0.add("A", meeting: NextTimeMeeting(invite()), at: now) }
        let names = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        XCTAssertTrue(names.contains { $0.contains("unreadable") }, "\(names)")
        XCTAssertTrue(try String(contentsOf: file, encoding: .utf8).contains("Budget chat"))
        let newer = #"{"version": 9, "points": {}}"#
        try Data(newer.utf8).write(to: file)
        try NextTimeBook.change(in: dir) { _ = $0.add("B", meeting: NextTimeMeeting(invite("Other", uid: "uid-5")), at: now) }
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), newer)
    }

    // MARK: Minors

    func testAMeetingTheOwnerMissedHoldsNoPointUnderItsSummary() {
        let u = invite()
        var book = NextTimeBook()
        book.add("Ask about the Q3 budget", meeting: NextTimeMeeting(u, people: ["p-sam"]), at: now)
        var notes = record("n", of: u)
        notes.source = CallRecord.geminiNotesSource
        notes.utterances = notes.utterances.filter { $0.track == .them }
        XCTAssertTrue(NextTimeRules.ownerMissed(notes))
        XCTAssertTrue(book.leftOpen(in: "n", record: notes).isEmpty)
    }

    func testASecondRecordingOfAOneOnOneReadsThePointThatTheFirstMovedToThePerson() {
        let u = invite()
        var book = NextTimeBook()
        let p = book.add("Ask about the Q3 budget", meeting: NextTimeMeeting(u, people: ["p-sam"]), at: now)!
        NextTimeRules.apply([], checked: [p], call: record("c", of: u), to: &book, at: now, onlyOther: ("p-sam", "Sam Carter"))
        var second = record("d", of: u)
        second.speakerNames["them:B"] = "Speaker B"
        XCTAssertEqual(NextTimeRules.points(for: second, in: book, series: nil, people: refs).map(\.id), [p.id])
    }

    func testTheCheckDoesNotWriteOverAPointTheOwnerMovedMeanwhile() {
        let u = invite()
        var book = NextTimeBook()
        let p = book.add("Ask about the Q3 budget", meeting: NextTimeMeeting(u, people: ["p-sam", "p-jo"]), at: now)!
        book.move(p.id, toPerson: "p-jo", name: "Jo Park", at: now)
        NextTimeRules.apply([], checked: [p], call: record("c", of: u), to: &book, at: now, onlyOther: ("p-sam", "Sam Carter"))
        XCTAssertEqual(book.points[0].personID, "p-jo")
    }
}
