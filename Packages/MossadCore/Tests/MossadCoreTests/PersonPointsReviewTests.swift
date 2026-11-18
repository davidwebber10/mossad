import XCTest
@testable import MossadCore

/// The review of "a person's points belong to a 1:1": the real 1:1s that the first rule did not see.
final class PersonPointsReviewTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let owner = "Dana Lee"

    private var people: [Person] {
        let me = Person(id: PersonID(rawValue: "p-dana"), displayName: owner, isOwner: true, origin: .owner, at: .distantPast)
        var sam = Person(id: PersonID(rawValue: "p-sam"), displayName: "Sam Carter", origin: .voiceNaming, at: .distantPast)
        sam.emails = [EmailIdentity(address: "sam@example.com", state: .verified, source: .owner, at: .distantPast),
                      EmailIdentity(address: "s.carter@example.org", state: .verified, source: .owner, at: .distantPast)]
        let jo = Person(id: PersonID(rawValue: "p-jo"), displayName: "Jo Park", origin: .voiceNaming, at: .distantPast)
        return [me, sam, jo]
    }

    private var refs: PersonReferences { PersonReferences(people: people) }
    /// The voice profiles know only Sam's first address: the second is in the people store alone.
    private var directory: PersonDirectory {
        PersonDirectory([.init(name: owner, email: "dana@example.com"), .init(name: "Sam Carter", email: "sam@example.com"), .init(name: "Jo Park", email: nil)])
    }

    private func ofInvite(_ attendees: [String]) -> String? {
        OneOnOne.person(ofInvite: attendees, owner: owner, directory: directory, ownerEmails: ["dana@example.com"], people: refs)
    }

    private func ofRecording(_ r: CallRecord) -> String? {
        OneOnOne.person(ofRecording: r, owner: owner, directory: directory, ownerEmails: ["dana@example.com"], people: refs)
    }

    /// A written call: the owner for a minute, then each voice for its seconds, on the call track.
    private func recording(_ id: String, attendees: [String] = [], title: String? = nil, voices: [(name: String?, seconds: TimeInterval)]) -> CallRecord {
        var r = CallRecord(id: id, platform: .zoom, bundleID: "", start: now.addingTimeInterval(-3600), end: now.addingTimeInterval(-1800), status: .written)
        r.attendees = attendees
        r.calendarTitle = title
        if title != nil {
            r.plannedStart = r.start
            r.plannedEnd = r.end
        }
        r.speakerNames["me:A"] = owner
        var lines = [Utterance(track: .me, speakerLabel: "A", start: 0, end: 60, text: "Thanks for making time. Let us go over the hiring plan for next quarter")]
        var at: TimeInterval = 60
        for (i, v) in voices.enumerated() {
            let label = String(UnicodeScalar(UInt8(66 + i)))
            if let name = v.name { r.speakerNames["them:\(label)"] = name }
            lines.append(Utterance(track: .them, speakerLabel: label, start: at, end: at + v.seconds, text: "Sure, the hiring plan for next quarter is ready"))
            at += v.seconds
        }
        r.utterances = lines
        return r
    }

    private func check(_ r: CallRecord, _ book: inout NextTimeBook, point: UUID) {
        let checked = NextTimeRules.points(for: r, in: book, series: nil, people: refs)
        let found = [NextTimeChecker.Found(point: point, at: 60, quote: "the hiring plan for next quarter is ready")]
        let other = NextTimeRules.onlyOther(r, owner: owner, directory: directory, ownerEmails: ["dana@example.com"], people: refs)
        NextTimeRules.apply(found, checked: checked, call: r, to: &book, at: now, onlyOther: other, person: ofRecording(r), canonical: refs.canonical)
    }

    private func samPoint(_ book: inout NextTimeBook) -> UUID {
        book.add("Hiring plan for next quarter", personID: "p-sam", personName: "Sam Carter", at: now.addingTimeInterval(-86_400))!.id
    }

    // MARK: I1: a recording with no invite

    func testACallWithNoInviteWithSamAloneClosesSamsPoint() {
        var book = NextTimeBook()
        let p = samPoint(&book)
        let r = recording("adhoc", voices: [("Sam Carter", 120)])
        XCTAssertEqual(ofRecording(r), "p-sam")
        check(r, &book, point: p)
        XCTAssertEqual(book.points.first { $0.id == p }?.done?.callID, "adhoc")
    }

    func testACallWithNoInviteWithTwoOtherPeopleOnlyNotesAMention() {
        var book = NextTimeBook()
        let p = samPoint(&book)
        let r = recording("adhoc", voices: [("Sam Carter", 120), ("Jo Park", 120)])
        XCTAssertNil(ofRecording(r))
        check(r, &book, point: p)
        let after = book.points.first { $0.id == p }!
        XCTAssertNil(after.done)
        XCTAssertEqual(after.mentions?.map(\.callID), ["adhoc"])
        // A voice with no name, or a person who is not surely saved, is not known: no 1:1.
        XCTAssertNil(ofRecording(recording("x", voices: [(nil, 120)])))
        XCTAssertNil(ofRecording(recording("y", voices: [("Riley Moss", 120)])))
    }

    func testACallWhoseInviteIsNotKnownYetIsNoOneOnOneByItsVoices() {
        var r = recording("w", voices: [("Sam Carter", 120)])
        r.inviteUnknown = true
        XCTAssertNil(ofRecording(r))
    }

    // MARK: I2: people and main voices, not keys

    func testTwoKeysOfOnePersonAndAStrayKeyDoNotMakeAOneOnOneAGroup() {
        let invite = ["Dana Lee", "Sam Carter"]
        XCTAssertEqual(ofRecording(recording("a", attendees: invite, title: "Sam / Dana", voices: [("Sam Carter", 600), ("Sam Carter", 300)])), "p-sam")
        XCTAssertEqual(ofRecording(recording("b", attendees: invite, title: "Sam / Dana", voices: [("Sam Carter", 600), (nil, 2)])), "p-sam")
        // A second person who really spoke is a group.
        XCTAssertNil(ofRecording(recording("c", attendees: invite, title: "Sam / Dana", voices: [("Sam Carter", 600), ("Jo Park", 300)])))
    }

    // MARK: I3: the live list

    func testAPointTickedInThisCallStaysInTheLiveList() {
        var book = NextTimeBook()
        let p = samPoint(&book)
        book.update(p) { $0.done = .init(callID: "live", at: 30, quote: nil, date: self.now, byOwner: true) }
        XCTAssertEqual(LivePoints.list(book, series: nil, oneOnOne: nil, callID: "live").map(\.id), [p])
        // Another call's tick is not this call's.
        XCTAssertTrue(LivePoints.list(book, series: nil, oneOnOne: nil, callID: "other").isEmpty)
    }

    func testAShortVoiceWithNoNameIsNoOtherVoiceLive() throws {
        var t = LiveTranscript()
        func turn(_ order: Int, _ label: String, from: Double, to: Double) -> Data {
            let json: [String: Any] = ["type": "Turn", "turn_order": order, "end_of_turn": true, "transcript": "Hello there, yes",
                                       "speaker_label": label, "words": [["start": from * 1000, "end": to * 1000, "word_is_final": true]]]
            return try! JSONSerialization.data(withJSONObject: json)
        }
        t.apply(turn(0, "A", from: 0, to: 30), source: .them, at: 1)
        t.names["0A"] = "Sam Carter"
        t.apply(turn(1, "B", from: 31, to: 32), source: .them, at: 31)
        XCTAssertEqual(t.otherVoices(owner: owner), ["Sam Carter"])
        // With 10 s of speech or more it may be another person.
        t.apply(turn(2, "B", from: 40, to: 52), source: .them, at: 40)
        XCTAssertEqual(t.otherVoices(owner: owner), ["Sam Carter", nil])
    }

    // MARK: I4: rooms on the Mac's calendar

    func testARoomIsNoInvitedPersonButAGroupAddressIs() {
        let withRoom = CalendarMatcher.invitedAttendees([("Dana Lee", nil), ("Sam Carter", nil), ("Room 4 North", "room"), ("Projector", "resource")])
        XCTAssertEqual(withRoom, ["Dana Lee", "Sam Carter"])
        XCTAssertEqual(ofInvite(withRoom), "p-sam")
        let withGroup = CalendarMatcher.invitedAttendees([("Dana Lee", nil), ("Sam Carter", nil), ("team@example.com", "group")])
        XCTAssertEqual(withGroup, ["Dana Lee", "Sam Carter", "team@example.com"])
        XCTAssertNil(ofInvite(withGroup))
    }

    // MARK: I5: the Recurring page

    func testASeriesIsAOneOnOneSeriesWithOneUsualPersonBesidesTheOwner() {
        XCTAssertEqual(OneOnOne.person(ofSeries: ["Dana Lee", "Sam Carter"], owner: owner, people: refs), "p-sam")
        XCTAssertEqual(OneOnOne.person(ofSeries: ["Sam Carter"], owner: owner, people: refs), "p-sam")
        XCTAssertNil(OneOnOne.person(ofSeries: ["Dana Lee", "Sam Carter", "Jo Park"], owner: owner, people: refs))
        // A usual person who is not saved is still a person.
        XCTAssertNil(OneOnOne.person(ofSeries: ["Dana Lee", "Sam Carter", "Riley Moss"], owner: owner, people: refs))
        XCTAssertNil(OneOnOne.person(ofSeries: ["Dana Lee", "Riley Moss"], owner: owner, people: refs))
    }

    // MARK: A second address

    func testAPersonInvitedUnderBothOfTheirAddressesIsOnePerson() {
        XCTAssertEqual(ofInvite(["Dana Lee", "s.carter@example.org"]), "p-sam")
        XCTAssertEqual(ofInvite(["dana@example.com", "sam@example.com", "s.carter@example.org"]), "p-sam")
        XCTAssertNil(ofInvite(["Dana Lee", "s.carter@example.org", "Jo Park"]))
    }

    // MARK: A mention, then the 1:1

    func testAPointThatCameUpInAGroupClosesInTheOneOnOneAfter() {
        var book = NextTimeBook()
        let p = samPoint(&book)
        check(recording("group", attendees: ["Dana Lee", "Sam Carter", "Jo Park"], title: "Product review", voices: [("Sam Carter", 120), ("Jo Park", 120)]), &book, point: p)
        XCTAssertTrue(book.points.first { $0.id == p }!.isOpen)
        var one = recording("one", attendees: ["Dana Lee", "Sam Carter"], title: "Sam / Dana", voices: [("Sam Carter", 600)])
        one.start = now.addingTimeInterval(-1200)
        one.end = now
        check(one, &book, point: p)
        let after = book.points.first { $0.id == p }!
        XCTAssertEqual(after.done?.callID, "one")
        XCTAssertEqual(after.mentions?.map(\.callID), ["group"])
    }
}
