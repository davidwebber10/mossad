import XCTest
@testable import MossadCore

final class MeetingGroupsTests: XCTestCase {
    var calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/New_York")!
        c.firstWeekday = 2
        return c
    }()

    func at(_ day: Int, _ hour: Int) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour))!
    }

    func record(_ id: String, _ start: Date) -> CallRecord {
        CallRecord(id: id, platform: .meet, bundleID: "com.google.Chrome", start: start, end: start.addingTimeInterval(600), status: .written)
    }

    func testGroupsNewestFirstAndHidesEmptyGroups() {
        // Wednesday, October 21, 2026, 3 PM. The week starts on Monday the 19th.
        let now = at(21, 15)
        let records = [record("mon", at(19, 9)), record("today2", at(21, 11)), record("old", at(9, 10)), record("today1", at(21, 9))]
        let groups = MeetingGroups.group(records, now: now, calendar: calendar)
        XCTAssertEqual(groups.map(\.kind), [.today, .thisWeek, .earlier])
        XCTAssertEqual(groups[0].records.map(\.id), ["today2", "today1"])
        XCTAssertEqual(groups.map(\.kind.title), ["Today", "This week", "Earlier"])
    }

    func testYesterdayBeatsThisWeek() {
        let groups = MeetingGroups.group([record("y", at(20, 14))], now: at(21, 15), calendar: calendar)
        XCTAssertEqual(groups.map(\.kind), [.yesterday])
    }

    func testYesterdayInTheLastWeekIsStillYesterday() {
        // Monday the 19th: yesterday is Sunday the 18th, which is in the previous week.
        let groups = MeetingGroups.group([record("y", at(18, 14)), record("w", at(16, 9))], now: at(19, 15), calendar: calendar)
        XCTAssertEqual(groups.map(\.kind), [.yesterday, .earlier])
    }
}
