import AppKit
import Combine
import Foundation
import MossadCore

/// The Recurring list's search and filter: the search text, what the owner chose, and what the series offer. One
/// for the app's life, as the Meetings filter.
///
/// Each series' row is made from the Meetings filter's rows of its meetings, off the main actor, when the series,
/// those rows, the tasks, or a review change. The search reads the palette's index for the meetings (as the Meetings
/// search does) and each series' own words, off the main actor. The choices and their counts are one pass over the
/// rows, also off the main actor.
@MainActor
final class SeriesFilterModel: ObservableObject {
    @Published var filter = SeriesFilter() {
        didSet { if filter != oldValue { count() } }
    }
    @Published private(set) var facets = SeriesFacets()
    /// The filter that `facets` answers, so the list never shows one filter's series under another's chips.
    @Published private(set) var answered = SeriesFilter()
    @Published var isOpen = false {
        didSet { if oldValue, !isOpen { gate.closed(at: Date()) } }
    }
    @Published var query = "" {
        didSet { if query != oldValue { search(debounce: !oldValue.isEmpty) } }
    }
    /// The series the search text matches; nil while it is empty, when every series matches.
    @Published private(set) var found: Set<String>?
    /// Why each found series matched: the place under its row.
    @Published private(set) var places: [String: SeriesListSearch.Match] = [:]

    private var gate = MeetingFilterFlyoutGate()
    private var day = MeetingFilterDay()
    private weak var controller: AppController?
    private var observers: [AnyCancellable] = []
    private var rows: [SeriesFilterRow] = []
    private var searchRows: [SeriesSearchRow] = []
    private var reading: Task<Void, Never>?
    private var readAgain = false
    private var counting: Task<Void, Never>?
    private var searching: Task<Void, Never>?

    var isActive: Bool { !filter.isEmpty }
    var isSearching: Bool { found != nil }

    /// The series that the search text and the filter leave, in the catalog's order.
    func visible(_ all: [MeetingSeries]) -> [MeetingSeries] {
        let kept = answered.isEmpty ? nil : facets.filterMatches
        guard found != nil || kept != nil else { return all }
        return all.filter { (found?.contains($0.id) ?? true) && (kept?.contains($0.id) ?? true) }
    }

