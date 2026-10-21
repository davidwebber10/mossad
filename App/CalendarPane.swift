import MossadCore
import SwiftUI

/// Which period the calendar shows. Shared by the header controls and the grid.
@MainActor
final class CalendarState: ObservableObject {
    enum Scope: String, CaseIterable { case day = "Day", week = "Week", month = "Month" }

    @AppStorage("calendarScope") var scope = Scope.week { willSet { objectWillChange.send() } }
    @Published var anchor = Date()

    var calendar: Calendar { .current }

    func move(_ by: Int) {
        let component: Calendar.Component = switch scope {
        case .day: .day
        case .week: .weekOfYear
        case .month: .month
        }
        anchor = calendar.date(byAdding: component, value: by, to: anchor) ?? anchor
    }

    var title: String {
        switch scope {
        case .day: anchor.formatted(.dateTime.weekday(.wide).month(.wide).day())
        case .week, .month: anchor.formatted(.dateTime.month(.wide).year())
        }
    }

    /// The days of the week that holds the anchor, starting on the calendar's first weekday.
    var weekDays: [Date] {
        let start = calendar.dateInterval(of: .weekOfYear, for: anchor)?.start ?? calendar.startOfDay(for: anchor)
        return (0..<7).compactMap { calendar.date(byAdding: .day, value: $0, to: start) }
    }
}

struct CalendarControls: View {
    @ObservedObject var state: CalendarState

    var body: some View {
        HStack(spacing: 6) {
            navButton("chevron.left") { state.move(-1) }.accessibilityLabel("Previous")
            Button("Today") { state.anchor = Date() }
                .font(.system(size: 12, weight: .medium)).buttonStyle(.bordered).controlSize(.small)
            navButton("chevron.right") { state.move(1) }.accessibilityLabel("Next")
            Text(state.title).font(.system(size: 13, weight: .semibold)).padding(.leading, 6).fixedSize()
            Picker("Scope", selection: $state.scope) {
                ForEach(CalendarState.Scope.allCases, id: \.self) { Text($0.rawValue) }
            }
            .labelsHidden().fixedSize().controlSize(.small)
        }
    }

