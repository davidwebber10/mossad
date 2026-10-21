import XCTest
@testable import MossadCore

final class CalendarLayoutTests: XCTestCase {
    var cal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/New_York")!
        return c
    }()

    func date(_ mo: Int, _ d: Int, _ h: Int, _ mi: Int = 0) -> Date {
        cal.date(from: DateComponents(year: 2026, month: mo, day: d, hour: h, minute: mi))!
    }

    func call(_ id: String, _ start: Date, _ end: Date) -> CallRecord {
        CallRecord(id: id, platform: .zoom, bundleID: "us.zoom.xos", start: start, end: end, status: .written)
    }

    func testSeparateCallsTakeOneColumn() {
        let items = CalendarLayout.day([call("b", date(10, 20, 11), date(10, 20, 12)), call("a", date(10, 20, 9), date(10, 20, 10))],
                                       on: date(10, 20, 15), calendar: cal)
        XCTAssertEqual(items, [
            CalendarItem(id: "a", start: date(10, 20, 9), end: date(10, 20, 10), column: 0, columns: 1),
            CalendarItem(id: "b", start: date(10, 20, 11), end: date(10, 20, 12), column: 0, columns: 1),
        ])
    }

    func testOverlapsShareColumnsGreedily() {
        let items = CalendarLayout.day([
            call("a", date(10, 20, 9), date(10, 20, 11)),
            call("b", date(10, 20, 9, 30), date(10, 20, 10)),
            call("c", date(10, 20, 10), date(10, 20, 10, 30)),
            call("d", date(10, 20, 10, 15), date(10, 20, 10, 45)),
            call("e", date(10, 20, 13), date(10, 20, 14)),
        ], on: date(10, 20, 0), calendar: cal)
        let layout = Dictionary(uniqueKeysWithValues: items.map { ($0.id, [$0.column, $0.columns]) })
        XCTAssertEqual(layout, ["a": [0, 3], "b": [1, 3], "c": [1, 3], "d": [2, 3], "e": [0, 1]])
        XCTAssertEqual(items.map(\.id), ["a", "b", "c", "d", "e"])
    }

    func testCallAcrossMidnightIsClippedToEachDay() {
        let r = call("x", date(10, 20, 23, 30), date(10, 21, 0, 30))
        XCTAssertEqual(CalendarLayout.day([r], on: date(10, 20, 12), calendar: cal).map { [$0.start, $0.end] },
                       [[date(10, 20, 23, 30), date(10, 21, 0)]])
        XCTAssertEqual(CalendarLayout.day([r], on: date(10, 21, 12), calendar: cal).map { [$0.start, $0.end] },
                       [[date(10, 21, 0), date(10, 21, 0, 30)]])
    }

    func testCallsOutsideTheDayAreExcluded() {
        let items = CalendarLayout.day([
            call("before", date(10, 19, 9), date(10, 20, 0)),
            call("after", date(10, 21, 0), date(10, 21, 1)),
        ], on: date(10, 20, 12), calendar: cal)
        XCTAssertEqual(items, [])
    }

    func testDaylightSavingDays() {
        // March 8 has 23 hours and November 1 has 25.
        let spring = CalendarLayout.day([call("s", date(3, 8, 1, 30), date(3, 8, 3, 30)), call("late", date(3, 8, 23, 30), date(3, 9, 0, 30))],
                                        on: date(3, 8, 12), calendar: cal)
        XCTAssertEqual(spring.map(\.id), ["s", "late"])
        XCTAssertEqual(spring.last?.end, date(3, 9, 0))
        let fall = CalendarLayout.day([call("f", date(11, 1, 23), date(11, 2, 1))], on: date(11, 1, 12), calendar: cal)
        XCTAssertEqual(fall.first?.end, date(11, 2, 0))
        XCTAssertEqual(fall.first.map { $0.end.timeIntervalSince(cal.startOfDay(for: date(11, 1, 12))) }, 25 * 3600)
    }

    func testMonthCellsStartOnTheFirstWeekday() {
        var sunday = cal
        sunday.firstWeekday = 1
        let cells = CalendarLayout.monthCells(month: date(10, 21, 15), calendar: sunday)
        XCTAssertEqual(cells.count, 42)
        // October 1, 2026 is a Thursday.
        XCTAssertEqual(cells.first, date(9, 27, 0))
        XCTAssertEqual(cells[4], date(10, 1, 0))
        XCTAssertEqual(cells.last, date(11, 7, 0))

        var monday = cal
        monday.firstWeekday = 2
        XCTAssertEqual(CalendarLayout.monthCells(month: date(10, 21, 15), calendar: monday).first, date(9, 28, 0))
    }

    func testMonthCellsAcrossDaylightSavingStayAtMidnight() {
        var c = cal
        c.firstWeekday = 1
        let cells = CalendarLayout.monthCells(month: date(3, 15, 12), calendar: c)
        XCTAssertTrue(cells.allSatisfy { c.dateComponents([.hour, .minute], from: $0) == DateComponents(hour: 0, minute: 0) })
        XCTAssertEqual(Set(cells).count, 42)
    }
}
