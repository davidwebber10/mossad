import XCTest
@testable import MossadCore

final class CalendarMatcherTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    func event(_ title: String, _ start: Double, _ end: Double, text: String = "", allDay: Bool = false) -> CalendarEventInfo {
        CalendarEventInfo(title: title, start: t0.addingTimeInterval(start), end: t0.addingTimeInterval(end),
                          attendees: ["Alex Rivera"], text: text, isAllDay: allDay)
    }

    func best(_ platform: Platform, _ events: [CalendarEventInfo]) -> String? {
        CalendarMatcher.bestEvent(for: platform, start: t0.addingTimeInterval(60), end: t0.addingTimeInterval(1800), in: events)?.title
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
            event("Vendor call", 0, 1800, text: "https://polywood.zoom.us/j/123456"),
            event("Finance review", 0, 1800, text: "https://teams.microsoft.com/l/meetup-join/xyz"),
        ]
        XCTAssertEqual(best(.zoom, events), "Vendor call")
        XCTAssertEqual(best(.teams, events), "Finance review")
    }

    func testFallsBackToLargestOverlap() {
        let events = [event("Short", 1500, 2000), event("Planning", 0, 1800)]
        XCTAssertEqual(best(.zoom, events), "Planning")
    }

    func testIgnoresAllDayAndNonOverlapping() {
        let events = [event("Out of office", -86_400, 86_400, allDay: true), event("Tomorrow", 90_000, 93_600)]
        XCTAssertNil(best(.meet, events))
    }

    func testNoEventReturnsNil() {
        XCTAssertNil(best(.meet, []))
    }
}
