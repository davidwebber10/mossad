import Foundation

/// One call placed on a day: its times clipped to that day, and its column among the calls it overlaps.
public struct CalendarItem: Equatable, Sendable {
    public var id: String
    public var start: Date
    public var end: Date
    public var column: Int
    public var columns: Int

    public init(id: String, start: Date, end: Date, column: Int, columns: Int) {
        self.id = id
        self.start = start
        self.end = end
        self.column = column
        self.columns = columns
    }
}

public enum CalendarLayout {
    /// The calls on `day`, sorted by start. Calls that overlap share the width: each takes the first free column.
    public static func day(_ records: [CallRecord], on day: Date, calendar: Calendar) -> [CalendarItem] {
        let dayStart = calendar.startOfDay(for: day)
        // Adding a day, not 24 hours, keeps 23 and 25 hour days right.
        guard let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) else { return [] }
        let items = records
            .filter { $0.start < dayEnd && ($0.end > dayStart || $0.start >= dayStart) }
            .map { CalendarItem(id: $0.id, start: max($0.start, dayStart), end: max(min($0.end, dayEnd), max($0.start, dayStart)),
                                column: 0, columns: 1) }
            .sorted { ($0.start, $0.end, $0.id) < ($1.start, $1.end, $1.id) }

        var result: [CalendarItem] = []
        var group: [CalendarItem] = []
        var columnEnds: [Date] = []
        var groupEnd = Date.distantPast

        func closeGroup() {
            result += group.map { var item = $0; item.columns = columnEnds.count; return item }
            group = []
            columnEnds = []
        }

        for var item in items {
            if item.start >= groupEnd { closeGroup() }
            if let free = columnEnds.firstIndex(where: { $0 <= item.start }) {
                item.column = free
                columnEnds[free] = item.end
            } else {
                item.column = columnEnds.count
                columnEnds.append(item.end)
            }
            groupEnd = group.isEmpty ? item.end : max(groupEnd, item.end)
            group.append(item)
        }
        closeGroup()
        return result
    }

    /// The 42 days of a 6 by 7 month grid that starts on `calendar.firstWeekday`.
    public static func monthCells(month: Date, calendar: Calendar) -> [Date] {
        guard let first = calendar.dateInterval(of: .month, for: month)?.start else { return [] }
        let offset = (calendar.component(.weekday, from: first) - calendar.firstWeekday + 7) % 7
        return (0..<42).compactMap { calendar.date(byAdding: .day, value: $0 - offset, to: first) }
    }
}
