import AppKit
import Combine
import Foundation
import MossadCore

/// The Meetings filter: what the owner chose, and what the meetings offer. One for the app's life, so the choice
/// lasts as long as the search text does: through a change of page and a closed window, and not into the next
/// launch, where a filter from another day would hide the meeting that was just recorded.
///
/// The rows (one small value per meeting) are read off the main actor when the meetings, the saved people, or a
/// review change. The choices and their counts are one pass over the rows, also off the main actor, for each
/// change of the filter or of the search text.
@MainActor
final class MeetingFilterModel: ObservableObject {
    @Published var filter = MeetingFilter() {
        didSet { if filter != oldValue { count() } }
    }
    /// The choices and counts for `answered`.
    @Published private(set) var facets = MeetingFacets()
    /// The filter that `facets` answers, so the list never shows one filter's meetings under another's chips.
    @Published private(set) var answered = MeetingFilter()
    @Published var isOpen = false {
        didSet { if oldValue, !isOpen { gate.closed(at: Date()) } }
    }
    private var gate = MeetingFilterFlyoutGate()
    /// The day the counts are for: "Today" and "Last 7 days" move with the clock.
    private var day = MeetingFilterDay()
    private var midnight: Task<Void, Never>?

    /// The meetings the filter leaves, whatever the search text (the list meets them with the newest text); nil
    /// while the filter is empty, when every meeting matches.
    var matches: Set<String>? { answered.isEmpty ? nil : facets.filterMatches }
    var isActive: Bool { !filter.isEmpty }

    private weak var controller: AppController?
    private var observers: [AnyCancellable] = []
    private let kept = MeetingFilterRows()
    private let ratings = MeetingRatings()
    private var rows: [MeetingFilterRow] = []
    /// The meetings the search text matches; nil with no text.
    private var within: Set<String>?
    private var reading: Task<Void, Never>?
    private var readAgain = false
    private var counting: Task<Void, Never>?

