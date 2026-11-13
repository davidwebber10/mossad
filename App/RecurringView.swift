import AppKit
import MossadCore
import SwiftUI

/// Meetings › Recurring in one of two modes, as Meetings has. List: every recurring meeting on the left by the
/// weekday it meets on (its time, the next date, how many meetings, the open points), and on the right one
/// recurring meeting's page, laid out as a meeting's page. Calendar: one typical week of them; a click opens the
/// page full-pane with a Back bar, as Meetings' calendar opens a meeting.
struct RecurringView: View {
    @EnvironmentObject var controller: AppController
    @ObservedObject var model: SeriesModel
    @ObservedObject var filters: SeriesFilterModel
    @AppStorage("recurringMode") private var savedMode = MeetingsView.Mode.split
    /// A preview's mode, kept out of the owner's saved choice.
    @State private var previewMode: MeetingsView.Mode?
    private var mode: MeetingsView.Mode { previewMode ?? savedMode }
    /// The series opened full-pane from Calendar mode.
    @State private var opened: String?
    /// The pane that Back or Forward opens once the mode it asked for is in place; `.some(nil)` is the calendar.
    @State private var restoringPane: String??
    @State private var searchOpen = false
    @State private var searchFocus = 0

    private static let searchPrompt = "Search titles, people, transcripts"

    /// The list search: its text is the model's, so it lasts as long as the filter does.
    private var search: Binding<ListSearchState> {
        Binding(get: { ListSearchState(query: filters.query, isOpen: searchOpen, focusTick: searchFocus) },
                set: { s in
                    if filters.query != s.query { filters.query = s.query }
                    searchOpen = s.isOpen
                    searchFocus = s.focusTick
                })
    }

