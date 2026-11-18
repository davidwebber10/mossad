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
    // MARK: The link, the title, or neither (the morning of three wrong titles)

    func match(_ events: [CalendarEventInfo], on platform: Platform = .meet, id: String? = nil, key: String? = nil,
               from: Double, to: Double) -> (title: String, sure: Bool)? {
        CalendarMatcher.match(for: platform, meetingID: id, titleKey: key, start: t0.addingTimeInterval(from), end: t0.addingTimeInterval(to), in: events)
            .map { ($0.event.title, $0.sure) }
    }

    /// 10:00 is t0. The three events of that morning, each with a Meet link of its own.
    var morning: [CalendarEventInfo] {
        [event("Leadership sync", 0, 1800, text: "https://meet.google.com/aaa-aaaa-aaa"),
         event("Quick check", 1800, 3600, text: "https://meet.google.com/bbb-bbbb-bbb"),
         event("Team meetup", 3600, 5400, text: "https://meet.google.com/ccc-cccc-ccc")]
    }

    func testTheTitleOfTheMeetWindowFindsItsEventSurely() {
        let leadership = CallTitleWatch.key("Leadership sync")
        // Call 1: 10:01 to 11:04, the window showed the event's title.
        XCTAssertEqual(match(morning, key: leadership, from: 60, to: 3840)?.title, "Leadership sync")
        XCTAssertEqual(match(morning, key: leadership, from: 60, to: 3840)?.sure, true)
        // Call 2: 11:05 to 11:19, the late "Quick check": its event ended 5 minutes before, in the window of 10 minutes.
        let quick = match(morning, key: CallTitleWatch.key("Quick check"), from: 3900, to: 4740)
        XCTAssertEqual(quick?.title, "Quick check")
        XCTAssertEqual(quick?.sure, true)
        // An event of that title more than 10 minutes away is not the call's.
        XCTAssertEqual(match(morning, key: CallTitleWatch.key("Quick check"), from: 4300, to: 4740)?.title, "Team meetup")
        XCTAssertEqual(match(morning, key: CallTitleWatch.key("Quick check"), from: 4300, to: 4740)?.sure, true, "main's one candidate")
        // Two events of that title in the window: the one that overlaps the call; two that overlap say nothing.
        let before = morning + [event("Leadership sync", -1200, -300, text: "https://meet.google.com/ddd-dddd-ddd")]
        XCTAssertEqual(match(before, key: leadership, from: 60, to: 3840)?.title, "Leadership sync")
        XCTAssertEqual(match(before, key: leadership, from: 60, to: 3840)?.sure, true)
        let twice = morning + [event("Leadership sync", 1800, 2400, text: "https://meet.google.com/ddd-dddd-ddd")]
        XCTAssertEqual(match(twice, key: leadership, from: 60, to: 3840)?.sure, false)
        // Two spaces or another Unicode form of the same title is the same key.
        let spaced = [event("Leadership  sync", 0, 1800, text: "https://meet.google.com/aaa-aaaa-aaa")]
        XCTAssertEqual(match(spaced, key: leadership, from: 60, to: 3840)?.sure, true)
        let accent = [event("Cafe\u{301} sync", 0, 1800, text: "https://meet.google.com/aaa-aaaa-aaa")]
        XCTAssertEqual(CalendarMatcher.titleKey(of: accent[0]), CallTitleWatch.meeting(inWindowTitle: "Meet - Caf\u{e9} sync - Google Chrome").map(CallTitleWatch.key))
        // The window cuts a title at its first separator; the event's key is cut the same way.
        let cut = [event("Ops - weekly", 0, 1800, text: "https://meet.google.com/aaa-aaaa-aaa")]
        XCTAssertEqual(match(cut, key: CallTitleWatch.key("Ops"), from: 60, to: 1700)?.sure, true)
        XCTAssertEqual(CalendarMatcher.titleKey(of: cut[0]), CallTitleWatch.key("Ops"))
        // A title that is no event's: the overlap rule, not sure.
        XCTAssertEqual(match(morning, key: CallTitleWatch.key("Something else"), from: 60, to: 3840)?.sure, false)
    }

    /// With neither a link nor a title, main's rule: the largest overlap, sure when it is the only overlapping event.
    func testWithNeitherALinkNorATitleMainsRuleStays() {
        // Call 1 with no title: "Quick check" overlaps it most, and "Leadership sync" overlaps it too: not sure.
        let one = match(morning, from: 60, to: 3840)
        XCTAssertEqual(one?.title, "Quick check")
        XCTAssertEqual(one?.sure, false)
        // Call 3: 11:24 to 11:34, only "Team meetup" overlaps it: sure, as on main.
        XCTAssertEqual(match(morning, from: 5040, to: 5640)?.title, "Team meetup")
        XCTAssertEqual(match(morning, from: 5040, to: 5640)?.sure, true)
        XCTAssertEqual(match([event("Vendor call", 0, 1800, text: "https://zoom.us/j/1")], on: .zoom, from: 60, to: 1700)?.sure, true)
        // A call that runs one minute into the next event: two candidates, the larger overlap, not sure, as on main.
        let into = match(morning, from: 0, to: 1860)
        XCTAssertEqual(into?.title, "Leadership sync")
        XCTAssertEqual(into?.sure, false)
        // A room has no link to match: the one overlapping event with no call link stays sure, as before.
        XCTAssertEqual(match([event("Planning", 0, 1800)], on: .inPerson, from: 60, to: 1700)?.sure, true)
    }

    func testWithALinkOnlyAnEventThatHoldsItIsTheCalls() {
        XCTAssertNil(match(morning, id: "zzz-zzzz-zzz", from: 5040, to: 5640), "an unplanned call: no event holds its link")
        XCTAssertEqual(match(morning, id: "bbb-bbbb-bbb", key: CallTitleWatch.key("Team meetup"), from: 3900, to: 4740)?.title, "Quick check",
                       "the link wins over a title")
        XCTAssertEqual(match(morning, id: "bbb-bbbb-bbb", from: 3900, to: 4740)?.sure, false, "an event of the link that ended before the call, as before")
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