    private func navButton(_ symbol: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 11, weight: .semibold)).frame(width: 26, height: 26)
                .background(Theme.field, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

struct CalendarPane: View {
    @ObservedObject var state: CalendarState
    let records: [CallRecord]
    /// Search matches; other calls are dimmed.
    let matches: Set<String>
    @Binding var deleting: CallRecord?
    let open: (CallRecord, String) -> Void

    var body: some View {
        switch state.scope {
        case .week: HourGrid(state: state, days: state.weekDays, records: records, matches: matches, deleting: $deleting, open: open)
        case .day: HourGrid(state: state, days: [state.calendar.startOfDay(for: state.anchor)], records: records, matches: matches, deleting: $deleting, open: open)
        case .month: MonthGrid(state: state, records: records, matches: matches, deleting: $deleting, open: open)
        }
    }
}

// MARK: Week and Day

private struct HourGrid: View {
    @ObservedObject var state: CalendarState
    let days: [Date]
    let records: [CallRecord]
    let matches: Set<String>
    @Binding var deleting: CallRecord?
    let open: (CallRecord, String) -> Void
    @State private var hovered: String?
    @State private var card: String?
    @State private var hoverTask: Task<Void, Never>?
    @State private var position = ScrollPosition()

    private let hour: CGFloat = 60
    private let gutter: CGFloat = 52
    private var isDay: Bool { days.count == 1 }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                    GeometryReader { g in
                        let columnWidth = (g.size.width - gutter - 12) / CGFloat(days.count)
                        ZStack(alignment: .topLeading) {
                            grid(columnWidth: columnWidth)
                            ForEach(Array(days.enumerated()), id: \.offset) { i, day in
                                let byID = Dictionary(uniqueKeysWithValues: records.map { ($0.id, $0) })
                                ForEach(CalendarLayout.day(records, on: day, calendar: state.calendar), id: \.id) { item in
                                    if let r = byID[item.id] { event(r, item, x: gutter + CGFloat(i) * columnWidth, width: columnWidth, day: day) }
                                }
                                if state.calendar.isDateInToday(day) { NowLine().offset(x: gutter + CGFloat(i) * columnWidth, y: 0).frame(width: columnWidth) }
                            }
                            if let id = card, let r = records.first(where: { $0.id == id }) {
                                hoverCard(r, in: g.size, columnWidth: columnWidth)
                            }
                        }
                    }
                    .frame(height: hour * 24)
            }
            .scrollPosition($position)
            .onAppear { position.scrollTo(y: hour * CGFloat(firstHour)) }
            .onChange(of: days) { _, _ in position.scrollTo(y: hour * CGFloat(firstHour)) }
        }
    }

    private var firstHour: Int {
        let starts = records.filter { r in days.contains { state.calendar.isDate(r.start, inSameDayAs: $0) } }.map { state.calendar.component(.hour, from: $0.start) }
        return max(0, (starts.min() ?? 9) - 1)
    }

    @ViewBuilder
    private var header: some View {
        if isDay, let day = days.first {
            let dayRecords = records.filter { state.calendar.isDate($0.start, inSameDayAs: day) }
            let total = dayRecords.reduce(0) { $0 + $1.end.timeIntervalSince($1.start) }
            HStack(spacing: 8) {
                dayLabel(day)
                Text("\(dayRecords.count) \(dayRecords.count == 1 ? "call" : "calls") · \(durationText(total)) recorded")
                    .font(.system(size: 12)).foregroundStyle(.secondary).padding(.leading, 6)
                Spacer()
            }
            .padding(.leading, gutter + 10).padding(.vertical, 8)
        } else {
            HStack(spacing: 0) {
                Color.clear.frame(width: gutter, height: 1)
                ForEach(days, id: \.self) { day in
                    dayLabel(day).frame(maxWidth: .infinity, alignment: .leading).padding(.leading, 8).padding(.vertical, 8)
                        .overlay(alignment: .leading) { Rectangle().fill(Theme.separator).frame(width: 1) }
                }
                Color.clear.frame(width: 12, height: 1)
            }
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func dayLabel(_ day: Date) -> some View {
        let today = state.calendar.isDateInToday(day)
        return HStack(spacing: 6) {
            Text(day.formatted(.dateTime.weekday(.abbreviated)).uppercased())
                .font(.system(size: 11, weight: .semibold)).foregroundStyle(today ? Theme.recording : Color.secondary.opacity(0.7))
            Text("\(state.calendar.component(.day, from: day))")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(today ? .white : .primary)
                .frame(minWidth: 22, minHeight: 22)
                .background(today ? Theme.recording : .clear, in: Circle())
        }
    }

    private func grid(columnWidth: CGFloat) -> some View {
        Canvas { context, size in
            for h in 0...24 {
                let y = CGFloat(h) * hour
                context.fill(Path(CGRect(x: gutter, y: y, width: size.width - gutter, height: 1)), with: .color(Theme.separator))
                if h > 0, h < 24 {
                    let label = Calendar.current.date(bySettingHour: h, minute: 0, second: 0, of: Date())!.formatted(.dateTime.hour())
                    context.draw(Text(label).font(.system(size: 10)).foregroundStyle(.tertiary), at: CGPoint(x: gutter - 8, y: y - 6), anchor: .trailing)
                }
            }
            for i in 0..<days.count {
                context.fill(Path(CGRect(x: gutter + CGFloat(i) * columnWidth, y: 0, width: 1, height: size.height)), with: .color(Theme.separator))
            }
        }
    }

    private func event(_ r: CallRecord, _ item: CalendarItem, x: CGFloat, width: CGFloat, day: Date) -> some View {
        let dayStart = state.calendar.startOfDay(for: day)
        let end = r.status == .recording ? Date() : item.end
        let top = CGFloat(item.start.timeIntervalSince(dayStart) / 60)
        let height = max(18, CGFloat(end.timeIntervalSince(item.start) / 60))
        let inset: CGFloat = isDay ? 6 : 3
        let slot = (width - inset * 2) / CGFloat(max(item.columns, 1))
        let active = hovered == r.id
        return Button { open(r, state.title) } label: {
            eventLabel(r, active: active, height: height)
                .padding(.horizontal, isDay ? 12 : 7).padding(.vertical, isDay ? 7 : 4)
                .frame(width: slot - 2, height: height, alignment: .topLeading)
                .background(active ? Color.accentColor : Theme.surface, in: RoundedRectangle(cornerRadius: isDay ? 9 : 7, style: .continuous))
                .overlay(alignment: .leading) {
                    UnevenRoundedRectangle(topLeadingRadius: 7, bottomLeadingRadius: 7).fill(r.platform.color).frame(width: 3)
                }
                .shadow(color: .black.opacity(active ? 0.2 : 0.12), radius: active ? 8 : 1.5, y: active ? 3 : 1)
        }
        .buttonStyle(.plain)
        .opacity(matches.contains(r.id) ? 1 : 0.3)
        .offset(x: x + inset + slot * CGFloat(item.column), y: top)
        .onHover { inside in hover(r.id, inside) }
        .contextMenu { MeetingMenuItems(record: r, deleting: $deleting) }
    }

    @ViewBuilder
    private func eventLabel(_ r: CallRecord, active: Bool, height: CGFloat) -> some View {
        let meta = r.status == .recording ? "Recording" : [r.lengthText, r.badge.map(badgeWord)].compactMap { $0 }.joined(separator: " · ")
        if isDay {
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(r.title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                        .accessibilityAddTraits(.isHeader)
                    Text("\((r.start..<max(r.end, r.start)).formatted(.interval.hour().minute())) · \(r.platform.displayName)\(r.badge.map { " · " + badgeWord($0) } ?? "")")
                        .font(.system(size: 12)).foregroundStyle(active ? .white.opacity(0.8) : .secondary)
                }
                Spacer()
                if height >= 44 {
                    HStack(spacing: 4) {
                        ForEach(speakerNames(r), id: \.self) { name in
                            Text(name).font(.system(size: 11)).lineLimit(1)
                                .padding(.horizontal, 7).padding(.vertical, 2)
                                .background(active ? Color.white.opacity(0.22) : Theme.field, in: Capsule())
                        }
                    }
                }
            }
            .foregroundStyle(active ? .white : .primary)
        } else {
            VStack(alignment: .leading, spacing: 1) {
                Text(r.title).font(.system(size: 11, weight: .semibold)).lineLimit(height > 30 ? 2 : 1)
                if height > 28 {
                    HStack(spacing: 4) {
                        if r.status == .recording { StatusDot(color: Theme.recording, size: 6, pulsing: true) }
                        Text(meta).font(.system(size: 10)).foregroundStyle(active ? .white.opacity(0.8) : .secondary)
                    }
                }
            }
            .foregroundStyle(active ? .white : .primary)
        }
    }

    /// Speaker names in order of first appearance.
    private func speakerNames(_ r: CallRecord) -> [String] {
        let names = MarkdownWriter.displayNames(r)
        var order: [String] = []
        for u in r.utterances {
            let name = names[u.speakerKey] ?? u.speakerKey
            if !order.contains(name) { order.append(name) }
        }
        return order
    }

    private func badgeWord(_ kind: StatusBadge.Kind) -> String {
        switch kind {
        case .needsNames: "Needs names"
        case .processing: "Processing"
        case .failed: "Failed"
        case .recording: "Recording"
        }
    }

    /// The card shows after the pointer rests 0.5 s, and stays while the pointer is on the event or the card.
    private func hover(_ id: String, _ inside: Bool) {
        hoverTask?.cancel()
        if inside {
            hovered = id
            hoverTask = Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(500))
                if !Task.isCancelled, hovered == id { card = id }
            }
        } else {
            hovered = nil
            hoverTask = Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(200))
                if !Task.isCancelled, hovered == nil { card = nil }
            }
        }
    }

    private func hoverCard(_ r: CallRecord, in size: CGSize, columnWidth: CGFloat) -> some View {
        let dayIndex = days.firstIndex { state.calendar.isDate(r.start, inSameDayAs: $0) } ?? 0
        let top = CGFloat(r.start.timeIntervalSince(state.calendar.startOfDay(for: r.start)) / 60)
        let rightSide = gutter + CGFloat(dayIndex + 1) * columnWidth + 8
        let x = rightSide + 290 > size.width ? gutter + CGFloat(dayIndex) * columnWidth - 298 : rightSide
        let names = Array(Set(r.utterances.map { MarkdownWriter.displayNames(r)[$0.speakerKey] ?? $0.speakerKey })).sorted()
        return VStack(alignment: .leading, spacing: 8) {
            Text(r.title).font(.system(size: 13, weight: .semibold))
            Text("\((r.start..<max(r.end, r.start)).formatted(.interval.hour().minute())) · \(r.lengthText) · \(r.platform.displayName)")
                .foregroundStyle(.secondary)
            if !names.isEmpty {
                FlowLayout(spacing: 4) {
                    ForEach(names, id: \.self) { Text($0).font(.system(size: 11)).padding(.horizontal, 7).padding(.vertical, 2).background(Theme.field, in: Capsule()) }
                }
            }
            if let line = r.headline ?? r.summary.map(firstSentence) {
                Text(line).font(.system(size: 13)).lineSpacing(3)
            }
            HStack {
                if let badge = r.badge { StatusBadge(kind: badge) }
                Spacer()
                Button("Open meeting") { open(r, state.title) }.buttonStyle(.link).fontWeight(.medium)
            }
        }
        .font(.system(size: 12))
        .padding(.horizontal, 14).padding(.vertical, 12)
        .frame(width: 290, alignment: .leading)
        .mossadGlass(cornerRadius: 14)
        .offset(x: max(gutter, x), y: min(top, size.height - 200))
        .onHover { inside in hover(r.id, inside) }
        .onTapGesture { open(r, state.title) }
    }
}

