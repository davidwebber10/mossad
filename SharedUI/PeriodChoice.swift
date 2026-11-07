import Foundation
import MossadCore

/// The period an Analytics page shows, as it is remembered between launches.
struct PeriodChoice: Equatable {
    enum Preset: String, CaseIterable, Identifiable {
        // Raw values are stored in settings: add cases, never rename them.
        case last7Days, last30Days, last90Days, thisMonth, lastMonth, thisQuarter, lastQuarter, thisYear, all, custom
        var id: String { rawValue }

        /// The Mac's date picker: the canvas's order, with 90 days and All time kept from before.
        static let picker: [Preset] = [.last7Days, .last30Days, .last90Days, .thisMonth, .lastMonth, .thisQuarter, .lastQuarter, .thisYear, .all, .custom]

        var title: String {
            switch self {
            case .last7Days: "Last 7 days"
            case .last30Days: "Last 30 days"
            case .last90Days: "Last 90 days"
            case .thisMonth: "This month"
            case .lastMonth: "Last month"
            case .thisQuarter: "This quarter"
            case .lastQuarter: "Last quarter"
            case .thisYear: "Year to date"
            case .all: "All time"
            case .custom: "Custom"
            }
        }

        var range: AnalyticsRange? {
            switch self {
            case .last7Days: .last7Days
            case .last30Days: .last30Days
            case .last90Days: .last90Days
            case .thisMonth: .thisMonth
            case .lastMonth: .lastMonth
            case .thisQuarter: .thisQuarter
            case .lastQuarter: .lastQuarter
            case .thisYear: .yearToDate
            case .all: .all
            case .custom: nil
            }
        }
    }

    var preset: Preset
    var start: Date
    var end: Date

    var range: AnalyticsRange { preset.range ?? .custom(min(start, end), max(start, end)) }
}

/// "Sep 27 – Oct 26, 2026"; the year shows once when both ends share it.
func periodText(_ i: DateInterval) -> String {
    let end = i.end.addingTimeInterval(-1)
    let cal = Calendar.current
    if cal.isDate(i.start, inSameDayAs: end) { return end.formatted(.dateTime.month(.abbreviated).day().year()) }
    let sameYear = cal.isDate(i.start, equalTo: end, toGranularity: .year)
    let start = sameYear ? i.start.formatted(.dateTime.month(.abbreviated).day()) : i.start.formatted(.dateTime.month(.abbreviated).day().year())
    return "\(start) – \(end.formatted(.dateTime.month(.abbreviated).day().year()))"
}

/// A preset's dates beside its name, as short as they can be: "October", "Jul – Sep", "Nov 1 – 6", "Oct 31 – Nov 6".
func shortPeriodText(_ i: DateInterval) -> String {
    let cal = Calendar.current
    let last = i.end.addingTimeInterval(-1)
    // Whole months: from the 1st at midnight to the end of a month.
    let startsMonth = cal.startOfDay(for: i.start) == i.start && cal.component(.day, from: i.start) == 1
    if startsMonth, cal.dateInterval(of: .month, for: last)?.end == i.end {
        if cal.isDate(i.start, equalTo: last, toGranularity: .month) { return i.start.formatted(.dateTime.month(.wide)) }
        return "\(i.start.formatted(.dateTime.month(.abbreviated))) – \(last.formatted(.dateTime.month(.abbreviated)))"
    }
    if cal.isDate(i.start, inSameDayAs: last) { return last.formatted(.dateTime.month(.abbreviated).day()) }
    if cal.isDate(i.start, equalTo: last, toGranularity: .month) {
        return "\(i.start.formatted(.dateTime.month(.abbreviated).day())) – \(cal.component(.day, from: last))"
    }
    return "\(i.start.formatted(.dateTime.month(.abbreviated).day())) – \(last.formatted(.dateTime.month(.abbreviated).day()))"
}
