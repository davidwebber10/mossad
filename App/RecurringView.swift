import AppKit
import MossadCore
import SwiftUI

/// Meetings › Recurring: every recurring meeting on the left (its cadence, the next date, how many meetings, the
/// open points), and on the right one recurring meeting's page, laid out as a meeting's page.
struct RecurringView: View {
    @EnvironmentObject var controller: AppController
    @ObservedObject var model: SeriesModel

    var body: some View {
        let all = model.all
        Group {
            if all.isEmpty {
                DetailColumn { PageToolbar(title: "Recurring") {} } content: {
                    if model.loaded {
                        EmptyState(symbol: "repeat", title: "No recurring meetings yet",
                                   message: "A meeting that repeats in your calendar, or that Mossad recorded twice with the same title and nearly the same people, shows here. Each one gets a list of points for next time.")
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
            } else {
                // Development hook for screenshots: MOSSAD_RECURRING_SERIES names the series to open.
                let preview = DevHooks.preview ? ProcessInfo.processInfo.environment["MOSSAD_RECURRING_SERIES"] : nil
                let shown = model.series(model.selected) ?? preview.flatMap { t in all.first { $0.title == t } } ?? all[0]
                HStack(spacing: 0) {
                    ListColumn("Recurring", widthKey: "recurring") {
                        SeriesList(series: all, book: model.book, selection: Binding(get: { shown.id }, set: { model.selected = $0 }))
                    }
                    RecurringPage(series: shown)
                        // A key that stays while the series lives, so a point in edit is not lost when the id moves.
                        .id(shown.meetings.last.map { "call:\($0.id)" } ?? shown.id)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .overlay(alignment: .leading) { Hairline(axis: .vertical) }
                }
                .navigationPart(.recurring, .init(item: shown.id)) { _ in }
            }
        }
        .task(id: controller.meetingsVersion) { controller.refreshSeries() }
        .task {
            // The points are written by Chat, the MCP, and the phone too.
            while !Task.isCancelled {
                controller.series.reload(controller.paths)
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }
}

// MARK: The list

private struct SeriesList: View {
    let series: [MeetingSeries]
    let book: NextTimeBook
    @Binding var selection: String?
    @FocusState private var focused: Bool

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    ForEach(series) { s in
                        SeriesRow(series: s, open: book.points(of: s).open.count, selected: selection == s.id) {
                            selection = s.id
                            focused = true
                        }
                        .id(s.id)
                    }
                }
                .padding(.leading, 4).padding(.trailing, Space.s).padding(.vertical, Space.s)
            }
            .scrollContentBackground(.hidden)
            .focusable()
            .focused($focused)
            .focusEffectDisabled()
            .onKeyPress(.downArrow) { move(1, proxy) }
            .onKeyPress(.upArrow) { move(-1, proxy) }
        }
    }

    private func move(_ by: Int, _ proxy: ScrollViewProxy) -> KeyPress.Result {
        guard !series.isEmpty else { return .ignored }
        let index = series.firstIndex { $0.id == selection }.map { min(max($0 + by, 0), series.count - 1) } ?? 0
        selection = series[index].id
        proxy.scrollTo(series[index].id)
        return .handled
    }
}

/// A recurring meeting in the list: its title and open points, then the cadence, the next date, and the count.
private struct SeriesRow: View {
    let series: MeetingSeries
    let open: Int
    let selected: Bool
    let select: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: select) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(series.title)
                        .font(.system(size: 13, weight: selected ? .semibold : .medium))
                        .foregroundStyle(Palette.ink)
                        .lineLimit(1).truncationMode(.tail)
                    Spacer(minLength: 4)
                    if open > 0 {
                        Text("\(open)")
                            .font(.system(size: 11, weight: .semibold)).monospacedDigit()
                            .foregroundStyle(Palette.accent)
                            .padding(.horizontal, 6).frame(minWidth: 18, minHeight: 16)
                            .background(Palette.accentTint, in: Capsule())
                            .help("\(open) \(open == 1 ? "point" : "points") for next time")
                            .accessibilityLabel("\(open) \(open == 1 ? "point" : "points") for next time")
                    }
                }
                Text(subtitle)
                    .font(.system(size: 11.5)).foregroundStyle(Palette.secondary).lineLimit(1)
            }
            .padding(.horizontal, 10).padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(selected ? Palette.selection : hovering ? Palette.fill.opacity(0.5) : .clear,
                        in: RoundedRectangle(cornerRadius: Radius.row, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: Radius.row, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    /// "Every Tuesday 10:00 · Next Tue · 12 meetings".
    private var subtitle: String {
        var parts: [String] = []
        if let c = series.cadence { parts.append(c.text(time: clockTime)) } else if series.recurringInCalendar { parts.append("Repeats") }
        if let next = series.next { parts.append("Next: \(UpcomingHeader.day(next.start))") }
        let n = series.meetings.count
        parts.append(n == 0 ? "None recorded yet" : "\(n) \(n == 1 ? "meeting" : "meetings")")
        return parts.joined(separator: " · ")
    }
}

/// "10:00 AM" or "10:00", as the owner's clock shows the time.
func clockTime(_ hour: Int, _ minute: Int) -> String {
    let date = Calendar.current.date(bySettingHour: hour, minute: minute, second: 0, of: Date()) ?? Date()
    return date.formatted(date: .omitted, time: .shortened)
}
