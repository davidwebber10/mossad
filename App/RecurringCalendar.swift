import MossadCore
import SwiftUI

/// Recurring's Calendar mode: one typical week, not this week. Monday to Friday, and a weekend day only when a
/// series meets then; the hours on the side, as Meetings' week. Each series is a block at its usual time with its
/// usual length; blocks that overlap sit side by side (`SeriesWeek.blocks`). Today's column is marked. A series
/// with no fixed day or no known time is in a quiet strip under the grid.
struct SeriesWeekCalendar: View {
    let series: [MeetingSeries]
    let entries: [SeriesWeek.Entry]
    /// The series whose page was open last, so the way back finds it.
    let selected: String?
    let open: (String) -> Void
    @State private var hovered: String?
    @State private var position = ScrollPosition()

    private let hour: CGFloat = 60
    private let gutter: CGFloat = 44
    private var calendar: Calendar { .current }

    var body: some View {
        let columns = SeriesWeek.columns(entries)
        let blocks = SeriesWeek.blocks(entries)
        let unplaced = SeriesWeek.unplaced(entries)
        let byID = Dictionary(series.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let schedules = Dictionary(entries.map { ($0.id, $0.schedule) }, uniquingKeysWith: { a, _ in a })
        let today = calendar.component(.weekday, from: Date())
        VStack(spacing: 0) {
            header(columns, today: today)
            ScrollView {
                GeometryReader { g in
                    let width = (g.size.width - gutter - 12) / CGFloat(columns.count)
                    ZStack(alignment: .topLeading) {
                        if let i = columns.firstIndex(of: today) {
                            Rectangle().fill(Palette.fill.opacity(0.45))
                                .frame(width: width, height: hour * 24)
                                .offset(x: gutter + CGFloat(i) * width)
                                .allowsHitTesting(false)
                        }
                        HourLines(hour: hour, gutter: gutter, columns: columns.count, columnWidth: width)
                        ForEach(blocks, id: \.self) { b in
                            if let i = columns.firstIndex(of: b.weekday), let s = byID[b.id] {
                                block(b, series: s, schedule: schedules[b.id], x: gutter + CGFloat(i) * width, width: width)
                            }
                        }
                        if let i = columns.firstIndex(of: today) {
                            NowLine().offset(x: gutter + CGFloat(i) * width, y: 0).frame(width: width)
                        }
                    }
                }
                .frame(height: hour * 24)
            }
            .scrollPosition($position)
            .onAppear { position.scrollTo(y: top(blocks)) }
            if !unplaced.isEmpty {
                strip(unplaced, byID: byID)
            }
        }
        // The page gutter, as Meetings' calendar pads it; the grid keeps 12 pt of it for the scroller.
        .padding(.leading, Detail.gutter).padding(.trailing, Detail.gutter - 12)
    }

    /// A little above 8 AM, or above the first block when one starts earlier.
    private func top(_ blocks: [SeriesWeek.Block]) -> CGFloat {
        let first = min(8 * 60, blocks.map(\.start).min() ?? 8 * 60)
        return max(0, hour * CGFloat(first / 60) - 10)
    }

    /// "MON", "TUE": weekdays only, with no dates, since this is a typical week. Today's in the accent.
    private func header(_ columns: [Int], today: Int) -> some View {
        HStack(spacing: 0) {
            Color.clear.frame(width: gutter, height: 1)
            ForEach(columns, id: \.self) { d in
                Text(calendar.shortWeekdaySymbols[d - 1])
                    .textRole(.label)
                    .foregroundStyle(d == today ? Palette.accent : Palette.tertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10).padding(.bottom, Space.s)
                    .hairline()
                    .accessibilityLabel(calendar.weekdaySymbols[d - 1] + (d == today ? ", today" : ""))
            }
            Color.clear.frame(width: 12, height: 1)
        }
        .padding(.top, Space.s)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func block(_ b: SeriesWeek.Block, series s: MeetingSeries, schedule: SeriesSchedule?, x: CGFloat, width: CGFloat) -> some View {
        let height = max(20, CGFloat(b.end - b.start) * hour / 60)
        let inset: CGFloat = 4
        let slot = (width - inset * 2) / CGFloat(max(b.columns, 1))
        let active = hovered == b.id || selected == b.id
        let skips = schedule.flatMap { SeriesWeek.meetsThisWeek(s, schedule: $0, now: Date(), calendar: calendar) } == false
        let note = [schedule.flatMap(quietNote), skips ? "not this week" : nil].compactMap { $0 }.joined(separator: " · ")
        return Button { open(b.id) } label: {
            VStack(alignment: .leading, spacing: 0) {
                Text(s.title).font(.system(size: 11.5, weight: .semibold)).foregroundStyle(Palette.ink).lineLimit(height > 44 ? 2 : 1)
                if height > 28 {
                    Text(note.isEmpty ? clockTime(b.start / 60, b.start % 60) : note)
                        .font(.system(size: 10.5)).foregroundStyle(Palette.secondary).lineLimit(1)
                }
            }
            .lineSpacing(1)
            .padding(.leading, 8).padding(.trailing, 7).padding(.vertical, 3)
            .frame(width: slot - 2, height: height - 1, alignment: .topLeading)
            .clipped()
            .background(active ? Palette.selection : Palette.fill, in: RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
            .opacity(skips ? 0.6 : 1)
            .contentShape(RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
        }
        .buttonStyle(.plain)
        .offset(x: x + inset + slot * CGFloat(b.column), y: CGFloat(b.start) * hour / 60)
        .onHover { hovered = $0 ? b.id : (hovered == b.id ? nil : hovered) }
        .help([s.title, clockTime(b.start / 60, b.start % 60), note].filter { !$0.isEmpty }.joined(separator: " · "))
        .accessibilityLabel("\(s.title), \(calendar.weekdaySymbols[b.weekday - 1]) \(clockTime(b.start / 60, b.start % 60))\(note.isEmpty ? "" : ", \(note)")")
    }

    /// The series the grid cannot place: no fixed day, or a day with no known time. Each opens its page.
    private func strip(_ entries: [SeriesWeek.Entry], byID: [String: MeetingSeries]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("No fixed day or time").textRole(.label).foregroundStyle(Palette.tertiary)
            FlowLayout(spacing: 6) {
                ForEach(entries, id: \.id) { e in
                    if byID[e.id] != nil {
                        Button { open(e.id) } label: {
                            HStack(spacing: 6) {
                                Text(e.title).font(.system(size: 12, weight: .medium)).foregroundStyle(Palette.ink).lineLimit(1)
                                if let words = stripNote(e.schedule) {
                                    Text(words).font(.system(size: 11)).foregroundStyle(Palette.tertiary).lineLimit(1)
                                }
                            }
                            .padding(.horizontal, 9).frame(minHeight: 24)
                            .background(selected == e.id ? Palette.selection : Palette.fill, in: Capsule())
                            .contentShape(Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.leading, gutter).padding(.trailing, 12).padding(.vertical, Space.s)
        .overlay(alignment: .top) { Hairline() }
    }

    /// "monthly", "Tue, time not known".
    private func stripNote(_ s: SeriesSchedule) -> String? {
        if s.hasFixedDay {
            let days = s.weekdays.map { calendar.shortWeekdaySymbols[$0 - 1] }.joined(separator: ", ")
            return "\(days), time not known"
        }
        return quietNote(s)
    }

    /// "every 2 weeks", "monthly" in lower case as a quiet label; the days of the week ("Mon, Thu") keep their capitals.
    private func quietNote(_ s: SeriesSchedule) -> String? {
        guard let note = s.note else { return nil }
        return s.rhythm == .weekly ? note : note.lowercased()
    }
}
