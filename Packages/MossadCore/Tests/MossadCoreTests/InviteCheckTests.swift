import XCTest
@testable import MossadCore

/// The morning of three wrong titles, with made-up names. 10:00 is t0; every call ran in a browser whose tab list could
/// not be read, so it has no link, and its window gave no title key.
final class InviteCheckTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    let owner = "Avery Webb"

    func at(_ minutes: Double) -> Date { t0.addingTimeInterval(minutes * 60) }

    func event(_ title: String, _ from: Double, _ to: Double, _ guests: [(String, String)], link: String) -> CalendarEventInfo {
        let people = [Invitee(name: owner, email: "avery@example.com", isSelf: true)] + guests.map { Invitee(name: $0.0, email: $0.1) }
        var e = CalendarEventInfo(title: title, start: at(from), end: at(to), attendees: people.map { $0.name ?? "" },
                                  text: "https://meet.google.com/\(link)", isAllDay: false, participants: people)
        e.eventID = title
        return e
    }

    var leadership: CalendarEventInfo {
        event("Leadership sync", 0, 30, [("Sam Carter", "sam@example.com"), ("Jordan Lee", "jordan@example.com"),
                                        ("Robin Ash", "robin@example.com"), ("Casey Moore", "casey@example.com")], link: "aaa-aaaa-aaa")
    }
    var quick: CalendarEventInfo { event("Quick check", 30, 60, [("Dana Fox", "dana@example.com")], link: "bbb-bbbb-bbb") }
    var meetup: CalendarEventInfo {
        event("Team meetup", 60, 90, (1...11).map { ("Guest \($0)", "guest\($0)@example.com") }, link: "ccc-cccc-ccc")
    }
    var morning: [CalendarEventInfo] { [leadership, quick, meetup] }

    func profile(_ name: String, _ email: String? = nil, owner: Bool = false) -> VoiceProfile {
        VoiceProfile(name: name, isOwner: owner, embeddings: [[1, 0, 0, 0]], email: email)
    }

    var profiles: [VoiceProfile] {
        [profile(owner, "avery@example.com", owner: true), profile("Sam Carter", "sam@example.com"), profile("Jordan Lee", "jordan@example.com"),
         profile("Robin Ash", "robin@example.com"), profile("Dana Fox", "dana@example.com"), profile("Guest 3", "guest3@example.com"),
         profile("Pat Quinn", "pat@example.com")]
    }

    func answer(from: Double, to: Double, voices: Set<String>?, link: String? = nil, key: String? = nil,
                events: [CalendarEventInfo]? = nil) -> InviteAnswer {
        InviteAnswer.of(platform: .meet, link: link, titleKey: key, start: at(from), end: at(to), events: events ?? morning, voices: voices,
                        invited: InviteCheck.invitedVoices(profiles: profiles, people: []))
    }

    /// Call 1, 10:01 to 11:04: the overlap picks "Quick check" (30 minutes against 29), but three people of the
    /// "Leadership sync" spoke and were named for sure.
    func testCall1GoesToTheMeetingWhosePeopleSpoke() {
        XCTAssertEqual(answer(from: 1, to: 64, voices: nil), .guess(quick), "before the voices: a guess")
        XCTAssertEqual(answer(from: 1, to: 64, voices: ["Sam Carter", "Jordan Lee", "Robin Ash"]), .sure(leadership))
    }

    /// Call 2, 11:05 to 11:19: the late "Quick check", whose event ended 5 minutes before the call; its one invited
    /// person spoke. "Team meetup" overlaps it and none of its eleven people spoke.
    func testCall2GoesToTheEventThatEndedFiveMinutesBefore() {
        XCTAssertEqual(answer(from: 65, to: 79, voices: nil), .guess(meetup))
        XCTAssertEqual(answer(from: 65, to: 79, voices: ["Dana Fox"]), .sure(quick))
    }

    /// Call 3, 11:24 to 11:34: an unplanned call with one voice that Mossad does not know. Nothing says which event it
    /// is: the overlap's event stays a guess, and a guess gives no calendar title (`CallRecordTitleTests`).
    func testCall3KeepsAGuess() {
        XCTAssertEqual(answer(from: 84, to: 94, voices: []), .guess(meetup))
    }

    func testVoicesThatAreInvitedNowhereMeanAnotherCall() {
        XCTAssertEqual(answer(from: 84, to: 94, voices: ["Pat Quinn"]), .none, "a known voice, invited to no event: another call")
    }

    func testATieIsAGuessAndNoVoiceConfirmsAnEventWithoutItsPeople() {
        var other = leadership
        other.title = "Leadership prep"
        other.eventID = "prep"
        other.start = at(-5)
        other.end = at(20)
        XCTAssertEqual(answer(from: 1, to: 25, voices: ["Sam Carter"], events: [leadership, other]), .guess(leadership),
                       "both invite the one voice: not known which")
        XCTAssertEqual(answer(from: 1, to: 25, voices: ["Sam Carter", "Dana Fox"], events: [leadership, quick]), .guess(leadership),
                       "one each: a tie, and the event picked holds one of them")
    }

    /// A sure answer by the link or the title is never changed by voices; a link no event holds is no invite.
    func testALinkOrATitleWinsOverTheVoices() {
        XCTAssertEqual(answer(from: 1, to: 64, voices: ["Sam Carter", "Jordan Lee", "Robin Ash"], link: "bbb-bbbb-bbb"), .sure(quick))
        XCTAssertEqual(answer(from: 84, to: 94, voices: ["Sam Carter"], link: "zzz-zzzz-zzz"), .none)
        XCTAssertEqual(answer(from: 1, to: 64, voices: ["Dana Fox"], key: CallTitleWatch.key("Leadership sync")), .sure(leadership))
    }

    /// An event more than 10 minutes before or after the recording is no candidate.
    func testTheWindowOfTenMinutes() {
        let late = event("Quick check", 30, 54, [("Dana Fox", "dana@example.com")], link: "bbb-bbbb-bbb")
        XCTAssertEqual(answer(from: 65, to: 79, voices: ["Dana Fox"], events: [late, meetup]), .none, "it ended 11 minutes before")
        XCTAssertEqual(InviteCheck.candidates(platform: .meet, link: nil, start: at(65), end: at(79), in: [late, meetup]), [meetup])
    }

    /// A voice named from the invite is no proof of it; the owner is never counted.
    func testOnlyVoicesNamedByTheirOwnScoreCount() {
        var r = CallRecord(id: "x", platform: .meet, bundleID: "com.google.Chrome", start: at(65), end: at(79), status: .identified)
        r.speakerNames = ["me:A": owner, "them:A": "Dana Fox", "them:B": "Guest 3"]
        r.fromInvite = ["them:B"]
        XCTAssertEqual(r.namedVoices(without: [owner]), ["Dana Fox"])
    }
}