/// The first sentence of a summary, without Markdown, for the hover card.
func firstSentence(_ markdown: String) -> String {
    let plain = markdown.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "### ", with: "")
    let paragraph = plain.split(separator: "\n").first.map(String.init) ?? plain
    if let end = paragraph.range(of: ". ") { return String(paragraph[..<end.lowerBound]) + "." }
    return paragraph
}

private func durationText(_ seconds: TimeInterval) -> String {
    let m = Int(seconds / 60)
    return m >= 60 ? "\(m / 60)h \(m % 60)m" : "\(m)m"
}

private struct NowLine: View {
    var body: some View {
        TimelineView(.everyMinute) { context in
            let minutes = CGFloat(context.date.timeIntervalSince(Calendar.current.startOfDay(for: context.date)) / 60)
            HStack(spacing: 0) {
                Circle().fill(Theme.recording).frame(width: 8, height: 8).offset(x: -4)
                Rectangle().fill(Theme.recording).frame(height: 1.5)
            }
            .offset(y: minutes - 4)
        }
        .allowsHitTesting(false)
    }
}

// MARK: Month

private struct MonthGrid: View {
    @ObservedObject var state: CalendarState
    let records: [CallRecord]
    let matches: Set<String>
    @Binding var deleting: CallRecord?
    let open: (CallRecord, String) -> Void

