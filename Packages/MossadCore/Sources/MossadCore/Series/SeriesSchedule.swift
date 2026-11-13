import Foundation

/// The weekdays and the usual time of a series, for the Recurring list's day groups and its typical week. Pure.
///
/// The dates are the calendar's next meetings when it has two or more of them (the calendar's own recurrence),
/// else the next one with the last meetings that happened. A weekday is the series' when it has a meeting in more
/// than half of the weeks that have one, so a daily meeting has five and a meeting that moves has none. The time is
/// the one that more than half of the dates have, to five minutes; with no clear majority it is unknown, never
/// guessed.
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
    /// The usual start as minutes after midnight; nil when the dates do not agree.
    public var minuteOfDay: Int?
    /// Nil with fewer than two dates.
    public var rhythm: Repeat?

    public init(weekdays: [Int], minuteOfDay: Int?, rhythm: Repeat?) {
        self.weekdays = weekdays
        self.minuteOfDay = minuteOfDay
        self.rhythm = rhythm
    }

    public var hasFixedDay: Bool { !weekdays.isEmpty }
    public var hour: Int? { minuteOfDay.map { $0 / 60 } }
    public var minute: Int? { minuteOfDay.map { $0 % 60 } }

    /// The words for a rhythm that is not every week on one day: "Every 2 weeks", "Monthly", "Every weekday",
    /// "Mon, Wed". Nil for a weekly meeting on one day, which its day group says.
    public var note: String? {
        switch rhythm {
        case .weeks(let n): return "Every \(n) weeks"
        case .monthly: return "Monthly"
        case .days(let n): return "About every \(n) days"
        case .weekly, nil:
            guard weekdays.count > 1 else { return nil }
            if weekdays.count == 7 { return "Every day" }
            if weekdays == [2, 3, 4, 5, 6] { return "Every weekday" }
            return weekdays.map { Self.shortNames[$0 - 1] }.joined(separator: ", ")
        }
    }

    static let shortNames = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
    /// The weeks of history that the rule reads at most.
    static let weeksRead = 8

    /// The schedule of a series: its next meetings from the calendar, else its history (a planned start before the
    /// time the recording began).
    public static func of(_ series: MeetingSeries, calendar: Calendar = .current) -> SeriesSchedule {
        from(upcoming: series.upcoming.map(\.start), history: series.meetings.map { $0.plannedStart ?? $0.start }, calendar: calendar)
    }

    /// `history` newest first.
    public static func from(upcoming: [Date], history: [Date], calendar: Calendar = .current) -> SeriesSchedule {
        var dates = upcoming
        if upcoming.count < 2 {
            // The last meetings, until they span the weeks the rule reads.
            var weeks = Set(upcoming.map { week($0, calendar) })
            for d in history.sorted(by: >) {
                let w = week(d, calendar)
                if !weeks.contains(w) {
                    guard weeks.count < weeksRead else { break }
                    weeks.insert(w)
                }
                dates.append(d)
            }
        }
        // One date for each day: the earliest of it.
        var byDay: [Date: Date] = [:]
        for d in dates { byDay[calendar.startOfDay(for: d)] = min(byDay[calendar.startOfDay(for: d)] ?? d, d) }
        let days = byDay.values.sorted()
        guard !days.isEmpty else { return SeriesSchedule(weekdays: [], minuteOfDay: nil, rhythm: nil) }

        let times = days.map { d -> Int in
            let c = calendar.dateComponents([.hour, .minute], from: d)
            return ((c.hour ?? 0) * 60 + (c.minute ?? 0) + 2) / 5 * 5
        }
        let minuteOfDay = majority(times, of: times.count)

        guard days.count >= 2 else {
            // One date says no habit: its weekday may not come back.
            return SeriesSchedule(weekdays: [], minuteOfDay: minuteOfDay, rhythm: nil)
        }

        let weeks = Set(days.map { week($0, calendar) }).count
        var perWeekday: [Int: Int] = [:]
        for d in days { perWeekday[calendar.component(.weekday, from: d), default: 0] += 1 }
        var weekdays = perWeekday.filter { $0.value * 2 > weeks }.map(\.key)

        let gaps = zip(days, days.dropFirst()).map { $1.timeIntervalSince($0) / 86_400 }.sorted()
        let gap = gaps[gaps.count / 2]
        let rhythm: Repeat
        if weekdays.count > 1 || gap < 5.5 {
            rhythm = .weekly
        } else if let n = (1...3).first(where: { abs(gap - Double(7 * $0)) <= 1.5 }) {
            rhythm = n == 1 ? .weekly : .weeks(n)
        } else if (25...36).contains(gap) {
            rhythm = .monthly
            // The same date each month, on different weekdays: the date is the habit, not a weekday.
            let dates = Set(days.map { calendar.component(.day, from: $0) })
            let ordinals = Set(days.map { calendar.component(.weekdayOrdinal, from: $0) })
            if dates.count == 1, ordinals.count > 1 { weekdays = [] }
        } else {
            rhythm = .days(max(1, Int(gap.rounded())))
        }
        // Some days apart with no weekday of its own is no rhythm that a week shows.
        if case .weekly = rhythm, weekdays.isEmpty, gap >= 1.5 {
            return SeriesSchedule(weekdays: [], minuteOfDay: minuteOfDay, rhythm: .days(max(1, Int(gap.rounded()))))
        }
        return SeriesSchedule(weekdays: weekdays.sorted { mondayFirst($0) < mondayFirst($1) }, minuteOfDay: minuteOfDay, rhythm: rhythm)
    }

    /// 0 for Monday to 6 for Sunday.
    public static func mondayFirst(_ weekday: Int) -> Int { (weekday + 5) % 7 }

    /// The value that more than half of `count` have.
    static func majority(_ values: [Int], of count: Int) -> Int? {
        var counts: [Int: Int] = [:]
        for v in values { counts[v, default: 0] += 1 }
        return counts.first { $0.value * 2 > count }?.key
    }

    static func week(_ date: Date, _ calendar: Calendar) -> Int {
        let c = calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: date)
        return (c.yearForWeekOfYear ?? 0) * 100 + (c.weekOfYear ?? 0)
    }
}