    private var openedSeries: MeetingSeries? { opened.flatMap { model.series($0) } }

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
                let visible = filters.visible(all)
                let entries = visible.map { SeriesWeek.Entry($0, seconds: filters.lengths[$0.id]) }
                switch mode {
                case .split: splitBody(all: all, visible: visible, entries: entries)
                case .calendar:
                    DetailColumn { toolbar(shownID: nil) } content: {
                        if let s = openedSeries {
                            VStack(spacing: 0) {
                                PaneBackBar(crumbs: ["Recurring"], title: s.title) { opened = nil }
                                page(s)
                            }
                        } else {
                            VStack(spacing: 0) {
                                SeriesFilterChips(filters: filters)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.leading, Chrome.toolbarInsets.leading).padding(.trailing, Chrome.toolbarInsets.trailing)
                                    .padding(.bottom, Space.s)
                                if visible.isEmpty {
                                    nothing.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top).padding(.top, Space.l)
                                } else {
                                    SeriesWeekCalendar(series: visible, entries: entries, selected: model.selected) { id in
                                        controller.navigation.jumpNext()
                                        model.selected = id
                                        opened = id
                                    }
                                }
                            }
                        }
                    }
                    .navigationPart(.recurring, .init(page: "calendar", item: openedSeries?.id), restore: restore)
                }
            }
        }
        .task(id: controller.meetingsVersion) { controller.refreshSeries() }
        .onAppear {
            filters.attach(controller)
            // Development hook for screenshots: MOSSAD_RECURRING_MODE=list|calendar picks the mode.
            if DevHooks.preview, let m = ProcessInfo.processInfo.environment["MOSSAD_RECURRING_MODE"] {
                previewMode = m.lowercased() == "calendar" ? .calendar : .split
            }
        }
        .onChange(of: mode) { _, _ in
            // Back or Forward to the other mode opens its pane here, after the change; any other change closes it.
            opened = restoringPane ?? nil
            restoringPane = nil
            filters.isOpen = false
        }
        // The flyout belongs to this page's button; it must not come back by itself with the page.
        .onDisappear { filters.isOpen = false }
        .task {
            // The points are written by Chat, the MCP, and the phone too.
            while !Task.isCancelled {
                controller.series.reload(controller.paths)
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }

    @ViewBuilder
    private func splitBody(all: [MeetingSeries], visible: [MeetingSeries], entries: [SeriesWeek.Entry]) -> some View {
        // Development hook for screenshots: MOSSAD_RECURRING_SERIES names the series to open.
        let preview = DevHooks.preview ? ProcessInfo.processInfo.environment["MOSSAD_RECURRING_SERIES"] : nil
        // The page shows a series of the list: the selected one while it is in the list (or while Back or a link
        // asks for it and the list is still answering), else the first one.
        let days = SeriesWeek.days(entries)
        let selected = model.series(model.selected) ?? preview.flatMap { t in all.first { $0.title == t } }
        let shownID = SeriesShown.pick(selected: selected?.id, asked: model.asked, visible: days.flatMap(\.ids), all: all.map(\.id))
        let shown = shownID.flatMap { id in all.first { $0.id == id } }
        HStack(spacing: 0) {
            ListColumn("Recurring", widthKey: "recurring", search: search, searchPrompt: Self.searchPrompt) {
                SeriesFilterButton(filters: filters)
            } content: {
                SeriesFilterChips(filters: filters)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10).padding(.top, 2).padding(.bottom, Space.xs)
                if visible.isEmpty {
                    nothing.padding(.horizontal, 14).padding(.top, Space.m)
                } else {
                    let byID = Dictionary(visible.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
                    let schedules = Dictionary(entries.map { ($0.id, $0.schedule) }, uniquingKeysWith: { a, _ in a })
                    SeriesList(days: days, series: byID, schedules: schedules, book: model.book,
                               places: filters.isSearching ? filters.places : [:],
                               selection: Binding(get: { shown?.id }, set: { model.selected = $0 }))
                }
            }
            DetailColumn { toolbar(shownID: shown?.id) } content: {
                if let shown {
                    page(shown)
                } else {
                    // Nothing in the list: the page says so too, and shows no series that the list hides.
                    Color.clear
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .navigationPart(.recurring, .init(item: shown?.id), restore: restore)
    }

    private func page(_ s: MeetingSeries) -> some View {
        RecurringPage(series: s)
            // A key that stays while the series lives, so a point in edit is not lost when the id moves.
            .id(s.meetings.last.map { "call:\($0.id)" } ?? s.id)
    }

    /// Calendar mode has no list column: its search and filter sit at the start of the toolbar row instead.
    private var calendarShown: Bool { mode == .calendar && openedSeries == nil }

    /// The search and the filter in Calendar mode, then List or Calendar at the end, where Meetings has it.
    private func toolbar(shownID: String?) -> some View {
        PageToolbar(search: calendarShown ? search : nil, searchPrompt: Self.searchPrompt) {
            if calendarShown { SeriesFilterButton(filters: filters, edge: .bottom) }
        } trailing: {
            ModePicker(mode: Binding(get: { mode }, set: { previewMode = nil; savedMode = $0 }))
        }
    }

    private var nothing: some View {
        Text(nothingText)
            .font(.system(size: 13)).foregroundStyle(Palette.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var nothingText: String {
        let query = filters.query.trimmingCharacters(in: .whitespaces)
        if query.isEmpty { return "No recurring meetings match these filters." }
        return filters.isActive ? "No recurring meetings match “\(query)” with these filters." : "No recurring meetings match “\(query)”."
    }

    /// Back or Forward: the mode, and in Calendar mode the series open full-pane. The controller sets the rest.
    private func restore(_ p: NavigationPlace) {
        let wanted: MeetingsView.Mode = p.page == "calendar" ? .calendar : .split
        let pane = wanted == .calendar ? p.item.flatMap { model.series($0)?.id ?? $0 } : nil
        guard wanted != mode else { opened = pane; return }
        restoringPane = .some(pane)
        if previewMode != nil { previewMode = wanted } else { savedMode = wanted }
    }
}

// MARK: The list

/// The list by weekday, under the Meetings list's day headers. A series that meets on several weekdays has a row in
/// each; all of its rows show selected. The arrow keys go row by row across the groups.
private struct SeriesList: View {
    @EnvironmentObject var controller: AppController
    let days: [SeriesWeek.Day]
    let series: [String: MeetingSeries]
    let schedules: [String: SeriesSchedule]
    let book: NextTimeBook
    /// Why each series is in a searched list; empty with no search.
    let places: [String: SeriesListSearch.Match]
    @Binding var selection: String?
    @Environment(\.navigation) private var navigation
    @FocusState private var focused: Bool
    /// The row the arrow keys move from: one series can have a row in several days.
    @State private var cursor: Row?

    struct Row: Hashable {
        let day: Int
        let id: String
        var key: String { "\(day):\(id)" }
    }

    private var rows: [Row] { days.flatMap { d in d.ids.map { Row(day: d.id, id: $0) } } }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    ForEach(Array(days.enumerated()), id: \.element.id) { i, day in
                        GroupHeader(title: day.title, first: i == 0)
                        ForEach(day.ids, id: \.self) { id in
                            if let s = series[id] {
                                let row = Row(day: day.id, id: id)
                                SeriesRow(series: s, schedule: schedules[id], inDay: day.weekday != nil, open: book.points(of: s).open.count,
                                          selected: selection == id, place: places[id]) {
                                    if selection != id { navigation?.jumpNext() }
                                    selection = id
                                    cursor = row
                                    focused = true
                                }
                                .id(row.key)
                            }
                        }
                    }
                }
                .padding(.leading, 4).padding(.trailing, Space.s).padding(.bottom, Space.m)
            }
            .scrollContentBackground(.hidden)
            .focusable()
            .focused($focused)
            .focusEffectDisabled()
            .onKeyPress(.downArrow) { move(1, proxy) }
            .onKeyPress(.upArrow) { move(-1, proxy) }
            // Return or Down Arrow in the search field goes to the rows.
            .onChange(of: controller.listFocusRequest) { _, _ in focused = true }
        }
    }

    private func move(_ by: Int, _ proxy: ScrollViewProxy) -> KeyPress.Result {
        let rows = rows
        guard !rows.isEmpty else { return .ignored }
        // From the row the keys or a click left, else from the first row of the selected series.
        let from = cursor.flatMap { c in c.id == selection ? rows.firstIndex(of: c) : nil } ?? rows.firstIndex { $0.id == selection }
        let index = from.map { min(max($0 + by, 0), rows.count - 1) } ?? 0
        cursor = rows[index]
        selection = rows[index].id
        proxy.scrollTo(rows[index].key)
        return .handled
    }
}

/// A recurring meeting in the list: its title and open points, then the cadence, the next date, and the count. In a
/// search, the place that shows why it matched comes under it; a place in a meeting opens that meeting there.
private struct SeriesRow: View {
    @EnvironmentObject var controller: AppController
    let series: MeetingSeries
    let schedule: SeriesSchedule?
    /// Under a weekday, which says the day: the row says the time and a rhythm that is not every week.
    let inDay: Bool
    let open: Int
    let selected: Bool
    var place: SeriesListSearch.Match?
    let select: () -> Void
    @State private var hovering = false

    private var title: AttributedString {
        guard let match = place?.match, match.title.text == series.title else { return AttributedString(series.title) }
        return match.title.boldMatches(size: 13)
    }

    var body: some View {
        // The place is a button of its own beside the row's, not inside it, so its click opens the meeting.
        VStack(alignment: .leading, spacing: 3) {
            Button(action: select) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(title)
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
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(selected ? .isSelected : [])
            if let place, place.match.context != nil { placeLine(place) }
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(selected ? Palette.selection : hovering ? Palette.fill.opacity(0.5) : .clear,
                    in: RoundedRectangle(cornerRadius: Radius.row, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: Radius.row, style: .continuous))
        // The padding around the row's button selects too: the whole row is one target, as before the place line.
        .onTapGesture(perform: select)
        .onHover { hovering = $0 }
    }

    /// The line under the row. One in a meeting is a link to that meeting, at its time when it has one.
    @ViewBuilder
    private func placeLine(_ place: SeriesListSearch.Match) -> some View {
        if let id = place.meetingID {
            Button {
                // The series of this line becomes the place to come back to, then the meeting opens as one step.
                controller.series.selected = series.id
                controller.navigation.report(.recurring, .init(item: series.id))
                controller.navigation.recordNow()
                if let time = place.match.time { controller.showMoment(id, at: time) } else { controller.openMeeting(id) }
            } label: {
                ListMatchLine(match: place.match).multilineTextAlignment(.leading).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(place.match.time == nil ? "Open this meeting" : "Open this meeting at this moment")
        } else {
            ListMatchLine(match: place.match)
        }
    }

    /// The row's short day: "Today", "Tomorrow", the weekday inside a week, else "Tue, Nov 17". The headers keep
    /// the long form; the row has one line.
    private static func shortDay(_ date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) || calendar.isDateInTomorrow(date) { return UpcomingHeader.day(date) }
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: Date()), to: calendar.startOfDay(for: date)).day ?? 0
        return days < 7 ? date.formatted(.dateTime.weekday(.wide)) : date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
    }

    /// Under a weekday: "10:00 AM · Every 2 weeks · Next: Tue · 12 meetings". With no fixed day: "About every 10 days ·
    /// Next: Tue, Nov 17 · 4 meetings". A time that is not known is left out.
    private var subtitle: String {
        var parts: [String] = []
        if inDay, let schedule {
            if let h = schedule.hour, let m = schedule.minute { parts.append(clockTime(h, m)) }
            if let note = schedule.note { parts.append(note) }
        } else if let note = schedule?.note {
            parts.append(note)
        } else if let c = series.cadence {
            parts.append(c.text(time: clockTime))
        } else if series.recurringInCalendar {
            parts.append("Repeats")
        }
        if let next = series.next { parts.append("Next: \(Self.shortDay(next.start))") }
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
