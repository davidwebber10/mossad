import XCTest
@testable import MossadCore

final class CalendarMatcherTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    func event(_ title: String, _ start: Double, _ end: Double, text: String = "", allDay: Bool = false) -> CalendarEventInfo {
        CalendarEventInfo(title: title, start: t0.addingTimeInterval(start), end: t0.addingTimeInterval(end),
                          attendees: ["Alex Rivera"], text: text, isAllDay: allDay)
    }

    func best(_ platform: Platform, _ events: [CalendarEventInfo], id: String? = nil) -> String? {
        CalendarMatcher.bestEvent(for: platform, meetingID: id, start: t0.addingTimeInterval(60), end: t0.addingTimeInterval(1800), in: events)?.title
    }

    func testPicksOverlappingEventWithPlatformLink() {
        let events = [
            event("Lunch hold", 0, 3600),
            event("Weekly Ops Sync", 0, 1800, text: "Join: https://meet.google.com/abc-defg-hij"),
        ]
        XCTAssertEqual(best(.meet, events), "Weekly Ops Sync")
    }

    func testZoomAndTeamsLinks() {
        let events = [
            event("Vendor call", 0, 1800, text: "https://example.zoom.us/j/123456"),
            event("Finance review", 0, 1800, text: "https://teams.microsoft.com/l/meetup-join/xyz"),
        ]
        XCTAssertEqual(best(.zoom, events), "Vendor call")
        XCTAssertEqual(best(.teams, events), "Finance review")
    }

    func testWithoutAnIDPrefersTheLargestOverlapAmongLinkedEvents() {
        let events = [event("Short", 1500, 2000, text: "https://zoom.us/j/1"), event("Planning", 0, 1800, text: "https://zoom.us/j/2")]
        XCTAssertEqual(best(.zoom, events), "Planning")
    }

    func testAnEventWithoutAMeetingLinkNeverMatches() {
        XCTAssertNil(best(.zoom, [event("Planning", 0, 1800)]))
        XCTAssertNil(best(.meet, [event("Lunch hold", 0, 3600)], id: "abc-defg-hij"))
    }

    func testMeetingIDPicksTheEventWithThatLink() {
        let events = [
            event("Team sync", 0, 1800, text: "https://meet.google.com/xyz-wxyz-xyz"),
            event("Ad hoc", 600, 1200, text: "Join: https://meet.google.com/abc-defg-hij"),
        ]
        XCTAssertEqual(best(.meet, events, id: "abc-defg-hij"), "Ad hoc")
    }

    func testMeetingIDWithNoMatchingEventReturnsNil() {
        let events = [event("Team sync", 0, 1800, text: "https://meet.google.com/xyz-wxyz-xyz")]
        XCTAssertNil(best(.meet, events, id: "abc-defg-hij"))
    }

    func testMeetingIDMatchesAnEventThatStartsSoonAfterTheCall() {
        // Joined five minutes early: the event does not overlap yet but has the same link.
        let events = [event("Early join", 1860, 3600, text: "https://meet.google.com/abc-defg-hij")]
        XCTAssertEqual(best(.meet, events, id: "abc-defg-hij"), "Early join")
    }

    func testZoomAndTeamsMeetingIDs() {
        let events = [
            event("Vendor call", 0, 1800, text: "https://example.zoom.us/j/81234567890?pwd=abc"),
            event("Other Zoom", 0, 1800, text: "https://example.zoom.us/j/99999999999"),
            event("Finance review", 0, 1800, text: "https://teams.microsoft.com/l/meetup-join/19%3ameeting_NjQ1ZDk2%40thread.v2/0"),
            event("Other Teams", 0, 1800, text: "https://teams.microsoft.com/l/meetup-join/19%3ameeting_OTHER%40thread.v2/0"),
        ]
        XCTAssertEqual(best(.zoom, events, id: "81234567890"), "Vendor call")
        XCTAssertEqual(best(.teams, events, id: "meeting_NjQ1ZDk2"), "Finance review")
    }

    func testIgnoresAllDayAndNonOverlapping() {
        let events = [event("Out of office", -86_400, 86_400, text: "https://meet.google.com/abc-defg-hij", allDay: true),
                      event("Tomorrow", 90_000, 93_600, text: "https://meet.google.com/abc-defg-hij")]
        XCTAssertNil(best(.meet, events))
    }

    func testNoEventReturnsNil() {
        XCTAssertNil(best(.meet, []))
    }

    // A phone call: the event of its one person, never the owner's own block.
    private let me = Invitee(name: "Avery Webb", email: "avery@example.com", isSelf: true)
    private let samInvitee = Invitee(name: "Sam Carter", email: "sam@example.com")
    private let jo = Invitee(name: "Jo Fenwick", email: nil)

    private func event(_ people: [Invitee], text: String = "") -> CalendarEventInfo {
        CalendarEventInfo(title: "Call", start: t0.addingTimeInterval(-300), end: t0.addingTimeInterval(1800),
                          attendees: people.compactMap { $0.name ?? $0.email }, text: text, isAllDay: false, participants: people)
    }

    private func found(_ e: CalendarEventInfo, hint: PersonHint?, people: [Person] = []) -> Bool {
        CalendarMatcher.phoneCallEvent(start: t0, end: t0.addingTimeInterval(600), in: [e], hint: hint, people: people) != nil
    }

    func testAPhoneCallTakesOnlyAnEventWithItsOnePerson() {
        XCTAssertTrue(found(event([me, samInvitee]), hint: PersonHint(name: "Sam Carter")))
        XCTAssertTrue(found(event([me, samInvitee]), hint: PersonHint(name: "Carter, Sam")))
        XCTAssertTrue(found(event([me, samInvitee]), hint: nil))
        XCTAssertTrue(found(event([me, samInvitee, Invitee(name: "Room 4B", email: nil, kind: "room")]), hint: nil))
        XCTAssertFalse(found(event([me, samInvitee, jo]), hint: PersonHint(name: "Sam Carter")), "two others")
        XCTAssertFalse(found(event([me, samInvitee]), hint: PersonHint(name: "Jo Fenwick")), "another person than the hint")
        XCTAssertFalse(found(event([me, samInvitee]), hint: PersonHint(name: "Sam")), "a guess joins nobody")
        XCTAssertFalse(found(event([]), hint: nil), "the owner's own block, such as Lunch")
        XCTAssertFalse(found(event([me]), hint: nil))
        XCTAssertFalse(found(event([me, samInvitee], text: "https://meet.google.com/abc-defg-hij"), hint: nil), "a call with a link is another meeting")
    }

    func testAPickedPersonIsFoundByTheirAddress() {
        var p = Person(id: PersonID(rawValue: "p1"), displayName: "Sam Carter", origin: .voiceNaming, at: .distantPast)
        p.addEmail("sam@example.com", state: .verified, source: .voiceNaming, at: .distantPast)
        let hint = PersonHint(name: "Sam", personID: "p1")
        XCTAssertTrue(found(event([me, Invitee(name: nil, email: "sam@example.com")]), hint: hint, people: [p]))
        XCTAssertFalse(found(event([me, Invitee(name: nil, email: "other@example.com")]), hint: hint, people: [p]))
        XCTAssertTrue(found(event([me, Invitee(name: "Sam Carter", email: "other@example.com")]), hint: hint, people: [p]), "by the whole name")
        var merged = Person(id: PersonID(rawValue: "p0"), displayName: "Samuel Carter", origin: .voiceNaming, at: .distantPast)
        merged.mergedInto = PersonID(rawValue: "p1")
        XCTAssertTrue(found(event([me, Invitee(name: nil, email: "sam@example.com")]), hint: PersonHint(name: "Sam", personID: "p0"), people: [merged, p]),
                      "a merged id follows its person")
    }

    func testTheInPersonRuleDoesNotChange() {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let room = CalendarEventInfo(title: "Budget review", start: start.addingTimeInterval(-300), end: start.addingTimeInterval(3300),
                                     attendees: [], text: "Room 4B", isAllDay: false)
        XCTAssertEqual(CalendarMatcher.bestEvent(for: .inPerson, meetingID: nil, start: start, end: start.addingTimeInterval(1800), in: [room])?.title,
                       "Budget review")
        XCTAssertNil(CalendarMatcher.bestEvent(for: .phoneCall, meetingID: nil, start: start, end: start.addingTimeInterval(1800), in: [room]),
                     "the general rule never gives a phone call an event")
    }

    private var ownerPerson: Person {
        var p = Person(id: PersonID(rawValue: "p9"), displayName: "Avery Webb", isOwner: true, origin: .owner, at: .distantPast)
        p.addEmail("avery@example.com", state: .verified, source: .owner, at: .distantPast)
        return p
    }

    func testTheOwnerIsKnownByThePeopleStoreToo() {
        let unmarked = Invitee(name: "Avery Webb", email: "avery@example.com")
        XCTAssertTrue(found(event([unmarked, samInvitee]), hint: nil, people: [ownerPerson]), "the owner without the flag is still the owner")
        XCTAssertFalse(found(event([unmarked]), hint: nil, people: [ownerPerson]), "the owner's own block, without the flag")
    }

    func testANameOnlyHintFindsTheOneSavedPersonsAddress() {
        var p = Person(id: PersonID(rawValue: "p1"), displayName: "Sam Carter", origin: .voiceNaming, at: .distantPast)
        p.addEmail("sam@example.com", state: .verified, source: .voiceNaming, at: .distantPast)
        let onlyAddress = event([me, Invitee(name: nil, email: "sam@example.com")])
        XCTAssertTrue(found(onlyAddress, hint: PersonHint(name: "Sam Carter"), people: [p]))
        var twin = Person(id: PersonID(rawValue: "p4"), displayName: "Sam Carter", origin: .voiceNaming, at: .distantPast)
        twin.addEmail("s.carter@example.com", state: .verified, source: .voiceNaming, at: .distantPast)
        XCTAssertFalse(found(onlyAddress, hint: PersonHint(name: "Sam Carter"), people: [p, twin]), "two saved people of that name are nobody")
    }

    func testTheWholeNameIsNoMatchAtAnAddressThatIsSomeoneElses() {
        var p = Person(id: PersonID(rawValue: "p1"), displayName: "Sam Carter", origin: .voiceNaming, at: .distantPast)
        p.addEmail("sam.old@example.com", state: .rejected, source: .owner, at: .distantPast)
        var twin = Person(id: PersonID(rawValue: "p4"), displayName: "Sam Carter", origin: .voiceNaming, at: .distantPast)
        twin.addEmail("s.carter@example.com", state: .verified, source: .voiceNaming, at: .distantPast)
        let hint = PersonHint(name: "Sam Carter", personID: "p1")
        XCTAssertFalse(found(event([me, Invitee(name: "Sam Carter", email: "sam.old@example.com")]), hint: hint, people: [p, twin]), "an address p1 refused")
        XCTAssertFalse(found(event([me, Invitee(name: "Sam Carter", email: "s.carter@example.com")]), hint: hint, people: [p, twin]), "the other Sam's address")
        XCTAssertTrue(found(event([me, Invitee(name: "Sam Carter", email: "sam@elsewhere.example")]), hint: hint, people: [p, twin]))
    }

    func testTwoEventsWithDifferentPeopleAndNoHintGiveNoEvent() {
        let sam = CalendarEventInfo(title: "1:1 Sam", start: t0, end: t0.addingTimeInterval(300), attendees: [], text: "", isAllDay: false,
                                    participants: [me, samInvitee])
        let jo2 = CalendarEventInfo(title: "1:1 Jo", start: t0, end: t0.addingTimeInterval(600), attendees: [], text: "", isAllDay: false,
                                    participants: [me, Invitee(name: "Jo Fenwick", email: "jo@example.com")])
        XCTAssertNil(CalendarMatcher.phoneCallEvent(start: t0, end: t0.addingTimeInterval(600), in: [sam, jo2], hint: nil, people: []))
    }

    func testThePhoneCallTakesTheLongestOverlapOfItsPerson() {
        let short = CalendarEventInfo(title: "Short", start: t0.addingTimeInterval(500), end: t0.addingTimeInterval(900), attendees: [], text: "",
                                      isAllDay: false, participants: [me, samInvitee])
        let long = CalendarEventInfo(title: "Long", start: t0, end: t0.addingTimeInterval(600), attendees: [], text: "",
                                     isAllDay: false, participants: [me, samInvitee])
        XCTAssertEqual(CalendarMatcher.phoneCallEvent(start: t0, end: t0.addingTimeInterval(600), in: [short, long], hint: nil, people: [])?.title, "Long")
        XCTAssertEqual(CalendarMatcher.phoneCallEvent(start: t0, end: t0.addingTimeInterval(600), in: [long, short], hint: nil, people: [])?.title, "Long")
    }

    func testAnAllDayEventIsNeverAPhoneCallsEvent() {
        let day = CalendarEventInfo(title: "Offsite", start: t0.addingTimeInterval(-3600), end: t0.addingTimeInterval(80_000), attendees: [], text: "",
                                    isAllDay: true, participants: [me, samInvitee])
        XCTAssertNil(CalendarMatcher.phoneCallEvent(start: t0, end: t0.addingTimeInterval(600), in: [day], hint: nil, people: []))
    }
}

