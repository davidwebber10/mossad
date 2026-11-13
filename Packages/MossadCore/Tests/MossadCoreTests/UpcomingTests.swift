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
            event("Holiday", in: 0, length: 1440, text: link, allDay: true), event("Far", in: 60 * 24 * 50, text: link), event("Soon", in: 15, text: link),
            event("Lunch", in: 30, text: "Cafe"),
        ]
        // Lunch has no call link, so it is not a call.
        XCTAssertEqual(UpcomingMeeting.from(events, now: now).map(\.title), ["Running", "Soon", "Later"])
    }

    func testTheListsShowTheWholeReadOfTheCalendar() {
        let link = "https://meet.google.com/abc-defg-hij"
        // One window for the lists, the calendar, the prep pages, and the series: 45 days, read once.
        XCTAssertEqual(UpcomingMeeting.days, 45)
        let events = [event("Next week", in: 60 * 24 * 8, text: link), event("Next month", in: 60 * 24 * 30, text: link),
                      event("Last day", in: 60 * 24 * 44.9, text: link), event("Too far", in: 60 * 24 * 46, text: link)]
        XCTAssertEqual(UpcomingMeeting.from(events, now: now, limit: .max).map(\.title), ["Next week", "Next month", "Last day"])
        // The menu bar keeps its own short count.
        let many = (1...20).map { event("Call \($0)", in: Double($0) * 60, text: link) }
        XCTAssertEqual(UpcomingMeeting.from(many, now: now).count, UpcomingMeeting.limit)
    }

    func testAPastRecordingHidesOnlyItsOwnInvite() {
        let link = "https://meet.google.com/abc-defg-hij"
        var done = CallRecord(id: "done", platform: .meet, bundleID: "", start: now.addingTimeInterval(-1200), end: now.addingTimeInterval(-60), status: .written)
        done.calendarTitle = "Weekly sync"
        var old = CallRecord(id: "old", platform: .meet, bundleID: "", start: now.addingTimeInterval(-8 * 86_400), end: now.addingTimeInterval(-8 * 86_400 + 1800), status: .written)
        old.calendarTitle = "Weekly sync"
        let events = [event("Weekly sync", in: -20, length: 30, text: link), event("Weekly sync", in: 60 * 24 * 7, text: link)]
        XCTAssertEqual(UpcomingMeeting.from(events, now: now, recorded: [done, old]).map(\.start), [events[1].start])
    }

    func testTheUpcomingListGroupsByDayLatestOnTop() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        cal.locale = Locale(identifier: "en_US")
        // `now` is Friday, January 15, 2027, 08:00 UTC.
        let link = "https://meet.google.com/abc-defg-hij"
        let hour = 60.0
        let events = [event("Today early", in: 1 * hour, text: link), event("Today late", in: 6 * hour, text: link),
                      event("Tomorrow", in: 26 * hour, text: link), event("Monday", in: 3 * 24 * hour, text: link),
                      event("Thursday", in: 6 * 24 * hour, text: link), event("Next Friday", in: 7 * 24 * hour, text: link),
                      event("February", in: 20 * 24 * hour, text: link)]
        let days = UpcomingMeeting.byDay(UpcomingMeeting.from(events, now: now, limit: .max), now: now, calendar: cal)
        XCTAssertEqual(days.map(\.title), ["Thursday, Feb 4", "Friday, Jan 22", "Thursday, Jan 21", "Monday, Jan 18", "Tomorrow", "Today"])
        // Time runs one way down the list: the latest on top, the soonest at the bottom, just above the meetings that happened.
        XCTAssertEqual(days.flatMap { $0.meetings.map(\.title) },
                       ["February", "Next Friday", "Thursday", "Monday", "Tomorrow", "Today late", "Today early"])
        // After Tomorrow the date is in the header too, so an upcoming day never reads like a past one ("Monday").
        XCTAssertEqual(days.last?.date, cal.startOfDay(for: now))
        XCTAssertTrue(UpcomingMeeting.byDay([], now: now, calendar: cal).isEmpty)
    }

    func testTheDefaultCalendarsAreTheOwnersOwn() {
        let all = [CalendarInfo(id: "1", title: "Avery Lane", account: "alane@example.com"),
                   CalendarInfo(id: "2", title: "Ecom Schedules", account: "alane@example.com"),
                   CalendarInfo(id: "3", title: "alane@example.com", account: "alane@example.com"),
                   CalendarInfo(id: "4", title: "US Holidays", account: "Other")]
        XCTAssertEqual(CalendarInfo.defaults(all, ownerName: "Avery Lane"), ["1", "3"])
        // The real layout: the account is named "Google", and the main calendar is titled with the address.
        let real = [CalendarInfo(id: "a", title: "Ecom Schedules", account: "Google"), CalendarInfo(id: "b", title: "alane@example.com", account: "Google"),
                    CalendarInfo(id: "c", title: "Personal", account: "Google"), CalendarInfo(id: "d", title: "Home", account: "assistant@example.org")]
        XCTAssertEqual(CalendarInfo.defaults(real, ownerName: "Avery Lane"), ["b"])
        XCTAssertTrue(CalendarInfo.isOwnersAddress("avery.lane@x.com", ownerName: "Avery Lane"))
        XCTAssertTrue(CalendarInfo.isOwnersAddress("averyl@x.com", ownerName: "Avery Lane"))
        XCTAssertFalse(CalendarInfo.isOwnersAddress("ecom@x.com", ownerName: "Avery Lane"))
        // With no calendar of their own, every calendar is read rather than none.
        XCTAssertEqual(CalendarInfo.defaults([all[1], all[3]], ownerName: "Avery Lane"), ["2", "4"])
    }

    func testTheWorkEmailFindsTheOwnersCalendarWhenTheNameDoesNot() {
        let list = [CalendarInfo(id: "a", title: "ops-lead@example.com", account: "Google"),
                    CalendarInfo(id: "b", title: "Team", account: "Google")]
        XCTAssertEqual(CalendarInfo.defaults(list, ownerName: "Alex Rivera"), ["a", "b"])
        XCTAssertEqual(CalendarInfo.defaults(list, ownerName: "Alex Rivera", ownerEmail: " Ops-Lead@example.com "), ["a"])
    }

    func testFindsTheCallLinkAndPlatform() throws {
        let m = try XCTUnwrap(UpcomingMeeting.from([event("Sync", in: 5, text: "Join: https://meet.google.com/abc-defg-hij?authuser=0\nNotes")], now: now).first)
        XCTAssertEqual(m.platform, .meet)
        XCTAssertEqual(m.link?.absoluteString, "https://meet.google.com/abc-defg-hij?authuser=0")
        let zoom = try XCTUnwrap(UpcomingMeeting.from([event("Z", in: 5, text: "https://us02web.zoom.us/j/123456789?pwd=x")], now: now).first)
        XCTAssertEqual(zoom.platform, .zoom)
        XCTAssertTrue(UpcomingMeeting.from([event("Lunch", in: 5, text: "Cafe")], now: now).isEmpty)
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

/// The Meetings list's window of invites: the next two work days, and the count of the rest.
final class UpcomingListWindowTests: XCTestCase {
    private func calendar(_ locale: String = "en_US") -> Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        c.locale = Locale(identifier: locale)
        return c
    }

    /// Monday, November 2, 2026, plus `day` days, at `hour`.
    private func date(_ day: Int, _ hour: Double = 9, _ c: Calendar? = nil) -> Date {
        let c = c ?? calendar()
        return c.date(from: DateComponents(year: 2026, month: 11, day: 2))!.addingTimeInterval(Double(day) * 86_400 + hour * 3600)
    }

    private func invite(_ title: String, _ start: Date, attendees: [String] = []) -> UpcomingMeeting {
        UpcomingMeeting(title: title, start: start, end: start.addingTimeInterval(1800), attendees: attendees, platform: .meet, link: nil)
    }

    func testTheWindowEndsAfterTheSecondWorkDay() {
        // From each day of a week with no holiday: the start of the day after the window.
        let cases: [(from: Int, ends: Int)] = [
            (0, 2),   // Monday: Monday and Tuesday
            (1, 3),   // Tuesday
            (2, 4),   // Wednesday
            (3, 5),   // Thursday: Thursday and Friday
            (4, 8),   // Friday: Friday and Monday
            (5, 9),   // Saturday: Monday and Tuesday
            (6, 9),   // Sunday: Monday and Tuesday
        ]
        for c in cases {
            XCTAssertEqual(UpcomingMeeting.listWindowEnd(now: date(c.from), calendar: calendar()), date(c.ends, 0), "day \(c.from)")
        }
        // Late on Friday evening, Friday still counts.
        XCTAssertEqual(UpcomingMeeting.listWindowEnd(now: date(4, 23.5), calendar: calendar()), date(8, 0))
    }

    func testAWeekendOfFridayAndSaturday() {
        let c = calendar("he_IL")
        XCTAssertTrue(c.isDateInWeekend(date(4, 9, c)))
        // Thursday: Thursday and Sunday. Friday: Sunday and Monday.
        XCTAssertEqual(UpcomingMeeting.listWindowEnd(now: date(3, 9, c), calendar: c), date(7, 0, c))
        XCTAssertEqual(UpcomingMeeting.listWindowEnd(now: date(4, 9, c), calendar: c), date(8, 0, c))
    }

    func testTheListShowsTheWindowAndCountsTheRest() {
        let c = calendar()
        let friday = date(4, 8)
        let meetings = [invite("Friday sync", date(4, 10)), invite("Saturday ops", date(5, 10)), invite("Monday standup", date(7, 9.5)),
                        invite("Tuesday review", date(8, 10)), invite("Next week", date(11, 10))]
        let part = UpcomingMeeting.listPart(meetings, now: friday, calendar: c)
        // A weekend meeting before the end of the window shows too.
        XCTAssertEqual(part.meetings.map(\.title), ["Friday sync", "Saturday ops", "Monday standup"])
        XCTAssertEqual(part.more, 2)
        XCTAssertEqual(part.after, date(8, 0))
        XCTAssertEqual(UpcomingMeeting.moreText(part.more), "2 more in the next 45 days")
        // The day groups keep their order: the latest day on top.
        XCTAssertEqual(UpcomingMeeting.byDay(part.meetings, now: friday, calendar: c).map(\.meetings.first?.title), ["Monday standup", "Saturday ops", "Friday sync"])
    }

    func testASearchFindsInvitesBeyondTheWindow() {
        let c = calendar()
        let meetings = [invite("Friday sync", date(4, 10)), invite("Budget review", date(11, 10), attendees: ["Sam Carter"]),
                        invite("Roadmap", date(20, 10))]
        let part = UpcomingMeeting.listPart(meetings, query: "budget", now: date(4, 8), calendar: c)
        XCTAssertEqual(part.meetings.map(\.title), ["Budget review"])
        XCTAssertEqual(part.more, 0)
        XCTAssertEqual(UpcomingMeeting.listPart(meetings, query: "sam", now: date(4, 8), calendar: c).meetings.map(\.title), ["Budget review"])
        XCTAssertEqual(UpcomingMeeting.listPart(meetings, query: "nothing", now: date(4, 8), calendar: c).meetings, [])
    }
}
