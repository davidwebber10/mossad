import Foundation

/// The weekdays and the usual times of a series: the one rule that the Recurring list's day groups, its typical
/// week, its search, its filter, and the series page's band read. Pure; the catalog makes it off the main thread.
///
/// The dates are the calendar's next meetings when it has two or more of them, else the next one with the meetings
/// of the last 8 weeks that had one. A weekday is the series' when two or more dates are on it and it has a date in
/// more than half of those weeks, so a daily meeting has five, one week of meetings has none, and a meeting that
/// moves about has none. With no calendar dates, the last three meetings decide when they are all on one weekday:
/// a series that moved is under its new day at once. Each weekday has its own usual time, and the time is known
/// only when more than half of the dates are within 10 minutes of their median. A series with no next meeting and
/// none recently has ended: no day, no time.
public struct SeriesSchedule: Sendable, Equatable, Hashable {
    public enum Repeat: Sendable, Equatable, Hashable {
        /// Each of its weekdays, every week.
        case weekly
        /// Every 2 or 3 weeks.
        case weeks(Int)
        case monthly
        /// About every n days, with no weekly or monthly rhythm.
        case days(Int)
    }

    /// `Calendar` weekdays (1 is Sunday), in Monday-first order. Empty: no fixed day.
    public var weekdays: [Int]
    /// The usual start of each weekday, as minutes after midnight; a weekday without one has no known time.
    public var times: [Int: Int]
    /// The usual start over all dates; for a series with no fixed day.
    public var minuteOfDay: Int?
    /// Nil when the dates show no rhythm.
    public var rhythm: Repeat?
    /// No next meeting and none recently.
    public var ended: Bool

    public init(weekdays: [Int], times: [Int: Int], minuteOfDay: Int?, rhythm: Repeat?, ended: Bool = false) {
        self.weekdays = weekdays
        self.times = times
        self.minuteOfDay = minuteOfDay
        self.rhythm = rhythm
        self.ended = ended
    }

    /// Every weekday at the one time.
    public init(weekdays: [Int], minuteOfDay: Int?, rhythm: Repeat?) {
        self.init(weekdays: weekdays, times: minuteOfDay.map { m in Dictionary(uniqueKeysWithValues: weekdays.map { ($0, m) }) } ?? [:],
                  minuteOfDay: minuteOfDay, rhythm: rhythm)
    }

    /// Nothing known: a series with no dates.
    public static let none = SeriesSchedule(weekdays: [], times: [:], minuteOfDay: nil, rhythm: nil)

    public var hasFixedDay: Bool { !weekdays.isEmpty }
    public func minute(on weekday: Int) -> Int? { times[weekday] }

    /// The words for a rhythm that is not every week on one day: "Every 2 weeks", "Monthly", "Every weekday",
    /// "Mon, Wed", "Not recently". Nil for a weekly meeting on one day, which its day group says.
    public var note: String? {
        if ended { return "Not recently" }
        switch rhythm {
        case .weeks(let n): return "Every \(n) weeks"
        case .monthly: return "Monthly"
        case .days(let n): return "About every \(n) days"
        case .weekly, nil: return weekdays.count > 1 ? daysWords : nil
        }
    }

    /// "Every weekday", "Every day", "Mon, Thu".
    var daysWords: String {
        if weekdays.count == 7 { return "Every day" }
        if weekdays == [2, 3, 4, 5, 6] { return "Every weekday" }
        return weekdays.map { Self.shortNames[$0 - 1] }.joined(separator: ", ")
    }

    /// The series page's line: "Every Tuesday 10:00", "Every weekday 9:30", "Every 2 weeks on Thursday 11:00",
    /// "Monthly on Tuesday", "About every 10 days". The time only when every day has the same one. Nil when nothing
    /// is known. `time` writes the hour and the minute as the owner's clock does; 24 hours without it.
    public func text(time: ((Int, Int) -> String)? = nil) -> String? {
        if ended { return "No meeting recently" }
        let names = weekdays.map { SeriesCadence.weekdays[$0 - 1] }
        let words: String
        switch rhythm {
        case .weekly where weekdays.count == 1: words = "Every \(names[0])"
        case .weekly where weekdays.count > 1: words = weekdays.count == 7 || weekdays == [2, 3, 4, 5, 6] ? daysWords : "Every \(daysWords)"
        case .weeks(let n): words = "Every \(n) weeks" + (names.isEmpty ? "" : " on \(names.joined(separator: " and "))")
        case .monthly: words = "Monthly" + (names.isEmpty ? "" : " on \(names.joined(separator: " and "))")
        case .days(let n): return "About every \(n) days"
        default: return nil
        }
        let one = Set(weekdays.map { times[$0] })
        let minute = weekdays.isEmpty ? minuteOfDay : (one.count == 1 ? one.first ?? nil : nil)
        guard let minute else { return words }
        return words + " " + (time?(minute / 60, minute % 60) ?? String(format: "%d:%02d", minute / 60, minute % 60))
    }

    static let shortNames = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
    /// The weeks of history that the rule reads at most.
    static let weeksRead = 8
    /// The age at which a series with no next meeting has ended, unless its own gaps are longer.
    static let recentDays = 56.0

    /// The schedule of a series: its next meetings from the calendar, else its history (a planned start before the
    /// time the recording began).
    public static func of(_ series: MeetingSeries, now: Date = Date(), calendar: Calendar = .current) -> SeriesSchedule {
        from(upcoming: series.upcoming.map(\.start), history: series.meetings.map { $0.plannedStart ?? $0.start }, now: now, calendar: calendar)
    }

