import XCTest
@testable import MossadCore

final class UpcomingTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func event(_ title: String, in minutes: Double, length: Double = 30, text: String = "", allDay: Bool = false,
                       attendees: [String] = ["a@b.com"]) -> CalendarEventInfo {
        CalendarEventInfo(title: title, start: now.addingTimeInterval(minutes * 60), end: now.addingTimeInterval((minutes + length) * 60),
                          attendees: attendees, text: text, isAllDay: allDay)
    }

    func testShowsTimedEventsThatHaveNotEndedSoonestFirst() {
        let events = [
            event("Later", in: 120), event("Running", in: -10), event("Done", in: -60), event("Holiday", in: 0, length: 1440, allDay: true),
            event("Far", in: 60 * 24 * 9), event("Soon", in: 15),
        ]
        XCTAssertEqual(UpcomingMeeting.from(events, now: now).map(\.title), ["Running", "Soon", "Later"])
    }

    func testFindsTheCallLinkAndPlatform() throws {
        let m = try XCTUnwrap(UpcomingMeeting.from([event("Sync", in: 5, text: "Join: https://meet.google.com/abc-defg-hij?authuser=0\nNotes")], now: now).first)
        XCTAssertEqual(m.platform, .meet)
        XCTAssertEqual(m.link?.absoluteString, "https://meet.google.com/abc-defg-hij?authuser=0")
        let zoom = try XCTUnwrap(UpcomingMeeting.from([event("Z", in: 5, text: "https://us02web.zoom.us/j/123456789?pwd=x")], now: now).first)
        XCTAssertEqual(zoom.platform, .zoom)
        let none = try XCTUnwrap(UpcomingMeeting.from([event("Lunch", in: 5, text: "Cafe")], now: now).first)
        XCTAssertNil(none.platform)
        XCTAssertNil(none.link)
    }

    func testEarlierMeetingsOfTheSameSeriesNewestFirst() {
        func record(_ id: String, _ title: String, daysAgo: Double) -> CallRecord {
            var r = CallRecord(id: id, platform: .meet, bundleID: "", start: now.addingTimeInterval(-daysAgo * 86_400),
                               end: now.addingTimeInterval(-daysAgo * 86_400 + 1800), status: .written)
            r.calendarTitle = title
            return r
        }
        let records = [record("a", "Weekly Sync", daysAgo: 14), record("b", "weekly sync", daysAgo: 7), record("c", "Other", daysAgo: 1)]
        let m = UpcomingMeeting.from([event("Weekly Sync", in: 30)], now: now)[0]
        XCTAssertEqual(m.earlier(in: records).map(\.id), ["b", "a"])
    }
}
