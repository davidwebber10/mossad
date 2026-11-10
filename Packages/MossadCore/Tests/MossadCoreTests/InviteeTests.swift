import XCTest
@testable import MossadCore

/// The calendar gives a name and an address for each invited person. Both are kept, so the address can say who
/// a name is.
final class InviteeTests: XCTestCase {
    func testAnInviteeKeepsTheNameAndTheAddress() {
        let i = Invitee.make(name: "Carter, Sam", address: "mailto:Sam.Carter@Example.com", isCurrentUser: false)
        XCTAssertEqual(i, Invitee(name: "Carter, Sam", email: "sam.carter@example.com"))
        XCTAssertNil(i?.isSelf)
    }

    func testTheOwnersEntryIsMarked() {
        XCTAssertEqual(Invitee.make(name: "Avery Webb", address: "mailto:avery@example.com", isCurrentUser: true)?.isSelf, true)
    }

    func testAnEntryWithNoNameIsItsAddress() {
        XCTAssertEqual(Invitee.make(name: nil, address: "mailto:sam@example.com", isCurrentUser: false), Invitee(name: nil, email: "sam@example.com"))
        XCTAssertEqual(Invitee.make(name: "  ", address: "MAILTO:sam@example.com", isCurrentUser: false), Invitee(name: nil, email: "sam@example.com"))
    }

    func testANameThatIsTheAddressIsNotAName() {
        XCTAssertEqual(Invitee.make(name: "sam@example.com", address: "mailto:sam@example.com", isCurrentUser: false), Invitee(name: nil, email: "sam@example.com"))
        XCTAssertEqual(Invitee.make(name: "Sam@Example.com", address: "invalid:nomail", isCurrentUser: false), Invitee(name: nil, email: "sam@example.com"))
    }

    func testAnEncodedAddressAndAQueryAreRead() {
        XCTAssertEqual(Invitee.make(name: "Sam", address: "mailto:sam%2Bnotes@example.com?subject=Hello", isCurrentUser: false)?.email, "sam+notes@example.com")
    }

    func testAnAddressThatIsNotMailIsUnknownNotAnAddress() {
        // An Exchange account can give a directory path in place of an address.
        let path = "/o=ExchangeLabs/ou=Exchange%20Administrative%20Group/cn=Recipients/cn=1234-sam"
        XCTAssertEqual(Invitee.make(name: "Carter, Sam", address: path, isCurrentUser: false), Invitee(name: "Carter, Sam", email: nil))
        XCTAssertEqual(Invitee.make(name: "Carter, Sam", address: "invalid:nomail", isCurrentUser: false), Invitee(name: "Carter, Sam", email: nil))
        XCTAssertNil(Invitee.make(name: nil, address: "invalid:nomail", isCurrentUser: false), "nothing is known of this entry")
    }

    // MARK: The record

    private func event(_ participants: [Invitee]) -> CalendarEventInfo {
        CalendarEventInfo(title: "Review", start: Date(timeIntervalSince1970: 1_780_000_000), end: Date(timeIntervalSince1970: 1_780_001_800),
                          attendees: ["Carter, Sam", "dana@example.com"], text: "", isAllDay: false, participants: participants)
    }

    func testTheRecordKeepsThePairsAndTheOldList() throws {
        var r = CallRecord(id: "c", platform: .meet, bundleID: "b", start: Date(timeIntervalSince1970: 1_780_000_000),
                           end: Date(timeIntervalSince1970: 1_780_001_800), status: .written)
        let pairs = [Invitee(name: "Carter, Sam", email: "sam@example.com"), Invitee(name: nil, email: "dana@example.com")]
        r.setInvite(event(pairs))
        XCTAssertEqual(r.attendees, ["Carter, Sam", "dana@example.com"], "the old list is as before")
        XCTAssertEqual(r.invitees, pairs)
        let back = try JSONDecoder.callRecord.decode(CallRecord.self, from: JSONEncoder.callRecord.encode(r))
        XCTAssertEqual(back.invitees, pairs)
        // An invite read by a source that gives no pairs takes the old ones away with the old list.
        r.setInvite(event([]))
        XCTAssertNil(r.invitees)
    }

    func testARecordFromBeforeThePairsReads() throws {
        let old = #"{"id":"c","platform":"meet","bundleID":"b","start":"2026-05-28T20:26:40Z","end":"2026-05-28T20:56:40Z","status":"written","attendees":["Carter, Sam"]}"#
        let r = try JSONDecoder.callRecord.decode(CallRecord.self, from: Data(old.utf8))
        XCTAssertEqual(r.attendees, ["Carter, Sam"])
        XCTAssertNil(r.invitees)
        XCTAssertFalse(String(decoding: try JSONEncoder.callRecord.encode(r), as: UTF8.self).contains("invitees"), "and writes no empty list")
    }

