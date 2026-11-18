import XCTest
@testable import MossadCore

/// The calendar's answer for a recording, by the link, the title, and the voices, with made-up names. 10:00 is t0. Main's
/// behavior stays for every call unless positive evidence says otherwise.
final class InviteCheckTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    let owner = "Avery Webb"

    func at(_ minutes: Double) -> Date { t0.addingTimeInterval(minutes * 60) }

    func event(_ title: String, _ from: Double, _ to: Double, _ guests: [(String, String)], link: String,
               host: String = "https://meet.google.com/", group: String? = nil) -> CalendarEventInfo {
        var people = [Invitee(name: owner, email: "avery@example.com", isSelf: true)] + guests.map { Invitee(name: $0.0, email: $0.1) }
        if let group { people.append(Invitee(name: nil, email: group, kind: "group")) }
        var e = CalendarEventInfo(title: title, start: at(from), end: at(to), attendees: people.map { $0.name ?? $0.email ?? "" },
                                  text: host + link, isAllDay: false, participants: people)
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

    /// The answer before the voices, then with `voices` as the evidence (nil: no check).
    func answer(_ platform: Platform = .meet, from: Double, to: Double, voices: Set<String>?, link: String? = nil, key: String? = nil,
                events: [CalendarEventInfo]? = nil, whole: Bool = true, unknown: Bool = false) -> InviteAnswer {
        let events = events ?? morning
        let first = InviteAnswer.of(platform: platform, link: link, titleKey: key, start: at(from), end: at(to), events: events, whole: whole)
        guard let voices else { return first }
        return first.checked(platform: platform, link: link, start: at(from), end: at(to), events: events, evidence: voices,
                             unknownVoices: unknown, invited: InviteCheck.invitedVoices(profiles: profiles, people: []))
    }

    // MARK: The three calls of the bug

    /// Call 1, 10:01 to 11:04: the overlap picks "Quick check" (30 minutes against 29), not sure; three people of the
    /// overlapping "Leadership sync" spoke and were named by their own scores.
    func testCall1TheOverlappingMeetingWhosePeopleSpokeReplacesThePick() {
        XCTAssertEqual(answer(from: 1, to: 64, voices: nil), .picked(quick, sure: false))
        XCTAssertEqual(answer(from: 1, to: 64, voices: ["Sam Carter", "Jordan Lee", "Robin Ash"]), .proved(leadership))
        XCTAssertEqual(answer(from: 1, to: 64, voices: nil, key: CallTitleWatch.key("Leadership sync")), .proved(leadership), "or by its title")
    }

    /// Call 2, 11:05 to 11:19: the late "Quick check", whose event ended 5 minutes before; its one invited person spoke.
    /// "Team meetup" is the one overlapping event, so main's pick is sure; the near event replaces it on the evidence.
    func testCall2TheEventThatEndedFiveMinutesBeforeReplacesTheOneCandidatePick() {
        XCTAssertEqual(answer(from: 65, to: 79, voices: nil), .picked(meetup, sure: true))
        XCTAssertEqual(answer(from: 65, to: 79, voices: ["Dana Fox"]), .proved(quick))
    }

    /// Call 3, 11:24 to 11:34: an unplanned call with one voice that Mossad does not know. With no evidence the pick stays,
    /// as on main. With the code of its title, which no event holds, a whole read proves there is no invite.
    func testCall3ThePickStaysWithoutEvidenceAndAnUnheldCodeIsNoInvite() {
        XCTAssertEqual(answer(from: 84, to: 94, voices: []), .picked(meetup, sure: true))
        XCTAssertEqual(answer(from: 84, to: 94, voices: [], link: "zzz-zzzz-zzz"), .noInvite)
        XCTAssertEqual(answer(from: 84, to: 94, voices: [], link: "zzz-zzzz-zzz", whole: false), .nothing, "an unknown calendar says nothing")
    }

    // MARK: Main stays

    /// A new user's Zoom call: no saved voice, the Zoom app gives no link. Sure by the one candidate, as on main.
    func testANewUsersZoomCallStaysSure() {
        let call = event("Vendor call", 0, 30, [("Lee Morgan", "lee@example.com")], link: "123456789", host: "https://zoom.us/j/")
        let a = answer(.zoom, from: 1, to: 29, voices: [], events: [call])
        XCTAssertEqual(a, .picked(call, sure: true))
        XCTAssertTrue(a.isSure)
    }

    /// A first call with a client: the client has no saved voice, a colleague who is not invited speaks. Nothing replaces.
    func testAFirstClientCallStays() {
        let client = event("Client intro", 0, 30, [("Morgan Hale", "morgan@client.example")], link: "ddd-dddd-ddd")
        XCTAssertEqual(answer(from: 1, to: 29, voices: ["Pat Quinn"], events: [client]), .picked(client, sure: true))
    }

    /// Two meetings in a row with the same people, the call overlaps both: a tie keeps the pick.
    func testTwoMeetingsWithTheSamePeopleTieAndThePickStays() {
        let standup = event("Standup", 0, 15, [("Sam Carter", "sam@example.com"), ("Jordan Lee", "jordan@example.com")], link: "eee-eeee-eee")
        let planning = event("Planning", 15, 60, [("Sam Carter", "sam@example.com"), ("Jordan Lee", "jordan@example.com")], link: "fff-ffff-fff")
        XCTAssertEqual(answer(from: 10, to: 50, voices: ["Sam Carter", "Jordan Lee"], events: [standup, planning]), .picked(planning, sure: false))
    }

    /// The pick invites the team through a group address: an event that ended before the call does not replace it.
    func testANearEventDoesNotReplaceAPickWithAGroupAddress() {
        let design = event("Design sync", -30, 0, [("Sam Carter", "sam@example.com"), ("Jordan Lee", "jordan@example.com")], link: "ggg-gggg-ggg")
        let review = event("Sprint review", 1, 61, [], link: "hhh-hhhh-hhh", group: "team@example.com")
        XCTAssertEqual(answer(from: 2, to: 58, voices: ["Sam Carter", "Jordan Lee"], events: [design, review]), .picked(review, sure: true))
    }

    /// A call that runs one minute into the next event: two candidates, main's pick stays, not sure.
    func testACallThatRunsOneMinuteIntoTheNextEventKeepsMainsPick() {
        XCTAssertEqual(answer(from: 0, to: 31, voices: ["Pat Quinn"]), .picked(leadership, sure: false))
    }

    // MARK: The rules of a replacement

    func testANearEventNeedsEveryEvidenceVoiceAndThePickToHaveNone() {
        XCTAssertEqual(answer(from: 65, to: 79, voices: ["Dana Fox", "Pat Quinn"]), .picked(meetup, sure: true),
                       "a voice invited to neither: the near event does not have them all")
        XCTAssertEqual(answer(from: 65, to: 79, voices: ["Dana Fox", "Guest 3"]), .picked(meetup, sure: true), "the pick has one of them")
        let late = event("Quick check", 30, 54, [("Dana Fox", "dana@example.com")], link: "bbb-bbbb-bbb")
        XCTAssertEqual(answer(from: 65, to: 79, voices: ["Dana Fox"], events: [late, meetup]), .picked(meetup, sure: true),
                       "it ended 11 minutes before: no candidate")
        XCTAssertEqual(answer(from: 65, to: 79, voices: ["Dana Fox"], events: [quick]), .nothing, "no pick: nothing is set, as on main")
        XCTAssertEqual(answer(from: 65, to: 79, voices: ["Dana Fox"], unknown: true), .picked(meetup, sure: true),
                       "a voice heard and not named can be the pick's person")
    }

    func testAnOverlappingEventNeedsStrictlyMoreThanThePick() {
        XCTAssertEqual(answer(from: 1, to: 64, voices: ["Sam Carter", "Dana Fox"]), .picked(quick, sure: false), "one each: the pick stays")
        XCTAssertEqual(answer(from: 1, to: 64, voices: ["Sam Carter", "Jordan Lee", "Dana Fox"]), .proved(leadership))
    }

    /// A proof by the link or the title is never changed by voices; a room keeps main's rule.
    func testAProofIsNeverChangedByVoices() {
        XCTAssertEqual(answer(from: 1, to: 64, voices: ["Sam Carter", "Jordan Lee", "Robin Ash"], link: "bbb-bbbb-bbb"), .proved(quick))
        XCTAssertEqual(answer(from: 65, to: 79, voices: ["Dana Fox"], key: CallTitleWatch.key("Team meetup")), .proved(meetup))
        let room = CalendarEventInfo(title: "Planning", start: at(0), end: at(30), attendees: [], text: "Room 4", isAllDay: false)
        XCTAssertEqual(answer(.inPerson, from: 1, to: 29, voices: ["Sam Carter"], events: [room]), .picked(room, sure: true))
    }

    /// Only voices named by their own score are evidence: not from the invite, not the owner, not a letter, not provisional.
    func testTheEvidence() {
        let names = ["me:A": owner, "them:A": "Dana Fox", "them:B": "Guest 3", "them:C": "Speaker C", "them:D": "Jo Fenwick"]
        XCTAssertEqual(InviteCheck.evidence(names: names, fromInvite: ["them:B"], owners: [owner], provisional: ["Jo Fenwick"]), ["Dana Fox"])
    }

    /// The first naming gets the people of every candidate, overlapping or near, and is never sure.
    func testThePoolOfTheFirstNaming() {
        let pool = InviteCheck.pool(InviteCheck.candidates(platform: .meet, start: at(65), end: at(79), in: morning))
        XCTAssertEqual(pool?.sure, false)
        XCTAssertTrue(pool?.guests.contains { $0.email == "dana@example.com" } == true, "the near event's person")
        XCTAssertTrue(pool?.guests.contains { $0.email == "guest3@example.com" } == true, "the overlapping event's person")
        XCTAssertFalse(pool?.guests.contains { $0.email == "sam@example.com" } == true, "an event out of the window")
    }

    // MARK: The second review

    /// N1: the owner joins 30 s early, and the meeting before lists more of the heard voices than the pick. Its 30 s are
    /// no overlap for a replacement: it is a near event, and the pick has a voice of its own, so the pick stays.
    func testN1AnEarlyJoinDoesNotGiveTheCallToTheMeetingBefore() {
        let teamSync = event("Team sync", -30, 0, [("Sam Carter", "sam@example.com"), ("Jordan Lee", "jordan@example.com")], link: "iii-iiii-iii",
                             host: "https://zoom.us/j/")
        let vendor = event("Vendor demo", 0, 60, [("Sam Carter", "sam@example.com"), ("Morgan Hale", "morgan@vendor.example")], link: "jjj-jjjj-jjj",
                           host: "https://zoom.us/j/")
        XCTAssertEqual(answer(.zoom, from: -0.5, to: 50, voices: ["Sam Carter", "Jordan Lee"], events: [teamSync, vendor]),
                       .picked(vendor, sure: false))
    }

    /// N2: a client call after a prep 1:1 with a colleague; the colleague is named, the clients are unknown. The pick stays.
    func testN2AClientCallAfterAPrepWithAColleagueStays() {
        let prep = event("Prep", -30, 0, [("Sam Carter", "sam@example.com")], link: "kkk-kkkk-kkk")
        let client = event("Client call", 0, 30, [("Morgan Hale", "morgan@client.example")], link: "lll-llll-lll")
        XCTAssertEqual(answer(from: 1, to: 29, voices: ["Sam Carter"], events: [prep, client], unknown: true), .picked(client, sure: true))
    }

    /// N2: an unplanned call with no pick after a 1:1 that ended: no invite, as on main.
    func testN2AnUnplannedCallAfterAOneOnOneGetsNoInvite() {
        let oneOnOne = event("1:1", -30, 0, [("Sam Carter", "sam@example.com")], link: "mmm-mmmm-mmm")
        XCTAssertEqual(answer(from: 5, to: 20, voices: ["Sam Carter"], events: [oneOnOne]), .nothing)
    }

    /// N2, the first review's I1 on a Google calendar: Google gives a group address no kind, so the guard cannot see it.
    /// The three voices of "Design sync" are all named and all invited to it, the pick has none of them: it replaces the
    /// pick. With the kind (the Mac's calendar marks a group), the pick stays.
    func testN2TheGroupCaseOnGoogleIsReplacedAndOnTheMacStays() {
        let design = event("Design sync", -30, 0, [("Sam Carter", "sam@example.com"), ("Jordan Lee", "jordan@example.com"),
                                                  ("Robin Ash", "robin@example.com")], link: "ggg-gggg-ggg")
        let voices: Set<String> = ["Sam Carter", "Jordan Lee", "Robin Ash"]
        var google = event("Sprint review", 1, 61, [], link: "hhh-hhhh-hhh")
        google.participants.append(Invitee(name: nil, email: "team@example.com"))
        XCTAssertEqual(answer(from: 2, to: 58, voices: voices, events: [design, google]), .proved(design))
        let mac = event("Sprint review", 1, 61, [], link: "hhh-hhhh-hhh", group: "team@example.com")
        XCTAssertEqual(answer(from: 2, to: 58, voices: voices, events: [design, mac]), .picked(mac, sure: true))
    }

    /// N3: "no invite" takes away only an invite whose own event is in the read and does not hold the link.
    func testN3NoInviteClearsOnlyAnInviteWhoseEventIsInTheRead() {
        var r = CallRecord(id: "x", platform: .meet, bundleID: "b", start: at(84), end: at(94), status: .written)
        r.setInvite(meetup)
        XCTAssertEqual(InviteAnswer.noInvite.held(by: r, events: morning), .noInvite, "its event is in the read")
        XCTAssertEqual(InviteAnswer.noInvite.held(by: r, events: [leadership]), .nothing, "its event is not in the read")
        XCTAssertEqual(InviteAnswer.noInvite.held(by: r, events: []), .nothing, "a blind store")
        r.clearInvite()
        XCTAssertEqual(InviteAnswer.noInvite.held(by: r, events: []), .noInvite, "nothing to keep")
        XCTAssertEqual(InviteAnswer.picked(meetup, sure: true).held(by: r, events: []), .picked(meetup, sure: true))
    }
}
