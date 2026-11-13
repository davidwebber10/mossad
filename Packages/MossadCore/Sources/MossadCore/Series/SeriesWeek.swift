import Foundation

/// The Recurring list by weekday and its calendar of one typical week. Pure.
public enum SeriesWeek {
    /// What the list and the calendar read of one series.
    public struct Entry: Sendable, Equatable {
        public var id: String
        public var title: String
        public var schedule: SeriesSchedule
        public var next: Date?
        public var last: Date?
        /// The usual length (the filter's median); nil when no meeting says.
        public var minutes: Int?

        public init(id: String, title: String, schedule: SeriesSchedule, next: Date? = nil, last: Date? = nil, minutes: Int? = nil) {
            self.id = id
            self.title = title
            self.schedule = schedule
            self.next = next
            self.last = last
            self.minutes = minutes
        }

        public init(_ series: MeetingSeries, seconds: TimeInterval?, calendar: Calendar = .current) {
            let invite = series.next.map { $0.end.timeIntervalSince($0.start) }
            self.init(id: series.id, title: series.title, schedule: .of(series, calendar: calendar), next: series.next?.start,
                      last: series.last?.start, minutes: (seconds ?? invite).flatMap { $0 > 0 ? Int(($0 / 60).rounded()) : nil })
        }
    }

    /// One group of the list: a weekday, or nil for "No fixed day".
    public struct Day: Sendable, Equatable, Identifiable {
        public var weekday: Int?
        public var ids: [String]
        public var id: Int { weekday ?? 0 }

        public var title: String {
            weekday.map { SeriesCadence.weekdays[$0 - 1] } ?? "No fixed day"
        }
    }

    /// The weekdays in order: Monday to Friday, then Saturday and Sunday.
    public static let order = [2, 3, 4, 5, 6, 7, 1]

    /// One group for each weekday that has a series, Monday first, then "No fixed day". In a day: by the usual
    /// time (none last), then by title. With no fixed day: by the next meeting, then by the last one.
    public static func days(_ entries: [Entry]) -> [Day] {
        var out: [Day] = []
        for weekday in order {
            let here = entries.filter { $0.schedule.weekdays.contains(weekday) }.sorted(by: inDay)
            if !here.isEmpty { out.append(Day(weekday: weekday, ids: here.map(\.id))) }
        }
        let loose = entries.filter { !$0.schedule.hasFixedDay }.sorted(by: unfixed)
        if !loose.isEmpty { out.append(Day(weekday: nil, ids: loose.map(\.id))) }
        return out
    }

    static func inDay(_ a: Entry, _ b: Entry) -> Bool {
        switch (a.schedule.minuteOfDay, b.schedule.minuteOfDay) {
        case let (x?, y?) where x != y: return x < y
        case (.some, nil): return true
        case (nil, .some): return false
        default: return titled(a, b)
        }
    }

    static func unfixed(_ a: Entry, _ b: Entry) -> Bool {
        switch (a.next, b.next) {
        case let (x?, y?) where x != y: return x < y
        case (.some, nil): return true
        case (nil, .some): return false
        case (.some, .some): return titled(a, b)
        default: break
        }
        switch (a.last, b.last) {
        case let (x?, y?) where x != y: return x > y
        case (.some, nil): return true
        case (nil, .some): return false
        default: return titled(a, b)
        }
    }

    static func titled(_ a: Entry, _ b: Entry) -> Bool {
        let c = a.title.localizedStandardCompare(b.title)
        return c == .orderedSame ? a.id < b.id : c == .orderedAscending
    }

    /// The calendar's columns: Monday to Friday, and Saturday or Sunday only when a series meets then.
    public static func columns(_ entries: [Entry]) -> [Int] {
        let used = Set(entries.flatMap(\.schedule.weekdays))
        return order.filter { (2...6).contains($0) || used.contains($0) }
    }

    /// One series at its usual time on one weekday, in minutes after midnight.
    public struct Block: Sendable, Hashable {
        public var id: String
        public var weekday: Int
        public var start: Int
        public var end: Int
        public var column: Int
        public var columns: Int
    }

    /// A block's length when no meeting says one: it must still be seen and clicked.
    public static let unknownMinutes = 30

    /// The blocks of the typical week: each series on each of its weekdays at its usual time and length. Blocks
    /// that overlap sit side by side. A series with no fixed day or no known time is in `unplaced`.
    public static func blocks(_ entries: [Entry]) -> [Block] {
        var out: [Block] = []
        for weekday in order {
            let spans = entries.compactMap { e -> (id: String, start: Int, end: Int)? in
                guard e.schedule.weekdays.contains(weekday), let start = e.schedule.minuteOfDay else { return nil }
                return (e.id, start, min(24 * 60, start + max(5, e.minutes ?? unknownMinutes)))
            }
            .sorted { ($0.start, $0.end, $0.id) < ($1.start, $1.end, $1.id) }
            out += CalendarLayout.pack(spans).enumerated().map { i, p in
                Block(id: p.id, weekday: weekday, start: spans[i].start, end: spans[i].end, column: p.column, columns: p.columns)
            }
        }
        return out
    }

    /// The series the grid cannot place, in the order of "No fixed day": no fixed day, or no known time.
    public static func unplaced(_ entries: [Entry]) -> [Entry] {
        entries.filter { !$0.schedule.hasFixedDay || $0.schedule.minuteOfDay == nil }.sorted(by: unfixed)
    }

    /// Whether the series meets in the week of `now`: true when it met or will meet on one of its weekdays, false
    /// only when the calendar shows none of its weekdays still to come this week and none of them has come yet. Nil
    /// when the calendar has nothing of it, or one of its weekdays is today or passed with nothing seen (it may have met).
    public static func meetsThisWeek(_ series: MeetingSeries, schedule: SeriesSchedule, now: Date, calendar: Calendar = .current) -> Bool? {
        guard !series.upcoming.isEmpty, schedule.hasFixedDay, let week = calendar.dateInterval(of: .weekOfYear, for: now) else { return nil }
        let dates = series.upcoming.map(\.start) + series.meetings.map(\.start)
        if dates.contains(where: { week.contains($0) }) { return true }
        let today = calendar.startOfDay(for: now)
        let passed = (0..<7).compactMap { calendar.date(byAdding: .day, value: $0, to: week.start) }
            .filter { schedule.weekdays.contains(calendar.component(.weekday, from: $0)) }
            .contains { $0 <= today }
        return passed ? nil : false
    }
}
