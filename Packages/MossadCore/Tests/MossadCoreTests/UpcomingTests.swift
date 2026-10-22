import XCTest
@testable import MossadCore

final class UpcomingTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func event(_ title: String, in minutes: Double, length: Double = 30, text: String = "", allDay: Bool = false,
                       attendees: [String] = ["a@b.com"]) -> CalendarEventInfo {
        CalendarEventInfo(title: title, start: now.addingTimeInterval(minutes * 60), end: now.addingTimeInterval((minutes + length) * 60),
                          attendees: attendees, text: text, isAllDay: allDay)
    }

    func testShowsTimedCallsThatHaveNotEndedSoonestFirst() {
        let link = "https://meet.google.com/abc-defg-hij"
        let events = [
            event("Later", in: 120, text: link), event("Running", in: -10, text: link), event("Done", in: -60, text: link),
            event("Holiday", in: 0, length: 1440, text: link, allDay: true), event("Far", in: 60 * 24 * 9, text: link), event("Soon", in: 15, text: link),
            event("Lunch", in: 30, text: "Cafe"),
        ]
        // Lunch has no call link, so it is not a call.
        XCTAssertEqual(UpcomingMeeting.from(events, now: now).map(\.title), ["Running", "Soon", "Later"])
    }

    func testTheDefaultCalendarsAreTheOwnersOwn() {
        let all = [CalendarInfo(id: "1", title: "David Webber", account: "dwebber@polywood.com"),
                   CalendarInfo(id: "2", title: "Ecom Schedules", account: "dwebber@polywood.com"),
                   CalendarInfo(id: "3", title: "dwebber@polywood.com", account: "dwebber@polywood.com"),
                   CalendarInfo(id: "4", title: "US Holidays", account: "Other")]
        XCTAssertEqual(CalendarInfo.defaults(all, ownerName: "David Webber"), ["1", "3"])
        // The real layout: the account is named "Google", and the main calendar is titled with the address.
        let real = [CalendarInfo(id: "a", title: "Ecom Schedules", account: "Google"), CalendarInfo(id: "b", title: "dwebber@polywood.com", account: "Google"),
                    CalendarInfo(id: "c", title: "Personal", account: "Google"), CalendarInfo(id: "d", title: "Home", account: "webberassistant@gmail.com")]
        XCTAssertEqual(CalendarInfo.defaults(real, ownerName: "David Webber"), ["b"])
        XCTAssertTrue(CalendarInfo.isOwnersAddress("david.webber@x.com", ownerName: "David Webber"))
        XCTAssertTrue(CalendarInfo.isOwnersAddress("davidw@x.com", ownerName: "David Webber"))
        XCTAssertFalse(CalendarInfo.isOwnersAddress("ecom@x.com", ownerName: "David Webber"))
        // With no calendar of their own, every calendar is read rather than none.
        XCTAssertEqual(CalendarInfo.defaults([all[1], all[3]], ownerName: "David Webber"), ["2", "4"])
    }

    func testFindsTheCallLinkAndPlatform() throws {
        let m = try XCTUnwrap(UpcomingMeeting.from([event("Sync", in: 5, text: "Join: https://meet.google.com/abc-defg-hij?authuser=0\nNotes")], now: now).first)
        XCTAssertEqual(m.platform, .meet)
        XCTAssertEqual(m.link?.absoluteString, "https://meet.google.com/abc-defg-hij?authuser=0")
        let zoom = try XCTUnwrap(UpcomingMeeting.from([event("Z", in: 5, text: "https://us02web.zoom.us/j/123456789?pwd=x")], now: now).first)
        XCTAssertEqual(zoom.platform, .zoom)
        XCTAssertTrue(UpcomingMeeting.from([event("Lunch", in: 5, text: "Cafe")], now: now).isEmpty)
    }

    func testEarlierMeetingsOfTheSameSeriesNewestFirst() {
        func record(_ id: String, _ title: String, daysAgo: Double) -> CallRecord {
            var r = CallRecord(id: id, platform: .meet, bundleID: "", start: now.addingTimeInterval(-daysAgo * 86_400),
                               end: now.addingTimeInterval(-daysAgo * 86_400 + 1800), status: .written)
            r.calendarTitle = title
            return r
        }
        let records = [record("a", "Weekly Sync", daysAgo: 14), record("b", "weekly sync", daysAgo: 7), record("c", "Other", daysAgo: 1)]
        let m = UpcomingMeeting.from([event("Weekly Sync", in: 30, text: "https://zoom.us/j/123456789")], now: now)[0]
        XCTAssertEqual(m.earlier(in: records).map(\.id), ["b", "a"])
    }

    func testAnEventBeingRecordedOrAlreadyRecordedIsNotUpcoming() {
        let link = "https://meet.google.com/abc-defg-hij"
        var live = CallRecord(id: "live", platform: .meet, bundleID: "", start: now.addingTimeInterval(-300), end: now, status: .recording)
        live.calendarTitle = "Commercial Website Leadership TB"
        let events = [event("Commercial Website Leadership TB", in: -10, length: 60, text: link),
                      event("Crescendo Launch Sync", in: 15, text: link),
                      event("Not joined yet", in: -5, text: link)]
        XCTAssertEqual(UpcomingMeeting.from(events, now: now, recorded: [live]).map(\.title), ["Not joined yet", "Crescendo Launch Sync"])
    }
}
