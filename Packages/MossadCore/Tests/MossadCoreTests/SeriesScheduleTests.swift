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
    /// "Now" for the rule: that Monday at 08:00.
    private var base: Date { monday.addingTimeInterval(8 * 3600) }

    private func schedule(_ upcoming: [Date], _ history: [Date], now: Date? = nil) -> SeriesSchedule {
        SeriesSchedule.from(upcoming: upcoming, history: history, now: now ?? base, calendar: utc)
    }

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
            let s = SeriesSchedule.from(upcoming: c.upcoming, history: c.history, now: base, calendar: utc)
            XCTAssertEqual(s.weekdays, c.weekdays, c.name)
            XCTAssertEqual(s.minuteOfDay, c.minute, c.name)
            XCTAssertEqual(s.rhythm, c.rhythm, c.name)
            XCTAssertEqual(s.note, c.note, c.name)
        }
    }

    func testTheTimeIsToFiveMinutes() {
        let s = schedule([], [at(-1, 3, "10:02"), at(-2, 3, "09:58"), at(-3, 3, "10:01")])
        XCTAssertEqual(s.minuteOfDay, 600)
    }

    func testOneUpcomingMeetingReadsWithTheHistory() {
        // A monthly series: one meeting in the calendar's read, the rest in the history.
        let next = utc.date(from: DateComponents(year: 2026, month: 12, day: 1, hour: 15))!
        let past = [11, 10, 9].map { m in utc.date(from: DateComponents(year: 2026, month: m, day: [9: 1, 10: 6, 11: 3][m]!, hour: 15))! }
        let s = schedule([next], past)
        XCTAssertEqual(s.weekdays, [3])
        XCTAssertEqual(s.rhythm, .monthly)
    }

    func testDailyHistoryReadsWeeksNotMeetings() {
        // Eight meetings of a daily series span two weeks; the rule reads the weeks, so each weekday is there.
        let s = schedule([], dates(-8 ... -1, [2, 3, 4, 5, 6]).reversed())
        XCTAssertEqual(s.weekdays, [2, 3, 4, 5, 6])
    }

    func testTheSeriesUsesPlannedStarts() {
        var series = MeetingSeries(id: "s", keys: ["s"], title: "Sync", meetings: [], upcoming: [], cadence: nil, recurringInCalendar: false,
                                   usualPeople: [])
        series.meetings = (1...4).map { w in
            MeetingSeries.Occurrence(id: "m\(w)", title: "Sync", start: at(-w, 3, "10:07"), end: at(-w, 3, "10:30"), notesOnly: false,
                                     plannedStart: at(-w, 3, "10:00"))
        }
        let s = SeriesSchedule.of(series, now: base, calendar: utc)
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

    // MARK: The review's cases

    // M3: each weekday has its own time.
    func testEachWeekdayHasItsOwnTime() {
        let standup = schedule(dates(1...6, [2, 3, 4, 5], "09:30") + dates(1...6, [6], "09:00"), [])
        XCTAssertEqual(standup.minute(on: 5), 570)
        XCTAssertEqual(standup.minute(on: 6), 540)
        let split = schedule(dates(1...6, [2], "10:00") + dates(1...6, [5], "14:00"), [])
        XCTAssertNil(split.minuteOfDay)
        XCTAssertEqual(split.times, [2: 600, 5: 840])
        XCTAssertEqual(split.text(), "Every Mon, Thu")
        let blocks = SeriesWeek.blocks([SeriesWeek.Entry(id: "s", title: "S", schedule: split, minutes: 30)])
        XCTAssertEqual(blocks.map(\.start), [600, 840])
        XCTAssertTrue(SeriesWeek.unplaced([SeriesWeek.Entry(id: "s", title: "S", schedule: split)]).isEmpty)
    }

    // M4: with no calendar dates, the newest three meetings on one weekday move the series there at once.
    func testASeriesThatMovedItsDayIsUnderTheNewDay() {
        let moved = schedule([], [at(-1, 5, "11:00"), at(-2, 5, "11:00"), at(-3, 5, "11:00")] + dates(-9 ... -4, [3]))
        XCTAssertEqual(moved.weekdays, [5])
        XCTAssertEqual(moved.minute(on: 5), 660)
        let even = schedule([], [at(-1, 5), at(-2, 5), at(-3, 5), at(-4, 5)] + dates(-8 ... -5, [3]))
        XCTAssertEqual(even.weekdays, [5])
        // Two meetings since the move are not enough: the old day still has the majority.
        XCTAssertEqual(schedule([], [at(-1, 5), at(-2, 5)] + dates(-8 ... -3, [3])).weekdays, [3])
    }

    // M5: a series with no next meeting and none recently has ended.
    func testASeriesThatEndedHasNoDay() {
        let old = schedule([], dates(-30 ... -24, [3]))
        XCTAssertTrue(old.ended)
        XCTAssertEqual(old.weekdays, [])
        XCTAssertEqual(old.note, "Not recently")
        let entry = SeriesWeek.Entry(id: "old", title: "Old", schedule: old, last: at(-24, 3))
        XCTAssertTrue(SeriesWeek.blocks([entry]).isEmpty)
        XCTAssertTrue(SeriesWeek.unplaced([entry]).isEmpty)
        XCTAssertEqual(SeriesWeek.days([entry]).map(\.weekday), [nil])
        // A slow series keeps its day for two of its own gaps.
        let monthly = [9, 8, 7].map { m in utc.date(from: DateComponents(year: 2026, month: m, day: 1, hour: 15))! }
        XCTAssertFalse(schedule([], monthly, now: utc.date(from: DateComponents(year: 2026, month: 10, day: 20))!).ended)
        XCTAssertTrue(schedule([], monthly, now: utc.date(from: DateComponents(year: 2027, month: 1, day: 20))!).ended)
        // A next meeting in the calendar is never ended.
        XCTAssertFalse(schedule([at(1, 3)], dates(-30 ... -24, [3])).ended)
    }

    // L1: the same date each month on different weekdays has no fixed day.
    func testMonthlyByDateWithTwoWeekdaysTheSame() {
        let dates = [2, 3, 4].map { m in utc.date(from: DateComponents(year: 2027, month: m, day: 15, hour: 9))! }
        let s = schedule([], dates.reversed(), now: dates[2])
        XCTAssertEqual(s.weekdays, [])
        XCTAssertEqual(s.rhythm, .monthly)
        XCTAssertEqual(s.minuteOfDay, 540)
    }

    // L2: one week of meetings is no habit.
    func testOneWeekOfMeetingsHasNoFixedDay() {
        let s = schedule([], [at(-1, 2), at(-1, 4), at(-1, 6)])
        XCTAssertEqual(s.weekdays, [])
        XCTAssertNil(s.note)
    }

    // L8: 23:58 is 23:55, never midnight.
    func testALateStartStaysInItsDay() {
        XCTAssertEqual(schedule(dates(1...4, [3], "23:58"), []).minute(on: 3), 23 * 60 + 55)
    }

    // L12: starts a minute or two either side of the hour still give the hour.
    func testRecordedStartsAroundTheHourGiveTheHour() {
        let starts = ["10:01", "10:03", "09:59", "10:04", "10:00", "10:03"].enumerated().map { at(-($0.offset + 1), 3, $0.element) }
        XCTAssertEqual(schedule([], starts).minute(on: 3), 600)
    }

    func testThePagesLine() {
        XCTAssertEqual(SeriesSchedule(weekdays: [3], minuteOfDay: 600, rhythm: .weekly).text(), "Every Tuesday 10:00")
        XCTAssertEqual(SeriesSchedule(weekdays: [2, 3, 4, 5, 6], minuteOfDay: 570, rhythm: .weekly).text(), "Every weekday 9:30")
        XCTAssertEqual(SeriesSchedule(weekdays: [5], minuteOfDay: 660, rhythm: .weeks(2)).text(), "Every 2 weeks on Thursday 11:00")
        XCTAssertEqual(SeriesSchedule(weekdays: [], minuteOfDay: 540, rhythm: .monthly).text(), "Monthly 9:00")
        XCTAssertEqual(SeriesSchedule(weekdays: [], minuteOfDay: nil, rhythm: .days(10)).text(), "About every 10 days")
        XCTAssertNil(SeriesSchedule.none.text())
    }

    // M2: a row under a weekday says that weekday's own next date, only when the header does not.
    func testTheNextWordOfARow() {
        let now = at(0, 2, "08:00")  // Monday
        let standup = dates(0...2, [2, 3, 4, 5, 6], "09:30")
        XCTAssertEqual(SeriesWeek.next(on: 2, upcoming: standup, now: now, calendar: utc), .today)
        XCTAssertEqual(SeriesWeek.next(on: 3, upcoming: standup, now: now, calendar: utc), .tomorrow)
        XCTAssertNil(SeriesWeek.next(on: 4, upcoming: standup, now: now, calendar: utc))
        // Every 2 weeks, off this week: the date says when.
        let roadmap = [at(1, 5, "11:00"), at(3, 5, "11:00")]
        XCTAssertEqual(SeriesWeek.next(on: 5, upcoming: roadmap, now: now, calendar: utc), .date(at(1, 5, "11:00")))
        XCTAssertNil(SeriesWeek.next(on: 3, upcoming: roadmap, now: now, calendar: utc))
    }

    // L3: the arrow keys go row by row from the row they left.
    func testTheArrowKeysGoRowByRow() {
        let days = SeriesWeek.days([entry("standup", [2, 3], 570), entry("tb", [3], 600)])
        let rows = SeriesWeek.rows(days)
        XCTAssertEqual(rows.map(\.id), ["standup", "standup", "tb"])
        let second = SeriesWeek.move(rows, cursor: rows[0], selection: "standup", by: 1)
        XCTAssertEqual(second, rows[1])
        XCTAssertEqual(SeriesWeek.move(rows, cursor: second, selection: "standup", by: 1), rows[2])
        // A selection from elsewhere starts at its first row.
        XCTAssertEqual(SeriesWeek.move(rows, cursor: rows[2], selection: "standup", by: 1), rows[1])
        XCTAssertEqual(SeriesWeek.move(rows, cursor: nil, selection: nil, by: 1), rows[0])
        XCTAssertNil(SeriesWeek.move([], cursor: nil, selection: nil, by: 1))
    }

    // L6: a short block is packed as tall as it is drawn.
    func testAShortBlockDoesNotCoverTheNext() {
        let blocks = SeriesWeek.blocks([entry("a", [2], 570, minutes: 8), entry("b", [2], 585, minutes: 30)])
        XCTAssertEqual(blocks.map(\.columns), [2, 2])
        XCTAssertEqual(blocks.first?.end, 578)
    }

    // L7: the invite's length before the recorded median.
    func testTheInvitesLengthComesFirst() {
        var s = series(upcoming: [at(1, 3)])
        s.schedule = SeriesSchedule(weekdays: [3], minuteOfDay: 600, rhythm: .weekly)
        XCTAssertEqual(SeriesWeek.Entry(s, seconds: 68 * 60, now: base, calendar: utc).minutes, 30)
        XCTAssertEqual(SeriesWeek.Entry(series(upcoming: []), seconds: 68 * 60, now: base, calendar: utc).minutes, 68)
    }

    // MARK: This week

    private func series(upcoming: [Date], meetings: [Date] = []) -> MeetingSeries {
        MeetingSeries(id: "s", keys: ["s"], title: "Sync",
                      meetings: meetings.map { .init(id: "\($0)", title: "Sync", start: $0, end: $0.addingTimeInterval(1800), notesOnly: false) },
                      upcoming: upcoming.map { UpcomingMeeting(title: "Sync", start: $0, end: $0.addingTimeInterval(1800), attendees: [], platform: .meet,
                                                              link: nil, seriesID: "x", isRecurring: true) },
                      cadence: nil, recurringInCalendar: true, usualPeople: [])
    }

    // L10: each weekday still to come this week, Monday to Sunday, with no date in the calendar.
    func testTheWeekdaysSkippedThisWeek() {
        let monThu = SeriesSchedule(weekdays: [2, 5], minuteOfDay: 600, rhythm: .weekly)
        let monday = at(0, 2, "08:00")
        // Monday is today (never marked); Thursday has no date this week.
        XCTAssertEqual(SeriesWeek.skipped(monThu, upcoming: [at(0, 2, "10:00"), at(1, 2), at(1, 5)], now: monday, calendar: utc), [5])
        XCTAssertEqual(SeriesWeek.skipped(monThu, upcoming: [at(0, 5), at(1, 2)], now: monday, calendar: utc), [])
        // Friday: Thursday has passed.
        XCTAssertEqual(SeriesWeek.skipped(monThu, upcoming: [at(1, 2)], now: at(0, 6), calendar: utc), [])
        XCTAssertEqual(SeriesWeek.skipped(monThu, upcoming: [], now: monday, calendar: utc), [])
        // A calendar whose week starts on Sunday: the grid's week still runs Monday to Sunday, so on Saturday the
        // Sunday is still to come, and on Sunday everything has come.
        var sunday = utc
        sunday.firstWeekday = 1
        let sun = SeriesSchedule(weekdays: [1, 3], minuteOfDay: 600, rhythm: .weekly)
        XCTAssertEqual(SeriesWeek.skipped(sun, upcoming: [at(1, 3)], now: at(0, 7, "08:00"), calendar: sunday), [1])
        XCTAssertEqual(SeriesWeek.skipped(sun, upcoming: [at(1, 3)], now: at(0, 1, "08:00"), calendar: sunday), [])
    }

    // MARK: Daylight time

    private var newYork: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/New_York")!
        return c
    }

    /// Each Tuesday from `from` for `weeks` weeks at `hour`:00 on the New York clock.
    private func tuesdays(_ from: DateComponents, weeks: Int, hour: Int = 15) -> [Date] {
        let first = newYork.date(from: from)!
        return (0..<weeks).map { w in
            let day = newYork.date(byAdding: .day, value: 7 * w, to: first)!
            return newYork.date(bySettingHour: hour, minute: 0, second: 0, of: day)!
        }
    }

    private func assertWeeklyTuesdayAt3(_ s: SeriesSchedule, _ name: String) {
        XCTAssertEqual(s.weekdays, [3], name)
        XCTAssertEqual(s.minute(on: 3), 15 * 60, name)
        XCTAssertEqual(s.rhythm, .weekly, name)
        XCTAssertEqual(SeriesFilter.Cadence(s)?.option, "Weekly", name)
        XCTAssertEqual(s.text(), "Every Tuesday 15:00", name)
    }

    func testAWeeklySeriesKeepsItsLocalTimeAcrossTheAutumnChange() {
        // Tuesdays from October 6 to November 24, 2026: the clocks went back on November 1.
        let history = tuesdays(DateComponents(year: 2026, month: 10, day: 6), weeks: 8)
        let now = newYork.date(from: DateComponents(year: 2026, month: 11, day: 25, hour: 9))!
        assertWeeklyTuesdayAt3(SeriesSchedule.from(upcoming: [], history: history, now: now, calendar: newYork), "history, autumn")
    }

    func testAWeeklySeriesKeepsItsLocalTimeAcrossTheSpringChange() {
        // Tuesdays from February 16 to March 30, 2027: the clocks went forward on March 14.
        let history = tuesdays(DateComponents(year: 2027, month: 2, day: 16), weeks: 7)
        let now = newYork.date(from: DateComponents(year: 2027, month: 3, day: 31, hour: 9))!
        assertWeeklyTuesdayAt3(SeriesSchedule.from(upcoming: [], history: history, now: now, calendar: newYork), "history, spring")
    }

    func testTheCalendarsDatesKeepTheirLocalTimeAcrossAChange() {
        let now = newYork.date(from: DateComponents(year: 2026, month: 10, day: 19, hour: 9))!
        let autumn = tuesdays(DateComponents(year: 2026, month: 10, day: 20), weeks: 6)
        assertWeeklyTuesdayAt3(SeriesSchedule.from(upcoming: autumn, history: [], now: now, calendar: newYork), "calendar, autumn")
        let springNow = newYork.date(from: DateComponents(year: 2027, month: 3, day: 1, hour: 9))!
        let spring = tuesdays(DateComponents(year: 2027, month: 3, day: 2), weeks: 6)
        assertWeeklyTuesdayAt3(SeriesSchedule.from(upcoming: spring, history: [], now: springNow, calendar: newYork), "calendar, spring")
    }

    /// An organizer whose clock does not change (20:00 UTC) meets at 16:00 in New York before November 1 and at
    /// 15:00 after it: the series' time is its next meeting's, not a median of the two.
    func testAnOrganizerInAZoneWithNoChangeShowsTheNextMeetingsTime() {
        var utcTuesdays: [Date] {
            (0..<8).map { w in utc.date(from: DateComponents(year: 2026, month: 9, day: 29 + 7 * w, hour: 20))! }
        }
        let all = utcTuesdays
        let before = all.filter { $0 < newYork.date(from: DateComponents(year: 2026, month: 11, day: 1))! }
        let after = all.filter { !before.contains($0) }
        XCTAssertEqual(before.count, 5)
        // One next meeting in the calendar, after the change; the history before it.
        let now = newYork.date(from: DateComponents(year: 2026, month: 11, day: 2, hour: 9))!
        let one = SeriesSchedule.from(upcoming: [after[0]], history: before, now: now, calendar: newYork)
        XCTAssertEqual(one.weekdays, [3])
        XCTAssertEqual(one.minute(on: 3), 15 * 60)
        XCTAssertEqual(one.minuteOfDay, 15 * 60)
        // The calendar's next meetings alone.
        XCTAssertEqual(SeriesSchedule.from(upcoming: after, history: before, now: now, calendar: newYork).minute(on: 3), 15 * 60)
        // No calendar: the newest three meetings, all after the change, say the time of now.
        let later = newYork.date(from: DateComponents(year: 2026, month: 11, day: 25, hour: 9))!
        XCTAssertEqual(SeriesSchedule.from(upcoming: [], history: all, now: later, calendar: newYork).minute(on: 3), 15 * 60)
    }
}
