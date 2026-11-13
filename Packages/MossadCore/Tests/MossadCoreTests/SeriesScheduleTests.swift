import XCTest
@testable import MossadCore

/// The weekdays and the time of a series, the Recurring list's day groups, and the blocks of its typical week.
final class SeriesScheduleTests: XCTestCase {
    private var utc: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        c.firstWeekday = 2
        return c
    }

    /// Monday, November 2, 2026, 00:00 UTC.
    private var monday: Date { utc.date(from: DateComponents(year: 2026, month: 11, day: 2))! }

    /// A date `weeks` weeks after the base Monday, on `weekday` (1 is Sunday) at `time` ("10:00").
    private func at(_ weeks: Int, _ weekday: Int, _ time: String = "10:00") -> Date {
        let parts = time.split(separator: ":").compactMap { Int($0) }
        let day = SeriesSchedule.mondayFirst(weekday) + weeks * 7
        return monday.addingTimeInterval(Double(day) * 86_400 + Double(parts[0] * 3600 + parts[1] * 60))
    }

    private func dates(_ weeks: ClosedRange<Int>, _ weekdays: [Int], _ time: String = "10:00") -> [Date] {
        weeks.flatMap { w in weekdays.map { at(w, $0, time) } }
    }

    private struct Case {
        let name: String
        let upcoming: [Date]
        let history: [Date]
        let weekdays: [Int]
        let minute: Int?
        let rhythm: SeriesSchedule.Repeat?
        let note: String?
    }

    // MARK: The rule

    func testTheScheduleRuleTable() {
        let monthlyByWeekday = [utc.date(from: DateComponents(year: 2026, month: 9, day: 1, hour: 15))!,   // first Tuesdays
                                utc.date(from: DateComponents(year: 2026, month: 10, day: 6, hour: 15))!,
                                utc.date(from: DateComponents(year: 2026, month: 11, day: 3, hour: 15))!]
        let monthlyByDate = [9, 10, 11].map { utc.date(from: DateComponents(year: 2026, month: $0, day: 15, hour: 9))! }
        let cases: [Case] = [
            Case(name: "weekly from the calendar", upcoming: dates(1...6, [3]), history: [], weekdays: [3], minute: 600, rhythm: .weekly, note: nil),
            Case(name: "daily on weekdays", upcoming: dates(1...6, [2, 3, 4, 5, 6], "09:30"), history: [], weekdays: [2, 3, 4, 5, 6], minute: 570,
                 rhythm: .weekly, note: "Every weekday"),
            Case(name: "every day", upcoming: dates(1...6, [1, 2, 3, 4, 5, 6, 7]), history: [], weekdays: [2, 3, 4, 5, 6, 7, 1], minute: 600,
                 rhythm: .weekly, note: "Every day"),
            Case(name: "twice a week", upcoming: dates(1...6, [2, 5]), history: [], weekdays: [2, 5], minute: 600, rhythm: .weekly, note: "Mon, Thu"),
            Case(name: "every 2 weeks", upcoming: [at(1, 4), at(3, 4), at(5, 4)], history: [], weekdays: [4], minute: 600, rhythm: .weeks(2),
                 note: "Every 2 weeks"),
            Case(name: "monthly by weekday", upcoming: [], history: monthlyByWeekday.reversed(), weekdays: [3], minute: 900, rhythm: .monthly,
                 note: "Monthly"),
            Case(name: "monthly by date", upcoming: [], history: monthlyByDate.reversed(), weekdays: [], minute: 540, rhythm: .monthly,
                 note: "Monthly"),
            Case(name: "irregular", upcoming: [], history: [at(-1, 2), at(-2, 4), at(-3, 6), at(-4, 3), at(-5, 5)], weekdays: [], minute: 600,
                 rhythm: .days(5), note: "About every 5 days"),
            Case(name: "history only, one move", upcoming: [], history: dates(-6 ... -1, [3]).reversed() + [at(-7, 5)], weekdays: [3], minute: 600,
                 rhythm: .weekly, note: nil),
            Case(name: "the calendar over the history", upcoming: dates(1...3, [5]), history: dates(-6 ... -1, [3]).reversed(), weekdays: [5],
                 minute: 600, rhythm: .weekly, note: nil),
            Case(name: "a tie of weekdays", upcoming: [], history: [at(-1, 2), at(-2, 5), at(-3, 2), at(-4, 5)], weekdays: [], minute: 600,
                 rhythm: .days(4), note: "About every 4 days"),
            Case(name: "a tie of times", upcoming: [at(1, 3, "10:00"), at(2, 3, "14:00"), at(3, 3, "10:00"), at(4, 3, "14:00")], history: [],
                 weekdays: [3], minute: nil, rhythm: .weekly, note: nil),
            Case(name: "one date", upcoming: [at(1, 3)], history: [], weekdays: [], minute: 600, rhythm: nil, note: nil),
            Case(name: "nothing", upcoming: [], history: [], weekdays: [], minute: nil, rhythm: nil, note: nil),
        ]
        for c in cases {
            let s = SeriesSchedule.from(upcoming: c.upcoming, history: c.history, calendar: utc)
            XCTAssertEqual(s.weekdays, c.weekdays, c.name)
            XCTAssertEqual(s.minuteOfDay, c.minute, c.name)
            XCTAssertEqual(s.rhythm, c.rhythm, c.name)
            XCTAssertEqual(s.note, c.note, c.name)
        }
    }

    func testTheTimeIsToFiveMinutes() {
        let s = SeriesSchedule.from(upcoming: [], history: [at(-1, 3, "10:02"), at(-2, 3, "09:58"), at(-3, 3, "10:01")], calendar: utc)
        XCTAssertEqual(s.minuteOfDay, 600)
    }

    func testOneUpcomingMeetingReadsWithTheHistory() {
        // A monthly series: one meeting in the calendar's read, the rest in the history.
        let next = utc.date(from: DateComponents(year: 2026, month: 12, day: 1, hour: 15))!
        let past = [11, 10, 9].map { m in utc.date(from: DateComponents(year: 2026, month: m, day: [9: 1, 10: 6, 11: 3][m]!, hour: 15))! }
        let s = SeriesSchedule.from(upcoming: [next], history: past, calendar: utc)
        XCTAssertEqual(s.weekdays, [3])
        XCTAssertEqual(s.rhythm, .monthly)
    }

    func testDailyHistoryReadsWeeksNotMeetings() {
        // Eight meetings of a daily series span two weeks; the rule reads the weeks, so each weekday is there.
        let s = SeriesSchedule.from(upcoming: [], history: dates(-8 ... -1, [2, 3, 4, 5, 6]).reversed(), calendar: utc)
        XCTAssertEqual(s.weekdays, [2, 3, 4, 5, 6])
    }

    func testTheSeriesUsesPlannedStarts() {
        var series = MeetingSeries(id: "s", keys: ["s"], title: "Sync", meetings: [], upcoming: [], cadence: nil, recurringInCalendar: false,
                                   usualPeople: [])
        series.meetings = (1...4).map { w in
            MeetingSeries.Occurrence(id: "m\(w)", title: "Sync", start: at(-w, 3, "10:07"), end: at(-w, 3, "10:30"), notesOnly: false,
                                     plannedStart: at(-w, 3, "10:00"))
        }
        let s = SeriesSchedule.of(series, calendar: utc)
        XCTAssertEqual(s.weekdays, [3])
        XCTAssertEqual(s.minuteOfDay, 600)
    }

    // MARK: The groups

    private func entry(_ id: String, _ weekdays: [Int], _ minute: Int?, title: String? = nil, next: Date? = nil, last: Date? = nil,
                       minutes: Int? = nil) -> SeriesWeek.Entry {
        SeriesWeek.Entry(id: id, title: title ?? id, schedule: SeriesSchedule(weekdays: weekdays, minuteOfDay: minute, rhythm: .weekly),
                         next: next, last: last, minutes: minutes)
    }

    func testTheGroupsRunMondayToSundayThenNoFixedDay() {
        let days = SeriesWeek.days([
            entry("sun", [1], 600), entry("fri", [6], 600), entry("loose", [], nil), entry("mon", [2], 600), entry("sat", [7], 600),
        ])
        XCTAssertEqual(days.map(\.weekday), [2, 6, 7, 1, nil])
        XCTAssertEqual(days.map(\.title), ["Monday", "Friday", "Saturday", "Sunday", "No fixed day"])
    }

    func testADayIsByTimeThenTitleAndUnknownTimeLast() {
        let days = SeriesWeek.days([
            entry("c", [3], nil, title: "Alpha"), entry("b", [3], 600, title: "Zulu"), entry("a", [3], 600, title: "Beta"),
            entry("d", [3], 540, title: "Yankee"),
        ])
        XCTAssertEqual(days.first?.ids, ["d", "a", "b", "c"])
    }

    func testADailySeriesIsInEachOfItsDays() {
        let days = SeriesWeek.days([entry("standup", [2, 3, 4, 5, 6], 570), entry("tb", [3], 600)])
        XCTAssertEqual(days.map(\.weekday), [2, 3, 4, 5, 6])
        XCTAssertEqual(days[1].ids, ["standup", "tb"])
    }

    func testNoFixedDayIsByNextThenLast() {
        let days = SeriesWeek.days([
            entry("old", [], nil, last: at(-9, 2)), entry("soon", [], nil, next: at(1, 2)), entry("later", [], nil, next: at(3, 2)),
            entry("recent", [], nil, last: at(-1, 2)),
        ])
        XCTAssertEqual(days.last?.ids, ["soon", "later", "recent", "old"])
    }

    func testNoSeriesNoGroups() {
        XCTAssertEqual(SeriesWeek.days([]), [])
    }

    // MARK: The typical week

    func testTheColumnsAreTheWorkweekAndAWeekendDayInUse() {
        XCTAssertEqual(SeriesWeek.columns([entry("a", [3], 600)]), [2, 3, 4, 5, 6])
        XCTAssertEqual(SeriesWeek.columns([entry("a", [1], 600)]), [2, 3, 4, 5, 6, 1])
        XCTAssertEqual(SeriesWeek.columns([]), [2, 3, 4, 5, 6])
    }

    func testOverlappingBlocksSitSideBySide() {
        let blocks = SeriesWeek.blocks([
            entry("a", [3], 600, minutes: 60), entry("b", [3], 630, minutes: 30), entry("c", [3], 660, minutes: 30), entry("d", [3], 720, minutes: 30),
        ])
        let byID = Dictionary(uniqueKeysWithValues: blocks.map { ($0.id, $0) })
        XCTAssertEqual(byID["a"]?.column, 0)
        XCTAssertEqual(byID["b"]?.column, 1)
        XCTAssertEqual(byID["a"]?.columns, 2)
        XCTAssertEqual(byID["b"]?.columns, 2)
        // c starts as a and b end: a group of its own, at full width.
        XCTAssertEqual(byID["c"]?.column, 0)
        XCTAssertEqual(byID["c"]?.columns, 1)
        XCTAssertEqual(byID["d"]?.columns, 1)
    }

    func testABlockOfUnknownLengthStillShows() {
        let blocks = SeriesWeek.blocks([entry("a", [2, 4], 600)])
        XCTAssertEqual(blocks.map(\.weekday), [2, 4])
        XCTAssertEqual(blocks.first?.end, 600 + SeriesWeek.unknownMinutes)
    }

    func testABlockEndsAtMidnight() {
        XCTAssertEqual(SeriesWeek.blocks([entry("late", [2], 23 * 60 + 30, minutes: 90)]).first?.end, 24 * 60)
    }

    func testTheGridLeavesOutWhatItCannotPlace() {
        let entries = [entry("placed", [3], 600), entry("no time", [3], nil), entry("loose", [], 600)]
        XCTAssertEqual(SeriesWeek.blocks(entries).map(\.id), ["placed"])
        XCTAssertEqual(Set(SeriesWeek.unplaced(entries).map(\.id)), ["no time", "loose"])
    }

    func testCalendarLayoutStillPacksCalls() {
        let a = CallRecord(id: "a", platform: .meet, bundleID: "", start: at(0, 2, "10:00"), end: at(0, 2, "11:00"), status: .written)
        let b = CallRecord(id: "b", platform: .meet, bundleID: "", start: at(0, 2, "10:30"), end: at(0, 2, "11:30"), status: .written)
        let items = CalendarLayout.day([b, a], on: at(0, 2), calendar: utc)
        XCTAssertEqual(items.map(\.id), ["a", "b"])
        XCTAssertEqual(items.map(\.column), [0, 1])
        XCTAssertEqual(items.map(\.columns), [2, 2])
    }

    // MARK: This week

    private func series(upcoming: [Date], meetings: [Date] = []) -> MeetingSeries {
        MeetingSeries(id: "s", keys: ["s"], title: "Sync",
                      meetings: meetings.map { .init(id: "\($0)", title: "Sync", start: $0, end: $0.addingTimeInterval(1800), notesOnly: false) },
                      upcoming: upcoming.map { UpcomingMeeting(title: "Sync", start: $0, end: $0.addingTimeInterval(1800), attendees: [], platform: .meet,
                                                              link: nil, seriesID: "x", isRecurring: true) },
                      cadence: nil, recurringInCalendar: true, usualPeople: [])
    }

    func testThisWeekIsKnownOnlyFromTheCalendar() {
        let thursday = SeriesSchedule(weekdays: [5], minuteOfDay: 600, rhythm: .weeks(2))
        let mondayMorning = at(0, 2, "08:00")
        XCTAssertEqual(SeriesWeek.meetsThisWeek(series(upcoming: [at(0, 5)]), schedule: thursday, now: mondayMorning, calendar: utc), true)
        XCTAssertEqual(SeriesWeek.meetsThisWeek(series(upcoming: [at(1, 5)]), schedule: thursday, now: mondayMorning, calendar: utc), false)
        // Friday: Thursday has passed, and nothing recorded says whether it met.
        XCTAssertNil(SeriesWeek.meetsThisWeek(series(upcoming: [at(1, 5)]), schedule: thursday, now: at(0, 6), calendar: utc))
        XCTAssertNil(SeriesWeek.meetsThisWeek(series(upcoming: []), schedule: thursday, now: mondayMorning, calendar: utc))
    }
}