    var body: some View {
        let cells = CalendarLayout.monthCells(month: state.anchor, calendar: state.calendar)
        let rows = (cells.count + 6) / 7
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                ForEach(cells.prefix(7), id: \.self) { d in
                    Text(d.formatted(.dateTime.weekday(.abbreviated)).uppercased())
                        .font(.system(size: 11, weight: .semibold)).foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity).padding(.top, 8).padding(.bottom, 6)
                }
            }
            Divider()
            Grid(horizontalSpacing: 0, verticalSpacing: 0) {
                ForEach(0..<rows, id: \.self) { row in
                    GridRow {
                        ForEach(Array(cells[(row * 7)..<min(row * 7 + 7, cells.count)]), id: \.self) { day in cell(day) }
                    }
                }
            }
        }
    }

    private func cell(_ day: Date) -> some View {
        let cal = state.calendar
        let inMonth = cal.isDate(day, equalTo: state.anchor, toGranularity: .month)
        let today = cal.isDateInToday(day)
        let items = records.filter { cal.isDate($0.start, inSameDayAs: day) }.sorted { $0.start < $1.start }
        let number = cal.component(.day, from: day) == 1 ? day.formatted(.dateTime.month(.abbreviated).day()) : "\(cal.component(.day, from: day))"
        return VStack(alignment: .leading, spacing: 3) {
            Text(number)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(today ? AnyShapeStyle(.white) : inMonth ? AnyShapeStyle(.primary) : AnyShapeStyle(.tertiary))
                .padding(.horizontal, 6)
                .frame(minWidth: 22, minHeight: 22)
                .background(today ? Theme.recording : .clear, in: Capsule())
                .frame(maxWidth: .infinity)
            ForEach(items.prefix(3), id: \.id) { r in
                MonthItem(record: r) { open(r, state.title) }
                    .opacity(matches.contains(r.id) ? 1 : 0.3)
                    .contextMenu { MeetingMenuItems(record: r, deleting: $deleting) }
            }
            if items.count > 3 {
                Button("+\(items.count - 3) more") {
                    state.anchor = day
                    state.scope = .day
                }
                .buttonStyle(.plain).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary).padding(.leading, 5)
            }
            Spacer(minLength: 0)
        }
        .padding(6)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(inMonth ? Color.clear : Theme.field)
        .overlay(alignment: .trailing) { Rectangle().fill(Theme.separator).frame(width: 1) }
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.separator).frame(height: 1) }
    }
}

private struct MonthItem: View {
    let record: CallRecord
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Group {
                    if record.status == .written {
                        Circle().fill(record.platform.color)
                    } else {
                        Circle().strokeBorder(record.platform.color, lineWidth: 1.5)
                    }
                }
                .frame(width: 7, height: 7)
                Text(time).foregroundStyle(.secondary).monospacedDigit()
                Text(record.title).fontWeight(.medium).lineLimit(1)
                Spacer(minLength: 0)
                if record.status == .recording { StatusDot(color: Theme.recording, size: 6, pulsing: true) }
            }
            .font(.system(size: 11))
            .padding(.horizontal, 5).padding(.vertical, 2)
            .background(hovering ? Theme.hover : .clear, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }

    /// "10am", "2:30pm".
    private var time: String {
        let c = Calendar.current.dateComponents([.hour, .minute], from: record.start)
        let h = (c.hour ?? 0) % 12 == 0 ? 12 : (c.hour ?? 0) % 12
        let suffix = (c.hour ?? 0) < 12 ? "am" : "pm"
        return c.minute == 0 ? "\(h)\(suffix)" : String(format: "%d:%02d%@", h, c.minute ?? 0, suffix)
    }
}