    func testTheAddressOfAnInvitedName() {
        var r = CallRecord(id: "c", platform: .meet, bundleID: "b", start: Date(), end: Date(), status: .written)
        r.invitees = [Invitee(name: "Carter, Sam", email: "sam@example.com"), Invitee(name: "Lee, Dana", email: nil),
                      Invitee(name: "Riley Chen", email: "r1@example.com"), Invitee(name: "riley chen", email: "r2@example.com")]
        XCTAssertEqual(Invitee.emails(byName: r.invitees)["carter sam"], "sam@example.com")
        XCTAssertNil(Invitee.emails(byName: r.invitees)["lee dana"])
        XCTAssertNil(Invitee.emails(byName: r.invitees)["riley chen"], "two addresses for one name say nothing")
        XCTAssertTrue(Invitee.emails(byName: nil).isEmpty)
    }

    // MARK: The address says who a name is

    private let saved = PersonDirectory([.init(name: "Sam Carter", email: "sam.carter@example.com"), .init(name: "Dana Lee", email: "dana@example.com")])

    func testAnInvitedNameThatFitsNobodyIsThePersonWithItsAddress() {
        let invitees = [Invitee(name: "S. Carter (Contractor)", email: "sam.carter@example.com"), Invitee(name: "Dana Lee", email: "sam.carter@example.com")]
        XCTAssertNil(saved.link(for: "S. Carter (Contractor)"))
        let meeting = saved.with(invitees: [invitees[0]])
        XCTAssertEqual(meeting.link(for: "S. Carter (Contractor)"), "Sam Carter")
        XCTAssertEqual(meeting.match("S. Carter (Contractor)", among: ["Dana Lee"]), "Sam Carter")
        XCTAssertEqual(meeting.link(for: "Dana Lee"), "Dana Lee", "a name with no pair is as before")
        // An assistant sent the invite: the address beats the name.
        XCTAssertEqual(saved.with(invitees: [invitees[1]]).match("Dana Lee"), "Sam Carter")
        XCTAssertNotEqual(meeting, saved, "a page made for another invite is another page")
    }

    func testParticipationReadsThePair() {
        var r = CallRecord(id: "c", platform: .meet, bundleID: "b", start: Date(timeIntervalSince1970: 1_780_000_000),
                           end: Date(timeIntervalSince1970: 1_780_001_800), status: .written)
        r.attendees = ["S. Carter (Contractor)"]
        r.invitees = [Invitee(name: "S. Carter (Contractor)", email: "sam.carter@example.com")]
        r.speakerNames = ["me:A": "Avery Webb", "them:A": "Sam Carter"]
        r.utterances = [Utterance(track: .me, speakerLabel: "A", start: 0, end: 10, text: "Hello."),
                        Utterance(track: .them, speakerLabel: "A", start: 10, end: 30, text: "Hello to you.")]
        let p = MeetingAnalytics(record: r, owner: "Avery Webb", people: saved).participation
        XCTAssertEqual(p?.invited.map(\.person), ["Sam Carter"])
        XCTAssertEqual(p?.spoke.count, 1)
        XCTAssertEqual(p?.unmatchedSpeakers, [])
    }

    func testAMergedMeetingKeepsThePairsOfBothParts() {
        var a = CallRecord(id: "20261105-100000", platform: .meet, bundleID: "b", start: Date(timeIntervalSince1970: 1_780_000_000),
                           end: Date(timeIntervalSince1970: 1_780_000_600), status: .written)
        var b = CallRecord(id: "20261105-101500", platform: .meet, bundleID: "b", start: Date(timeIntervalSince1970: 1_780_000_900),
                           end: Date(timeIntervalSince1970: 1_780_001_800), status: .written)
        a.attendees = ["Carter, Sam"]
        a.invitees = [Invitee(name: "Carter, Sam", email: "sam@example.com")]
        b.attendees = ["Carter, Sam", "dana@example.com"]
        b.invitees = [Invitee(name: "Carter, Sam", email: "sam@example.com"), Invitee(name: nil, email: "dana@example.com")]
        let merged = MeetingMerge.combine([a, b], durations: [:])
        XCTAssertEqual(merged.attendees, ["Carter, Sam", "dana@example.com"])
        XCTAssertEqual(merged.invitees, [Invitee(name: "Carter, Sam", email: "sam@example.com"), Invitee(name: nil, email: "dana@example.com")])
    }
}
