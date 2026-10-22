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
