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
        /// The usual length: the next invite's, else the filter's median of the recorded ones; nil when nothing says.
        public var minutes: Int?
        /// The starts of the next meetings in the calendar, soonest first.
        public var upcoming: [Date]
        /// Its weekdays still to come this week (Monday to Sunday) that have no date in the calendar.
        public var skipped: Set<Int>

        public init(id: String, title: String, schedule: SeriesSchedule, next: Date? = nil, last: Date? = nil, minutes: Int? = nil,
                    upcoming: [Date] = [], skipped: Set<Int> = []) {
            self.id = id
            self.title = title
            self.schedule = schedule
            self.next = next
            self.last = last
            self.minutes = minutes
            self.upcoming = upcoming
            self.skipped = skipped
        }

        /// `seconds` is the filter's median of the recorded lengths.
        public init(_ series: MeetingSeries, seconds: TimeInterval?, now: Date = Date(), calendar: Calendar = .current) {
            // The invite says what is planned; a series often recorded late or long says less.
            let invite = series.next.map { $0.end.timeIntervalSince($0.start) }.flatMap { $0 > 0 ? $0 : nil }
            let upcoming = series.upcoming.map(\.start)
            self.init(id: series.id, title: series.title, schedule: series.schedule, next: series.next?.start, last: series.last?.start,
                      minutes: (invite ?? seconds).flatMap { $0 > 0 ? Int(($0 / 60).rounded()) : nil }, upcoming: upcoming,
                      skipped: SeriesWeek.skipped(series.schedule, upcoming: upcoming, now: now, calendar: calendar))
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
    /// time of that day (none last), then by title. With no fixed day (a series that ended too): by the next
    /// meeting, then by the last one.
    public static func days(_ entries: [Entry]) -> [Day] {
        var out: [Day] = []
        for weekday in order {
            let here = entries.filter { $0.schedule.weekdays.contains(weekday) }.sorted { inDay($0, $1, weekday) }
            if !here.isEmpty { out.append(Day(weekday: weekday, ids: here.map(\.id))) }
        }
        let loose = entries.filter { !$0.schedule.hasFixedDay }.sorted(by: unfixed)
        if !loose.isEmpty { out.append(Day(weekday: nil, ids: loose.map(\.id))) }
        return out
    }

    static func inDay(_ a: Entry, _ b: Entry, _ weekday: Int) -> Bool {
        switch (a.schedule.minute(on: weekday), b.schedule.minute(on: weekday)) {
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

    /// What a row under a weekday says of the next meeting: that weekday's own next date, and only when the header
    /// does not say it already. Today, tomorrow, or a date a week or more away (a week it skips); nothing for 2 to
    /// 6 days away, or with no date on that weekday.
    public enum NextWord: Sendable, Equatable {
        case today, tomorrow
        case date(Date)
    }

    public static func next(on weekday: Int, upcoming: [Date], now: Date, calendar: Calendar = .current) -> NextWord? {
        let today = calendar.startOfDay(for: now)
        guard let date = upcoming.sorted().first(where: { $0 >= today && calendar.component(.weekday, from: $0) == weekday }) else { return nil }
        let days = calendar.dateComponents([.day], from: today, to: calendar.startOfDay(for: date)).day ?? 0
        switch days {
        case 0: return .today
        case 1: return .tomorrow
        case 2...6: return nil
        default: return .date(date)
        }
    }

    /// One row of the list: a series under one day group (`Day.id`).
    public struct Row: Sendable, Hashable {
        public var day: Int
        public var id: String
        public init(day: Int, id: String) {
            self.day = day
            self.id = id
        }
    }

    /// The rows in the order shown.
    public static func rows(_ days: [Day]) -> [Row] { days.flatMap { d in d.ids.map { Row(day: d.id, id: $0) } } }

    /// The arrow keys: one stop per row, from the row the keys or a click left (`cursor`) while it is of the
    /// selected series, else from the first row of the selected series, else from the top.
    public static func move(_ rows: [Row], cursor: Row?, selection: String?, by: Int) -> Row? {
        guard !rows.isEmpty else { return nil }
        let from = cursor.flatMap { c in c.id == selection ? rows.firstIndex(of: c) : nil } ?? rows.firstIndex { $0.id == selection }
        return rows[from.map { min(max($0 + by, 0), rows.count - 1) } ?? 0]
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
        /// The calendar has no date of it on this weekday, still to come this week.
        public var skipped: Bool
    }

    /// A block's length when no meeting says one: it must still be seen and clicked.
    public static let unknownMinutes = 30
    /// The least height of a block, in minutes of the grid: a short one is drawn this tall, so it is packed so too.
    public static let leastMinutes = 20

    /// The blocks of the typical week: each series on each of its weekdays at that day's usual time and its usual
    /// length. Blocks that overlap, as drawn, sit side by side. A series with no fixed day or a day with no known
    /// time is in `unplaced`.
    public static func blocks(_ entries: [Entry]) -> [Block] {
        var out: [Block] = []
        for weekday in order {
            let spans = entries.compactMap { e -> (id: String, start: Int, end: Int, skipped: Bool)? in
                guard e.schedule.weekdays.contains(weekday), let start = e.schedule.minute(on: weekday) else { return nil }
                return (e.id, start, min(24 * 60, start + max(5, e.minutes ?? unknownMinutes)), e.skipped.contains(weekday))
            }
            .sorted { ($0.start, $0.end, $0.id) < ($1.start, $1.end, $1.id) }
            let drawn = spans.map { (id: $0.id, start: $0.start, end: max($0.end, $0.start + leastMinutes)) }
            out += CalendarLayout.pack(drawn).enumerated().map { i, p in
                Block(id: p.id, weekday: weekday, start: spans[i].start, end: spans[i].end, column: p.column, columns: p.columns, skipped: spans[i].skipped)
            }
        }
        return out
    }

    /// The series the grid cannot place, in the order of "No fixed day": no fixed day, or a weekday with no known
    /// time. A series that ended is in the list only.
    public static func unplaced(_ entries: [Entry]) -> [Entry] {
        entries.filter { e in
            !e.schedule.ended && (!e.schedule.hasFixedDay || e.schedule.weekdays.contains { e.schedule.minute(on: $0) == nil })
        }
        .sorted(by: unfixed)
    }

    /// The weekdays of the series still to come in this week, Monday to Sunday as the grid shows it, that have no
    /// date in the calendar. Today is never one: a meeting earlier today is not in the calendar's next ones. Empty
    /// when the calendar has nothing of the series.
    public static func skipped(_ schedule: SeriesSchedule, upcoming: [Date], now: Date, calendar: Calendar = .current) -> Set<Int> {
        guard !upcoming.isEmpty else { return [] }
        let today = calendar.startOfDay(for: now)
        let monday = calendar.date(byAdding: .day, value: -SeriesSchedule.mondayFirst(calendar.component(.weekday, from: today)), to: today) ?? today
        var out: Set<Int> = []
        for w in schedule.weekdays {
            guard let day = calendar.date(byAdding: .day, value: SeriesSchedule.mondayFirst(w), to: monday), day > today else { continue }
            if !upcoming.contains(where: { calendar.isDate($0, inSameDayAs: day) }) { out.insert(w) }
        }
        return out
    }
}
