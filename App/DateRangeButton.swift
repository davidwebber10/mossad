import MossadCore
import SwiftUI

/// The period's dates between two arrows that move it back or forward by its own length. The dates open the
/// period panel: presets on the left, two months on the right, and the comparison switch.
struct DateRangeButton: View {
    @Binding var choice: PeriodChoice
    @Binding var compare: Bool
    /// The dates the current choice covers, as the report resolved them.
    let interval: DateInterval
    var earliest: Date?
    @State private var picking = false

    var body: some View {
        ControlGroup {
            Button { step(-1) } label: { Label("Earlier", systemImage: "chevron.left") }
                .help("The period before")
            Button { picking.toggle() } label: { Text(periodText(interval)).monospacedDigit() }
                .help("Choose the period")
                .accessibilityLabel("Period, \(periodText(interval))")
                .popover(isPresented: $picking, arrowEdge: .bottom) {
                    PeriodPanel(choice: $choice, compare: $compare, interval: interval, earliest: earliest) { picking = false }
                }
            Button { step(1) } label: { Label("Later", systemImage: "chevron.right") }
                .disabled(interval.end >= Calendar.current.startOfDay(for: Date()))
                .help("The period after")
        }
    }

    private func step(_ direction: Int) {
        guard case .custom(let a, let b) = AnalyticsRange.step(interval, by: direction) else { return }
        let today = Calendar.current.startOfDay(for: Date())
        choice = PeriodChoice(preset: .custom, start: min(a, today), end: min(b, today))
    }
}

/// The canvas's date picker. Nothing changes until Apply, so trying a preset or a range costs no report.
struct PeriodPanel: View {
    @Binding var choice: PeriodChoice
    @Binding var compare: Bool
    var earliest: Date?
    let close: () -> Void

    @State private var preset: PeriodChoice.Preset
    @State private var start: Date
    @State private var end: Date?
    @State private var hover: Date?
    /// The first of the two months shown.
    @State private var month: Date
    @State private var compareOn: Bool

    private static let cal = Calendar.current

