import Foundation
import MossadCore

/// The period an Analytics page shows, as it is remembered between launches.
struct PeriodChoice: Equatable {
    enum Preset: String, CaseIterable, Identifiable {
        case last7Days, last30Days, last90Days, thisMonth, lastMonth, thisYear, all, custom
        var id: String { rawValue }

        var title: String {
            switch self {
            case .last7Days: "Last 7 days"
            case .last30Days: "Last 30 days"
            case .last90Days: "Last 90 days"
            case .thisMonth: "This month"
            case .lastMonth: "Last month"
            case .thisYear: "This year"
            case .all: "All time"
            case .custom: "Custom range"
            }
        }

        var range: AnalyticsRange? {
            switch self {
            case .last7Days: .last7Days
            case .last30Days: .last30Days
            case .last90Days: .last90Days
            case .thisMonth: .thisMonth
            case .lastMonth: .lastMonth
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