    /// `history` in any order.
    public static func from(upcoming: [Date], history: [Date], now: Date = Date(), calendar: Calendar = .current) -> SeriesSchedule {
        let upcoming = upcoming.sorted()
        let history = history.sorted(by: >)
        var dates = upcoming
        if upcoming.count < 2 {
            // The last meetings, until they span the weeks the rule reads.
            var weeks = Set(upcoming.map { week($0, calendar) })
            for d in history {
                let w = week(d, calendar)
                if !weeks.contains(w) {
                    guard weeks.count < weeksRead else { break }
                    weeks.insert(w)
                }
                dates.append(d)
            }
        }
        let days = distinctDays(dates, calendar)
        guard !days.isEmpty else { return .none }
        let gap = medianGap(days)

        // No next meeting: the history counts only while it is recent, by the series' own pace.
        if upcoming.isEmpty, let newest = days.last,
           now.timeIntervalSince(newest) / 86_400 > max(recentDays, 2 * (gap ?? 0)) {
            return SeriesSchedule(weekdays: [], times: [:], minuteOfDay: nil, rhythm: rhythm(gap, weekdays: [], days: days, calendar), ended: true)
        }

        let minuteOfDay = usualTime(days, calendar)
        guard days.count >= 2, let gap else {
            // One date says no habit: its weekday may not come back.
            return SeriesSchedule(weekdays: [], times: [:], minuteOfDay: minuteOfDay, rhythm: nil)
        }

        let weeks = Set(days.map { week($0, calendar) }).count
        var perWeekday: [Int: [Date]] = [:]
        for d in days { perWeekday[calendar.component(.weekday, from: d), default: []].append(d) }
        var weekdays = perWeekday.filter { $0.value.count >= 2 && $0.value.count * 2 > weeks }.map(\.key)
        var times = Dictionary(uniqueKeysWithValues: weekdays.compactMap { w in usualTime(perWeekday[w] ?? [], calendar).map { (w, $0) } })

        // With no calendar dates, a move shows at once: the newest three on one weekday are the series' day now.
        if upcoming.count < 2 {
            let newest = Array(days.reversed())
            let w = calendar.component(.weekday, from: newest[0])
            if newest.count >= 3, newest.prefix(3).allSatisfy({ calendar.component(.weekday, from: $0) == w }) {
                let run = newest.prefix { calendar.component(.weekday, from: $0) == w }
                weekdays = [w]
                times = usualTime(Array(run), calendar).map { [w: $0] } ?? [:]
            }
        }

        let rhythm = rhythm(gap, weekdays: weekdays, days: days, calendar)
        if case .monthly = rhythm {
            // The same date each month on different weekdays: the date is the habit, not a weekday.
            let dates = Set(days.map { calendar.component(.day, from: $0) })
            let weekdaysSeen = Set(days.map { calendar.component(.weekday, from: $0) })
            if dates.count == 1, weekdaysSeen.count > 1 {
                weekdays = []
                times = [:]
            }
        }
        // Meetings close together with no weekday of their own show no rhythm that a week can hold; one week of
        // meetings shows none at all.
        if weekdays.isEmpty, case .weekly = rhythm {
            return SeriesSchedule(weekdays: [], times: [:], minuteOfDay: minuteOfDay,
                                  rhythm: gap < 1.5 || weeks < 2 ? nil : .days(max(1, Int(gap.rounded()))))
        }
        return SeriesSchedule(weekdays: weekdays.sorted { mondayFirst($0) < mondayFirst($1) }, times: times, minuteOfDay: minuteOfDay, rhythm: rhythm)
    }

    static func rhythm(_ gap: Double?, weekdays: [Int], days: [Date], _ calendar: Calendar) -> Repeat? {
        guard let gap else { return nil }
        if weekdays.count > 1 || gap < 5.5 { return .weekly }
        if let n = (1...3).first(where: { abs(gap - Double(7 * $0)) <= 1.5 }) { return n == 1 ? .weekly : .weeks(n) }
        if (25...36).contains(gap) { return .monthly }
        return .days(max(1, Int(gap.rounded())))
    }

    /// The earliest date of each day, oldest first.
    static func distinctDays(_ dates: [Date], _ calendar: Calendar) -> [Date] {
        var byDay: [Date: Date] = [:]
        for d in dates { byDay[calendar.startOfDay(for: d)] = min(byDay[calendar.startOfDay(for: d)] ?? d, d) }
        return byDay.values.sorted()
    }

    static func medianGap(_ days: [Date]) -> Double? {
        let gaps = zip(days, days.dropFirst()).map { $1.timeIntervalSince($0) / 86_400 }.sorted()
        return gaps.isEmpty ? nil : gaps[gaps.count / 2]
    }

    /// The median start, to five minutes, when more than half of the starts are within 10 minutes of it. A recording
    /// starts a minute or two either side of the hour; the median does not split them.
    static func usualTime(_ dates: [Date], _ calendar: Calendar) -> Int? {
        guard !dates.isEmpty else { return nil }
        let minutes = dates.map { d -> Int in
            let c = calendar.dateComponents([.hour, .minute], from: d)
            return (c.hour ?? 0) * 60 + (c.minute ?? 0)
        }.sorted()
        let median = minutes[(minutes.count - 1) / 2]
        guard minutes.filter({ abs($0 - median) <= 10 }).count * 2 > minutes.count else { return nil }
        // 23:58 is not midnight of the next day.
        return min(Int((Double(median) / 5).rounded()) * 5, 24 * 60 - 5)
    }

    /// 0 for Monday to 6 for Sunday.
    public static func mondayFirst(_ weekday: Int) -> Int { (weekday + 5) % 7 }

    static func week(_ date: Date, _ calendar: Calendar) -> Int {
        let c = calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: date)
        return (c.yearForWeekOfYear ?? 0) * 100 + (c.weekOfYear ?? 0)
    }
}