    func attach(_ controller: AppController) {
        guard self.controller == nil else { return }
        self.controller = controller
        observers = [
            controller.series.$all.dropFirst().receive(on: RunLoop.main)
                .sink { [weak self] _ in MainActor.assumeIsolated { self?.read() } },
            controller.meetingFilter.$rows.dropFirst().receive(on: RunLoop.main)
                .sink { [weak self] _ in MainActor.assumeIsolated { self?.read() } },
            controller.$commitmentsVersion.dropFirst().receive(on: RunLoop.main)
                .sink { [weak self] _ in MainActor.assumeIsolated { self?.read() } },
            // The search runs again on each new index: the first one, and a meeting that changed.
            controller.search.$version.dropFirst().receive(on: RunLoop.main)
                .sink { [weak self] _ in
                    MainActor.assumeIsolated {
                        guard let self, !self.query.isEmpty else { return }
                        self.search(debounce: false)
                    }
                },
        ]
        let center = NotificationCenter.default
        for name in [Notification.Name.NSCalendarDayChanged, .NSSystemTimeZoneDidChange] {
            observers.append(center.publisher(for: name).receive(on: RunLoop.main)
                .sink { [weak self] _ in MainActor.assumeIsolated { self?.countIfNewDay() } })
        }
        observers.append(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didWakeNotification).receive(on: RunLoop.main)
            .sink { [weak self] _ in MainActor.assumeIsolated { self?.countIfNewDay() } })
        // The Meetings filter reads every meeting's row; the Recurring page may come first.
        if controller.meetingFilter.rows.isEmpty { controller.meetingFilter.read() }
        read()
        applyPreview()
    }

    private func countIfNewDay() {
        if day.isStale(now: Date(), calendar: .current) { count() }
    }

    func clear() { filter = SeriesFilter() }

    func toggleOpen() {
        if !isOpen, !gate.mayOpen(at: Date()) { return }
        isOpen.toggle()
        if isOpen { count() }
    }

    // MARK: Rows

    /// Makes the rows again. A call that arrives while a read runs is folded into one more read after it.
    func read() {
        guard let controller else { return }
        guard reading == nil else { readAgain = true; return }
        let series = controller.series.all, meetingRows = controller.meetingFilter.rows, records = controller.meetings
        let profiles = controller.library.profiles, store = controller.library.identity?.people, owner = controller.ownerName
        let paths = controller.paths
        reading = Task(priority: .utility) {
            let made = await Self.rows(series, meetingRows: meetingRows, records: records, profiles: profiles, store: store, owner: owner, paths: paths)
            reading = nil
            if made.rows != rows || made.search != searchRows {
                rows = made.rows
                searchRows = made.search
                count()
                if !query.isEmpty { search(debounce: false) }
            }
            if readAgain {
                readAgain = false
                read()
            }
        }
    }

    @concurrent
    nonisolated private static func rows(_ series: [MeetingSeries], meetingRows: [MeetingFilterRow], records: [CallRecord], profiles: [VoiceProfile],
                                         store: PeopleStore?, owner: String, paths: Paths) async -> (rows: [SeriesFilterRow], search: [SeriesSearchRow]) {
        let people = MeetingFilterPeople(profiles: profiles, store: store, owner: owner)
        let byID = Dictionary(records.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let commitments = CommitmentBook.peek(in: paths.commitments)?.items
        let identity = OwnerIdentity.read(name: owner, paths: paths)
        var open: [String: Bool] = [:]
        for s in series { open[s.id] = SeriesFilterRow.openItems(series: s, records: byID, commitments: commitments, owner: identity) }
        let rows = SeriesFilterRow.rows(series, meetings: meetingRows, people: people, openItems: open)
        let directory = PersonDirectory(profiles: profiles, people: store?.people)
        let search = zip(series, rows).map { s, row in
            SeriesSearchRow(series: s, records: byID, people: row.people, directory: directory, cadence: s.cadence?.text(time: clockTime))
        }
        return (rows, search)
    }

    // MARK: Search

    /// The series for the newest text, a moment after the last key press; an answer for older text is dropped.
    private func search(debounce: Bool) {
        searching?.cancel()
        let query = query
        guard SearchIndex.isSearch(query), let controller else {
            if found != nil { found = nil }
            if !places.isEmpty { places = [:] }
            count()
            return
        }
        let rows = searchRows
        searching = Task {
            if debounce { try? await Task.sleep(for: .milliseconds(120)) }
            guard !Task.isCancelled else { return }
            let meetings = await controller.search.listMatches(query) ?? [:]
            let made = await Self.match(rows, query: query, meetings: meetings)
            guard !Task.isCancelled, query == self.query else { return }
            let ids = Set(made.keys)
            if places != made { places = made }
            if found != ids {
                found = ids
                count()
            }
        }
    }

    @concurrent
    nonisolated private static func match(_ rows: [SeriesSearchRow], query: String, meetings: [String: ListMatch]) async -> [String: SeriesListSearch.Match] {
        SeriesListSearch.matches(rows, query: query, meetings: meetings)
    }

    // MARK: Counts

    private func count() {
        counting?.cancel()
        let rows = rows, filter = filter, within = found, now = Date(), calendar = Calendar.current
        counting = Task {
            let made = await Self.facets(rows, filter, within, now: now, calendar: calendar)
            guard !Task.isCancelled else { return }
            if !facets.isSame(as: made) { facets = made }
            if answered != filter { answered = filter }
            day = MeetingFilterDay(calendar: calendar)
            day.counted(at: now)
        }
    }

    @concurrent
    nonisolated private static func facets(_ rows: [SeriesFilterRow], _ filter: SeriesFilter, _ within: Set<String>?, now: Date,
                                           calendar: Calendar) async -> SeriesFacets {
        SeriesFacets(rows: rows, filter: filter, within: within, now: now, calendar: calendar)
    }

    /// A chip's words; a person by the name they have now.
    func label(_ choice: SeriesFilter.Active) -> String {
        if case .person(let who) = choice, let now = facets.people.first(where: { $0.who == who }) { return now.who.name }
        return choice.label
    }

    // MARK: Screenshots

    /// Development hooks for a `--ui-preview`: `MOSSAD_SERIES_FILTER` sets choices ("person:Sam Carter;cadence:weekly;
    /// next:week;last:last30;length:to30;size:small;value:high;platform:zoom;has:open"), `MOSSAD_SERIES_QUERY` types
    /// into the search, and `MOSSAD_SERIES_FILTER_OPEN` opens the flyout a moment after the window.
    private func applyPreview() {
        guard DevHooks.preview else { return }
        let env = ProcessInfo.processInfo.environment
        if let text = env["MOSSAD_SERIES_FILTER"] {
            var made = SeriesFilter()
            for part in text.split(separator: ";") {
                let pair = part.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
                guard pair.count == 2, let choice = Self.choice(pair[0], pair[1]) else { continue }
                made.toggle(choice)
            }
            filter = made
        }
        if let q = env["MOSSAD_SERIES_QUERY"] { query = q }
        if env["MOSSAD_SERIES_FILTER_OPEN"] != nil {
            Task {
                try? await Task.sleep(for: .seconds(2))
                toggleOpen()
            }
        }
    }

    private static func choice(_ group: String, _ value: String) -> SeriesFilter.Active? {
        let cadences: [String: SeriesFilter.Cadence] = ["weekly": .weekly, "two": .everyTwoWeeks, "monthly": .monthly, "other": .other]
        let nexts: [String: SeriesFilter.Next] = ["week": .thisWeek, "two": .twoWeeks, "none": .noneKnown]
        let lasts: [String: SeriesFilter.LastMet] = ["last7": .last7, "last30": .last30, "last90": .last90, "earlier": .earlier]
        let lengths: [String: MeetingFilter.Length] = ["under15": .under15, "to30": .to30, "to60": .to60, "over60": .over60]
        let sizes: [String: MeetingFilter.Size] = ["alone": .alone, "1:1": .oneOnOne, "small": .small, "large": .large, "unknown": .unknown]
        let values: [String: MeetingFilter.Value] = ["high": .high, "medium": .medium, "low": .low, "none": .notRated]
        switch group {
        case "person": return .person(.init(name: value))
        case "cadence": return cadences[value].map { .cadence($0) }
        case "next": return nexts[value].map { .next($0) }
        case "last": return lasts[value].map { .lastMet($0) }
        case "length": return lengths[value].map { .length($0) }
        case "size": return sizes[value].map { .size($0) }
        case "value": return values[value].map { .value($0) }
        case "platform": return Platform(rawValue: value).map { .platform($0) }
        case "has": return value == "open" ? .openItems : nil
        default: return nil
        }
    }
}
