import Foundation

/// The meeting list's sections: Today, Yesterday, This week, Earlier.
public enum MeetingGroups {
    public enum Kind: Int, Sendable, CaseIterable {
        case today, yesterday, thisWeek, earlier

        public var title: String {
            switch self {
            case .today: "Today"
            case .yesterday: "Yesterday"
            case .thisWeek: "This week"
            case .earlier: "Earlier"
            }
        }
    }

    public struct Group: Sendable {
        public var kind: Kind
        public var records: [CallRecord]
    }

    /// Newest first inside each group; empty groups are left out.
    public static func group(_ records: [CallRecord], now: Date = Date(), calendar: Calendar = .current) -> [Group] {
        var buckets: [Kind: [CallRecord]] = [:]
        for r in records { buckets[kind(of: r.start, now: now, calendar: calendar), default: []].append(r) }
        return Kind.allCases.compactMap { kind in
            guard let list = buckets[kind], !list.isEmpty else { return nil }
            return Group(kind: kind, records: list.sorted { $0.start > $1.start })
        }
    }

    public static func kind(of date: Date, now: Date = Date(), calendar: Calendar = .current) -> Kind {
        if calendar.isDate(date, inSameDayAs: now) { return .today }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: yesterday) { return .yesterday }
        if calendar.isDate(date, equalTo: now, toGranularity: .weekOfYear), date < now { return .thisWeek }
        return .earlier
    }

    /// One calendar day of meetings, titled as the Mac list shows it.
    public struct Day: Sendable {
        /// The start of the day.
        public var date: Date
        public var title: String
        public var records: [CallRecord]
    }

    /// The Mac list's sections: Today, Yesterday, the weekday for the rest of the last week, then the date
    /// ("Oct 9", with the year when it is not this year). Newest first; each row then needs only its time.
    public static func byDay(_ records: [CallRecord], now: Date = Date(), calendar: Calendar = .current) -> [Day] {
        let buckets = Dictionary(grouping: records) { calendar.startOfDay(for: $0.start) }
        let today = calendar.startOfDay(for: now)
        return buckets.keys.sorted(by: >).map { day in
            Day(date: day, title: dayTitle(day, today: today, calendar: calendar),
                records: buckets[day, default: []].sorted { $0.start > $1.start })
        }
    }

    private static func dayTitle(_ day: Date, today: Date, calendar: Calendar) -> String {
        let back = calendar.dateComponents([.day], from: day, to: today).day ?? 0
        if back == 0 { return "Today" }
        if back == 1 { return "Yesterday" }
        var style = Date.FormatStyle(locale: calendar.locale ?? .current, calendar: calendar, timeZone: calendar.timeZone)
        if back > 1, back < 7 { return day.formatted(style.weekday(.wide)) }
        style = style.month(.abbreviated).day()
        if !calendar.isDate(day, equalTo: today, toGranularity: .year) { style = style.year() }
        return day.formatted(style)
    }
}
