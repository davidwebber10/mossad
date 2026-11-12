import AppKit
import MossadCore
import SwiftUI

/// Meetings › Recurring: every recurring meeting on the left (its cadence, the next date, how many meetings, the
/// open points), and on the right one recurring meeting's page, laid out as a meeting's page.
struct RecurringView: View {
    @EnvironmentObject var controller: AppController
    @ObservedObject var model: SeriesModel
    @ObservedObject var filters: SeriesFilterModel
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
                let visible = filters.visible(all)
                // The page shows a series of the list: the selected one while it is in the list (or while Back or a link
                // asks for it and the list is still answering), else the first one.
                let selected = model.series(model.selected) ?? preview.flatMap { t in all.first { $0.title == t } }
                let shownID = SeriesShown.pick(selected: selected?.id, asked: model.asked, visible: visible.map(\.id), all: all.map(\.id))
                let shown = shownID.flatMap { id in all.first { $0.id == id } }
                HStack(spacing: 0) {
                    ListColumn("Recurring", widthKey: "recurring", search: search, searchPrompt: Self.searchPrompt) {
                        SeriesFilterButton(filters: filters)
                    } content: {
                        SeriesFilterChips(filters: filters)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 10).padding(.top, 2).padding(.bottom, Space.xs)
                        if visible.isEmpty {
                            Text(nothingText)
                                .font(.system(size: 13)).foregroundStyle(Palette.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 14).padding(.top, Space.m)
                        } else {
                            SeriesList(series: visible, book: model.book, places: filters.isSearching ? filters.places : [:],
                                       selection: Binding(get: { shown?.id }, set: { model.selected = $0 }))
                        }
                    }
                    Group {
                        if let shown {
                            RecurringPage(series: shown)
                                // A key that stays while the series lives, so a point in edit is not lost when the id moves.
                                .id(shown.meetings.last.map { "call:\($0.id)" } ?? shown.id)
                        } else {
                            // Nothing in the list: the page says so too, and shows no series that the list hides.
                            DetailColumn { PageToolbar(title: "") {} } content: { Color.clear }
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .overlay(alignment: .leading) { Hairline(axis: .vertical) }
                }
                .navigationPart(.recurring, .init(item: shown?.id)) { _ in }
            }
        }
        .task(id: controller.meetingsVersion) { controller.refreshSeries() }
        .onAppear { filters.attach(controller) }
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

    private var nothingText: String {
        let query = filters.query.trimmingCharacters(in: .whitespaces)
        if query.isEmpty { return "No recurring meetings match these filters." }
        return filters.isActive ? "No recurring meetings match “\(query)” with these filters." : "No recurring meetings match “\(query)”."
    }
}

// MARK: The list

private struct SeriesList: View {
    @EnvironmentObject var controller: AppController
    let series: [MeetingSeries]
    let book: NextTimeBook
    /// Why each series is in a searched list; empty with no search.
    let places: [String: SeriesListSearch.Match]
    @Binding var selection: String?
    @Environment(\.navigation) private var navigation
    @FocusState private var focused: Bool

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    ForEach(series) { s in
                        SeriesRow(series: s, open: book.points(of: s).open.count, selected: selection == s.id, place: places[s.id]) {
                            if selection != s.id { navigation?.jumpNext() }
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
            // Return or Down Arrow in the search field goes to the rows.
            .onChange(of: controller.listFocusRequest) { _, _ in focused = true }
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

/// A recurring meeting in the list: its title and open points, then the cadence, the next date, and the count. In a
/// search, the place that shows why it matched comes under it; a place in a meeting opens that meeting there.
private struct SeriesRow: View {
    @EnvironmentObject var controller: AppController
    let series: MeetingSeries
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

    /// "Every Tuesday 10:00 · Next Tue · 12 meetings".
    private var subtitle: String {
        var parts: [String] = []
        if let c = series.cadence { parts.append(c.text(time: clockTime)) } else if series.recurringInCalendar { parts.append("Repeats") }
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