    /// Follows the controller's meetings, reviews, and search. Meetings settle in bursts while a call is
    /// processed, so their changes wait a moment and go in together.
    func attach(_ controller: AppController) {
        self.controller = controller
        observers = [
            controller.$meetings.debounce(for: .milliseconds(400), scheduler: RunLoop.main)
                .sink { [weak self] _ in MainActor.assumeIsolated { self?.read() } },
            controller.$coachVersion.dropFirst().receive(on: RunLoop.main)
                .sink { [weak self] _ in MainActor.assumeIsolated { self?.read() } },
            controller.$meetingMatches.receive(on: RunLoop.main)
                .sink { [weak self] ids in
                    MainActor.assumeIsolated {
                        guard let self, self.within != ids else { return }
                        self.within = ids
                        self.count()
                    }
                },
        ]
        // A new day, a wake from sleep, or a new time zone can change what "Today" holds.
        let center = NotificationCenter.default
        for name in [Notification.Name.NSCalendarDayChanged, .NSSystemTimeZoneDidChange] {
            observers.append(center.publisher(for: name).receive(on: RunLoop.main)
                .sink { [weak self] _ in MainActor.assumeIsolated { self?.countIfNewDay() } })
        }
        observers.append(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didWakeNotification).receive(on: RunLoop.main)
            .sink { [weak self] _ in MainActor.assumeIsolated { self?.countIfNewDay() } })
        applyPreview()
    }

    private func countIfNewDay() {
        if day.isStale(now: Date(), calendar: .current) { count() }
    }

    /// Counts again at the start of the next day, in case the system's notice of it does not come.
    private func waitForMidnight() {
        midnight?.cancel()
        guard let next = day.nextChange else { return }
        midnight = Task { [weak self] in
            try? await Task.sleep(for: .seconds(max(1, next.timeIntervalSinceNow + 1)))
            guard !Task.isCancelled else { return }
            self?.countIfNewDay()
        }
    }

    func clear() { filter = MeetingFilter() }

    /// Opens or closes the flyout. The saved people can change without a signal (a new name in People), so an
    /// open reads them again, and the date choices are counted for this moment.
    func toggleOpen() {
        if !isOpen, !gate.mayOpen(at: Date()) { return }
        isOpen.toggle()
        if isOpen {
            count()
            read()
        }
    }

    /// Reads the rows again. A call that arrives while a read runs is folded into one more read after it.
    func read() {
        guard let controller else { return }
        guard reading == nil else { readAgain = true; return }
        let records = controller.meetings, profiles = controller.library.profiles, store = controller.library.identity?.people
        let owner = controller.ownerName, paths = controller.paths, kept = kept, ratings = ratings
        reading = Task(priority: .utility) {
            let made = await Self.rows(records, profiles: profiles, store: store, owner: owner, paths: paths, kept: kept, ratings: ratings)
            reading = nil
            if !MeetingFilterRow.same(rows, made) {
                rows = made
                count()
            }
            if readAgain {
                readAgain = false
                read()
            }
        }
    }

    @concurrent
    nonisolated private static func rows(_ records: [CallRecord], profiles: [VoiceProfile], store: PeopleStore?, owner: String, paths: Paths,
                                         kept: MeetingFilterRows, ratings: MeetingRatings) async -> [MeetingFilterRow] {
        let people = MeetingFilterPeople(profiles: profiles, store: store, owner: owner)
        let rated = ratings.read(ids: records.map(\.id)) { paths.callDirectory($0) }
        return kept.rows(for: records, people: people, ratings: rated)
    }

    /// Counts for the newest filter and search text; an answer for an older pair is dropped.
    private func count() {
        counting?.cancel()
        let rows = rows, filter = filter, within = within, now = Date(), calendar = Calendar.current
        counting = Task {
            let made = await Self.facets(rows, filter, within, now: now, calendar: calendar)
            guard !Task.isCancelled else { return }
            if !facets.isSame(as: made) { facets = made }
            if answered != filter { answered = filter }
            day = MeetingFilterDay(calendar: calendar)
            day.counted(at: now)
            waitForMidnight()
        }
    }

    @concurrent
    nonisolated private static func facets(_ rows: [MeetingFilterRow], _ filter: MeetingFilter, _ within: Set<String>?, now: Date,
                                           calendar: Calendar) async -> MeetingFacets {
        MeetingFacets(rows: rows, filter: filter, within: within, now: now, calendar: calendar)
    }

    // MARK: Screenshots

    /// Development hooks for a `--ui-preview`: `MOSSAD_FILTER` sets choices ("person:Sam Carter;tag:Budget;
    /// length:to30 or 20-45;period:last30 or custom;weekday:2;size:small;value:high;platform:zoom;has:decisions;kind:Weekly sync"),
    /// `MOSSAD_FILTER_ALL` asks for all of the people, and `MOSSAD_FILTER_OPEN` opens the flyout a moment after the window.
    private func applyPreview() {
        guard DevHooks.preview else { return }
        let env = ProcessInfo.processInfo.environment
        if let text = env["MOSSAD_FILTER"] {
            var made = MeetingFilter()
            for part in text.split(separator: ";") {
                let pair = part.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
                guard pair.count == 2, let choice = Self.choice(pair[0], pair[1]) else { continue }
                made.toggle(choice)
            }
            if env["MOSSAD_FILTER_ALL"] != nil, made.people.count > 1 { made.peopleMode = .all }
            filter = made
        }
        // `MOSSAD_MEETING_QUERY` types into the Meetings search, to see the text and the filter together.
        if let query = env["MOSSAD_MEETING_QUERY"] { controller?.meetingQuery = query }
        if env["MOSSAD_FILTER_OPEN"] != nil {
            Task {
                try? await Task.sleep(for: .seconds(2))
                toggleOpen()
            }
        }
    }

    private static func choice(_ group: String, _ value: String) -> MeetingFilter.Active? {
        let lengths: [String: MeetingFilter.Length] = ["under15": .under15, "to30": .to30, "to60": .to60, "over60": .over60]
        let periods: [String: MeetingFilter.Period] = ["today": .today, "week": .thisWeek, "last7": .last7, "last30": .last30, "last90": .last90]
        let sizes: [String: MeetingFilter.Size] = ["alone": .alone, "1:1": .oneOnOne, "small": .small, "large": .large, "unknown": .unknown]
        let values: [String: MeetingFilter.Value] = ["high": .high, "medium": .medium, "low": .low, "none": .notRated]
        let flags: [String: MeetingFilter.Flag] = ["items": .actionItems, "decisions": .decisions, "screens": .screens]
        switch group {
        case "person": return .person(.init(name: value))
        case "tag": return .tag(value)
        case "kind": return .kind(value)
        case "weekday": return Int(value).map { .weekday($0) }
        case "length":
            if let known = lengths[value] { return .length(known) }
            // "20-45", or "45-" for 45 minutes or more.
            let ends = value.split(separator: "-", omittingEmptySubsequences: false).map { Int($0) }
            return ends.first.flatMap { $0 }.map { .customLength(.init(min: $0, max: ends.count > 1 ? ends[1] : nil)) }
        case "period":
            // "custom" is the last two weeks as a range of the owner's own.
            if value == "custom" { return .period(.custom(from: Date().addingTimeInterval(-13 * 86400), to: Date())) }
            return periods[value].map { .period($0) }
        case "size": return sizes[value].map { .size($0) }
        case "value": return values[value].map { .value($0) }
        case "platform": return Platform(rawValue: value).map { .platform($0) }
        case "has": return flags[value].map { .flag($0) }
        default: return nil
        }
    }
}