final class CalendarAccessTests: XCTestCase {
    func testANewStoreOnlyWhenAccessTurnsOnWhileRunning() {
        var access = CalendarAccess(allowedAtStart: false)
        XCTAssertFalse(access.needsNewStore(allowed: false))
        XCTAssertTrue(access.needsNewStore(allowed: true))
        XCTAssertFalse(access.needsNewStore(allowed: true), "only once")
    }

    func testNoNewStoreWhenAccessWasThereAtStart() {
        var access = CalendarAccess(allowedAtStart: true)
        XCTAssertFalse(access.needsNewStore(allowed: true))
    }

    func testAnInPersonMeetingMatchesAnOverlappingEventWithNoCallLink() {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let room = CalendarEventInfo(title: "Budget review", start: start.addingTimeInterval(-300), end: start.addingTimeInterval(3300),
                                     attendees: [], text: "Room 4B", isAllDay: false)
        let call = CalendarEventInfo(title: "Vendor call", start: start, end: start.addingTimeInterval(1800),
                                     attendees: [], text: "https://meet.google.com/abc-defg-hij", isAllDay: false)
        XCTAssertEqual(CalendarMatcher.bestEvent(for: .inPerson, meetingID: nil, start: start, end: start.addingTimeInterval(1800),
                                                 in: [call, room])?.title, "Budget review")
        XCTAssertNil(CalendarMatcher.bestEvent(for: .inPerson, meetingID: nil, start: start, end: start.addingTimeInterval(1800), in: [call]))
        XCTAssertEqual(Platform.inPerson.displayName, "In person")
    }
}