    init(choice: Binding<PeriodChoice>, compare: Binding<Bool>, interval: DateInterval, earliest: Date?, close: @escaping () -> Void) {
        _choice = choice
        _compare = compare
        self.earliest = earliest
        self.close = close
        let first = Self.cal.startOfDay(for: interval.start), last = Self.cal.startOfDay(for: interval.end.addingTimeInterval(-1))
        _preset = State(initialValue: choice.wrappedValue.preset)
        _start = State(initialValue: first)
        _end = State(initialValue: max(first, last))
        _month = State(initialValue: Self.monthBefore(last))
        _compareOn = State(initialValue: compare.wrappedValue)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            presets
                // Wider than the canvas's 160 so "Last 30 days · Oct 8 – Nov 6" fits without cutting.
                .frame(width: 214)
                .padding(.trailing, 10)
                .overlay(alignment: .trailing) { Hairline(axis: .vertical) }
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: 20) {
                    PanelMonth(month: month, start: start, end: end ?? hover, tap: tap, hover: $hover,
                               shift: (-1, "Earlier months"), onShift: shift)
                    PanelMonth(month: Self.cal.date(byAdding: .month, value: 1, to: month)!, start: start, end: end ?? hover, tap: tap,
                               hover: $hover, shift: canGoLater ? (1, "Later months") : nil, onShift: shift)
                }
                // A range being picked previews to the day under the pointer, and only while it is there.
                .onHover { inside in if !inside { hover = nil } }
                footer
            }
            .padding(EdgeInsets(top: 4, leading: 4, bottom: 2, trailing: 4))
        }
        .padding(8)
        .font(.system(size: 12.5))
        .foregroundStyle(Palette.ink)
    }

    private var presets: some View {
        VStack(alignment: .leading, spacing: 1) {
            ForEach(PeriodChoice.Preset.picker) { p in
                let on = p == preset
                Button { pick(p) } label: {
                    HStack {
                        Text(p.title).fontWeight(on ? .semibold : .regular).fixedSize()
                        Spacer(minLength: 6)
                        if let range = p.range {
                            Text(shortPeriodText(range.interval(earliest: earliest)))
                                .font(.system(size: 11)).monospacedDigit().opacity(on ? 0.85 : 1)
                                .foregroundStyle(on ? Palette.onAccent : Palette.secondary)
                        }
                    }
                    .foregroundStyle(on ? Palette.onAccent : Palette.ink)
                    .lineLimit(1)
                    .padding(.horizontal, 10)
                    .frame(height: 28)
                    .background(on ? Palette.accentFill : .clear, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                    .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 12) {
            if let end {
                let i = DateInterval(start: start, end: Self.cal.date(byAdding: .day, value: 1, to: end)!)
                Text(periodText(i)).fontWeight(.semibold).monospacedDigit()
                    + Text(" · \(days(i)) \(days(i) == 1 ? "day" : "days")").foregroundStyle(Palette.secondary)
            } else {
                Text("Pick the last day").foregroundStyle(Palette.secondary)
            }
            Spacer(minLength: 12)
            Toggle(isOn: $compareOn) {
                Text("Compare with the \(days(pending)) \(days(pending) == 1 ? "day" : "days") before")
                    .font(.system(size: 12)).foregroundStyle(Palette.secondary)
            }
            .toggleStyle(PanelSwitchStyle())
            .fixedSize()
            Button("Apply", action: apply)
                .buttonStyle(SheetButtonStyle(kind: .primary, compact: true))
                .keyboardShortcut(.defaultAction)
                .disabled(end == nil)
        }
        .padding(.top, 10)
        .overlay(alignment: .top) { Hairline() }
    }

    private var pending: DateInterval {
        DateInterval(start: start, end: Self.cal.date(byAdding: .day, value: 1, to: end ?? start)!)
    }

    private func days(_ i: DateInterval) -> Int { max(1, Int((i.duration / 86_400).rounded())) }

    private var canGoLater: Bool { Self.cal.date(byAdding: .month, value: 2, to: month)! <= Date() }

    private func pick(_ p: PeriodChoice.Preset) {
        preset = p
        guard let range = p.range else { return }
        let i = range.interval(earliest: earliest)
        start = Self.cal.startOfDay(for: i.start)
        end = max(start, Self.cal.startOfDay(for: i.end.addingTimeInterval(-1)))
        withAnimation(.snappy) { month = Self.monthBefore(end!) }
    }

    /// The first click starts a range, the second ends it; a click before the start starts again.
    private func tap(_ day: Date) {
        preset = .custom
        if end == nil, day >= start {
            end = day
        } else {
            start = day
            end = nil
        }
    }

    private func shift(_ n: Int) {
        withAnimation(.snappy) { month = Self.cal.date(byAdding: .month, value: n, to: month)! }
    }

    private func apply() {
        if preset == .custom {
            choice = PeriodChoice(preset: .custom, start: start, end: end ?? start)
        } else {
            choice.preset = preset
        }
        compare = compareOn
        close()
    }

    /// The right-hand month holds the end of the range.
    private static func monthBefore(_ day: Date) -> Date {
        cal.date(byAdding: .month, value: -1, to: cal.dateInterval(of: .month, for: day)!.start)!
    }
}

/// One month of the panel: 32 pt columns, the range as an accent tint with round ends, its ends as accent dots.
private struct PanelMonth: View {
    let month: Date
    let start: Date
    let end: Date?
    let tap: (Date) -> Void
    @Binding var hover: Date?
    /// The arrow in this month's header, if any: the step and its spoken name.
    let shift: (Int, String)?
    let onShift: (Int) -> Void

    private let cal = Calendar.current

    var body: some View {
        let days = self.days
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                if let shift, shift.0 < 0 { arrow(shift) }
                Text(month.formatted(.dateTime.month(.wide).year())).fontWeight(.semibold)
                Spacer()
                if let shift, shift.0 > 0 { arrow(shift) }
            }
            .frame(height: 24)
            .padding(.horizontal, 4)
            Grid(horizontalSpacing: 0, verticalSpacing: 0) {
                GridRow {
                    ForEach(Array(weekdaySymbols.enumerated()), id: \.offset) { _, s in
                        Text(s).font(.system(size: 10.5)).foregroundStyle(Palette.tertiary).frame(width: 32)
                    }
                }
                .padding(.bottom, 4)
                ForEach(0..<days.count / 7, id: \.self) { row in
                    GridRow {
                        ForEach(0..<7, id: \.self) { col in cell(days[row * 7 + col], column: col) }
                    }
                    .padding(.bottom, 2)
                }
            }
        }
        .frame(width: 224, alignment: .leading)
    }

    private func arrow(_ shift: (Int, String)) -> some View {
        Button { onShift(shift.0) } label: {
            Image(systemName: shift.0 < 0 ? "chevron.left" : "chevron.right")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Palette.secondary)
                .frame(width: 20, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(shift.1)
    }

    @ViewBuilder
    private func cell(_ day: Date?, column: Int) -> some View {
        if let day {
            let today = cal.startOfDay(for: Date())
            let future = day > today
            let lo = min(start, end ?? start), hi = max(start, end ?? start)
            let isStart = cal.isDate(day, inSameDayAs: lo), isEnd = cal.isDate(day, inSameDayAs: hi)
            let inside = day >= lo && day <= hi && end != nil
            let edge = isStart || isEnd
            Button { tap(day) } label: {
                Text("\(cal.component(.day, from: day))")
                    .font(.system(size: 12, weight: edge ? .semibold : .regular)).monospacedDigit()
                    .foregroundStyle(edge ? Palette.onAccent : future ? Palette.tertiary : Palette.ink)
                    .frame(width: 26, height: 26)
                    .background {
                        if edge {
                            Circle().fill(Palette.accentFill)
                        } else if cal.isDate(day, inSameDayAs: today) {
                            Circle().strokeBorder(Palette.ring, lineWidth: 1)
                        }
                    }
                    .frame(width: 32, height: 28)
                    .background {
                        if inside {
                            let round = (lead: isStart || column == 0 || startsMonth(day), trail: isEnd || column == 6 || endsMonth(day))
                            UnevenRoundedRectangle(topLeadingRadius: round.lead ? 14 : 0, bottomLeadingRadius: round.lead ? 14 : 0,
                                                   bottomTrailingRadius: round.trail ? 14 : 0, topTrailingRadius: round.trail ? 14 : 0,
                                                   style: .continuous)
                                .fill(Palette.accentTint)
                        }
                    }
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(future)
            .onHover { inside in if inside { hover = day } }
            .accessibilityLabel(day.formatted(date: .complete, time: .omitted))
            .accessibilityAddTraits(edge ? .isSelected : [])
        } else {
            Color.clear.frame(width: 32, height: 28)
        }
    }

    private func startsMonth(_ day: Date) -> Bool { cal.component(.day, from: day) == 1 }
    private func endsMonth(_ day: Date) -> Bool { !cal.isDate(cal.date(byAdding: .day, value: 1, to: day)!, equalTo: day, toGranularity: .month) }

    private var weekdaySymbols: [String] {
        let s = cal.veryShortStandaloneWeekdaySymbols
        return Array(s[(cal.firstWeekday - 1)...] + s[..<(cal.firstWeekday - 1)])
    }

    /// The month's days in six week rows, so both months stand the same height.
    private var days: [Date?] {
        let first = cal.dateInterval(of: .month, for: month)!.start
        let count = cal.range(of: .day, in: .month, for: first)!.count
        let lead = (cal.component(.weekday, from: first) - cal.firstWeekday + 7) % 7
        var cells: [Date?] = Array(repeating: nil, count: lead)
        cells += (0..<count).map { cal.date(byAdding: .day, value: $0, to: first)! }
        while cells.count < 42 { cells.append(nil) }
        return cells
    }
}

/// The panel's smaller switch, 30 by 18, label first.
private struct PanelSwitchStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button { configuration.isOn.toggle() } label: {
            HStack(spacing: 8) {
                configuration.label
                Capsule()
                    .fill(configuration.isOn ? Palette.accentFill : Palette.bar)
                    .frame(width: 30, height: 18)
                    .overlay(alignment: configuration.isOn ? .trailing : .leading) {
                        Circle().fill(.white).shadow(color: .black.opacity(0.25), radius: 1, y: 1).padding(2)
                    }
                    .animation(.snappy(duration: 0.18), value: configuration.isOn)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isToggle)
        .accessibilityValue(configuration.isOn ? "On" : "Off")
    }
}
