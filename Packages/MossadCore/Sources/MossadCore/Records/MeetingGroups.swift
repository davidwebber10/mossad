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
}
