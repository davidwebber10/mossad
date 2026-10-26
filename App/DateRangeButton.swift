import MossadCore
import SwiftUI

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

/// One button that shows the period's dates. Its menu has the usual periods, each with its dates, and a custom
/// range picked on a calendar. The arrows beside it move the period back or forward by its own length.
struct DateRangeButton: View {
    @Binding var choice: PeriodChoice
    /// The dates the current choice covers, as the report resolved them.
    let interval: DateInterval
    var earliest: Date?
    @State private var picking = false

    var body: some View {
        ControlGroup {
            Button { step(-1) } label: { Label("Earlier", systemImage: "chevron.left") }
                .help("The period before")
            Menu {
                Picker("Period", selection: Binding(get: { choice.preset }, set: select)) {
                    ForEach(PeriodChoice.Preset.allCases.filter { $0 != .custom }) { p in
                        Button {} label: {
                            Text(p.title)
                            Text(periodText(p.range!.interval(earliest: earliest)))
                        }
                        .tag(p)
                    }
                }
                .pickerStyle(.inline)
                Divider()
                Button("Custom range…") { picking = true }
            } label: {
                Label(periodText(interval), systemImage: "calendar").labelStyle(.titleAndIcon)
            }
            .help("Choose the period")
            Button { step(1) } label: { Label("Later", systemImage: "chevron.right") }
                .disabled(interval.end >= Calendar.current.startOfDay(for: Date()))
                .help("The period after")
        }
        .popover(isPresented: $picking, arrowEdge: .bottom) {
            RangeCalendar(start: interval.start, end: interval.end.addingTimeInterval(-1)) { a, b in
                choice = PeriodChoice(preset: .custom, start: a, end: b)
                picking = false
            } cancel: { picking = false }
        }
    }

    private func select(_ p: PeriodChoice.Preset) {
        if p == .custom { picking = true } else { choice.preset = p }
    }

    private func step(_ direction: Int) {
        guard case .custom(let a, let b) = AnalyticsRange.step(interval, by: direction) else { return }
        let today = Calendar.current.startOfDay(for: Date())
        choice = PeriodChoice(preset: .custom, start: min(a, today), end: min(b, today))
    }
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

/// Two months side by side. The first click sets the start, the second the end; the days between highlight.
struct RangeCalendar: View {
    @State private var start: Date
    @State private var end: Date?
    @State private var hover: Date?
    @State private var month: Date
    let apply: (Date, Date) -> Void
    let cancel: () -> Void

    init(start: Date, end: Date, apply: @escaping (Date, Date) -> Void, cancel: @escaping () -> Void) {
        let cal = Calendar.current
        _start = State(initialValue: cal.startOfDay(for: start))
        _end = State(initialValue: cal.startOfDay(for: end))
        // The right-hand month holds the end of the range.
        _month = State(initialValue: cal.date(byAdding: .month, value: -1, to: cal.dateInterval(of: .month, for: end)!.start)!)
        self.apply = apply
        self.cancel = cancel
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Button { shift(-1) } label: { Image(systemName: "chevron.left") }
                    .buttonStyle(.borderless).accessibilityLabel("Earlier months")
                Spacer()
                Text(summary).font(.callout.weight(.medium)).monospacedDigit()
                Spacer()
                Button { shift(1) } label: { Image(systemName: "chevron.right") }
                    .buttonStyle(.borderless).accessibilityLabel("Later months")
                    .disabled(Calendar.current.date(byAdding: .month, value: 2, to: month)! > Date())
            }
            HStack(alignment: .top, spacing: 24) {
                MonthGrid(month: month, start: start, end: end ?? hover, tap: tap, hover: $hover)
                MonthGrid(month: Calendar.current.date(byAdding: .month, value: 1, to: month)!, start: start, end: end ?? hover,
                          tap: tap, hover: $hover)
            }
            HStack {
                Spacer()
                Button("Cancel", action: cancel).keyboardShortcut(.cancelAction)
                Button("Apply") { apply(start, end ?? start) }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(16)
    }

    private var summary: String {
        guard let end else { return "Pick the last day" }
        return periodText(DateInterval(start: start, end: Calendar.current.date(byAdding: .day, value: 1, to: end)!))
    }

    private func tap(_ day: Date) {
        if end == nil, day >= start {
            end = day
        } else {
            start = day
            end = nil
        }
    }

    private func shift(_ n: Int) {
        withAnimation(.snappy) { month = Calendar.current.date(byAdding: .month, value: n, to: month)! }
    }
}

private struct MonthGrid: View {
    let month: Date
    let start: Date
    let end: Date?
    let tap: (Date) -> Void
    @Binding var hover: Date?

    private let cal = Calendar.current

    var body: some View {
        let days = self.days
        VStack(alignment: .leading, spacing: 8) {
            Text(month.formatted(.dateTime.month(.wide).year())).font(.subheadline.weight(.semibold))
            Grid(horizontalSpacing: 0, verticalSpacing: 2) {
                GridRow {
                    ForEach(weekdaySymbols, id: \.self) { Text($0).font(.caption2).foregroundStyle(.secondary).frame(width: 30) }
                }
                ForEach(0..<days.count / 7, id: \.self) { row in
                    GridRow {
                        ForEach(0..<7, id: \.self) { col in cell(days[row * 7 + col]) }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func cell(_ day: Date?) -> some View {
        if let day {
            let today = cal.startOfDay(for: Date())
            let future = day > today
            let lo = min(start, end ?? start), hi = max(start, end ?? start)
            let edge = cal.isDate(day, inSameDayAs: lo) || cal.isDate(day, inSameDayAs: hi)
            let inside = day > lo && day < hi
            Button { tap(day) } label: {
                Text("\(cal.component(.day, from: day))")
                    .font(.callout.weight(edge ? .semibold : .regular)).monospacedDigit()
                    .foregroundStyle(edge ? Color.white : future ? Color.secondary.opacity(0.5) : Color.primary)
                    .frame(width: 30, height: 28)
                    .background {
                        if edge {
                            Circle().fill(Color.accentColor).frame(width: 28, height: 28)
                        } else if inside {
                            Rectangle().fill(Color.accentColor.opacity(0.16))
                        }
                    }
                    .overlay {
                        if cal.isDate(day, inSameDayAs: today), !edge { Circle().strokeBorder(Color.accentColor, lineWidth: 1).frame(width: 28, height: 28) }
                    }
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(future)
            .onHover { inside in if inside { hover = day } }
            .accessibilityLabel(day.formatted(date: .complete, time: .omitted))
        } else {
            Color.clear.frame(width: 30, height: 28)
        }
    }

    private var weekdaySymbols: [String] {
        let s = cal.veryShortStandaloneWeekdaySymbols
        return Array(s[(cal.firstWeekday - 1)...] + s[..<(cal.firstWeekday - 1)])
    }

    /// The month's days in week rows, with blanks before the first and after the last.
    private var days: [Date?] {
        let first = cal.dateInterval(of: .month, for: month)!.start
        let count = cal.range(of: .day, in: .month, for: first)!.count
        let lead = (cal.component(.weekday, from: first) - cal.firstWeekday + 7) % 7
        var cells: [Date?] = Array(repeating: nil, count: lead)
        cells += (0..<count).map { cal.date(byAdding: .day, value: $0, to: first)! }
        while cells.count % 7 != 0 { cells.append(nil) }
        return cells
    }
}
