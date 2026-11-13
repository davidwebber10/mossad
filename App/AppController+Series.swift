import Foundation
import MossadCore

/// The recurring meetings, made off the main thread from the meetings and the calendar, and the owner's points for
/// next time, read again when the file changes (Chat, the MCP, and the phone write it too).
@MainActor
final class SeriesModel: ObservableObject {
    @Published private(set) var all: [MeetingSeries] = [] {
        willSet { owner?.objectWillChange.send() }
        didSet { version += 1 }
    }
    /// Counts the catalogs made, so a page that derives from `all` makes its part again only on a change.
    private(set) var version = 0
    /// A series that a link asked to open: Calendar mode opens its page full-pane (`SeriesShown.fullPane`).
    @Published var toOpen: String?
    @Published private(set) var book = NextTimeBook() { willSet { owner?.objectWillChange.send() } }
    /// False when the file is there and cannot be read: then nothing is saved over it.
    @Published private(set) var bookReadable = true { willSet { owner?.objectWillChange.send() } }
    /// The views that read the controller redraw when the points or the series change.
    weak var owner: AppController?
    /// False until the first catalog is made, so the page does not say "none" meanwhile.
    @Published private(set) var loaded = false
    private var builtFor: Int?
    private var building: Task<Void, Never>?
    private var bookDate: Date?
    /// True while the check after a meeting runs, so only one runs.
    var checking = false
    /// The series open on the Recurring page.
    @Published var selected: String?
    /// True when Back, Forward, or a link asked for `selected`: it shows before the list has answered its search,
    /// until the owner changes the list (`SeriesShown`).
    var asked = false

    func series(_ id: String?) -> MeetingSeries? { id.flatMap { id in all.first { $0.id == id || $0.keys.contains(id) } } }

    /// The saved people of each invite by its id, and of each series' usual people, made with the catalog: the
    /// pages and the menu read these and never the people file.
    private(set) var invitedIDs: [String: [String]] = [:]
    private(set) var usualIDs: [String: [(id: String, name: String)]] = [:]
    /// The people store, for the id a merged person has now.
    private(set) var people = PersonReferences(people: [])

    /// Everything the catalog is made from, taken on the main actor.
    struct Inputs: Sendable {
        let events: [CalendarEventInfo]
        let records: [CallRecord]
        let owner: String
        let profiles: [VoiceProfile]
        let ownerEmail: String
        let peopleDir: URL
    }

    private struct Made: Sendable {
        let all: [MeetingSeries]
        let invited: [String: [String]]
        let usual: [String: [UsualPerson]]
        let people: PersonReferences
    }

    struct UsualPerson: Sendable {
        let id: String
        let name: String
    }

    /// The invites and the series, made from the inputs alone: the page's catalog, and the usage report's count,
    /// which must not wait for a page to have made the catalog.
    nonisolated static func catalog(_ inputs: Inputs) -> (upcoming: [UpcomingMeeting], all: [MeetingSeries]) {
        let upcoming = UpcomingMeeting.from(inputs.events, limit: .max, recorded: inputs.records)
        let all = SeriesCatalog.build(records: inputs.records, upcoming: upcoming, owner: inputs.owner, directory: PersonDirectory(profiles: inputs.profiles),
                                      ownerEmails: [inputs.ownerEmail], aliases: SeriesCatalog.aliases(inputs.events))
        return (upcoming, all)
    }

    /// Makes the catalog again when the meetings, the invites, or the people changed. The invites come from the
    /// whole read of the calendar (`UpcomingMeeting.days`), as in the lists. All of it is off the main
    /// thread: the invites against the records, the catalog, and the people file.
    func refresh(_ inputs: Inputs, version: Int) {
        var h = Hasher()
        h.combine(version)
        h.combine(inputs.owner)
        h.combine(inputs.ownerEmail)
        for e in inputs.events { h.combine(e.title); h.combine(e.start); h.combine(e.seriesID); h.combine(e.attendees) }
        for p in inputs.profiles { h.combine(p.name); h.combine(p.email) }
        let file = inputs.peopleDir.appendingPathComponent(PeopleStore.fileName)
        h.combine((try? FileManager.default.attributesOfItem(atPath: file.path))?[.modificationDate] as? Date)
        h.combine(Calendar.current.startOfDay(for: Date()))
        // The weekdays and the times of the schedules are the owner's clock's.
        h.combine(TimeZone.current.identifier)
        let key = h.finalize()
        guard key != builtFor else { return }
        builtFor = key
        building?.cancel()
        building = Task {
            let made = await Task.detached(priority: .userInitiated) { () -> Made in
                let (upcoming, all) = Self.catalog(inputs)
                let refs = PersonReferences(people: PeopleStore.peek(in: inputs.peopleDir) ?? [])
                var invited: [String: [String]] = [:]
                for u in upcoming { invited[u.id] = NextTimeInvite.personIDs(u.attendees, people: refs) }
                var usual: [String: [UsualPerson]] = [:]
                for s in all {
                    var seen: Set<String> = []
                    usual[s.id] = s.usualPeople.compactMap { name in
                        guard let id = refs.id(for: name).map(refs.canonical), refs.person(id)?.isOwner != true, seen.insert(id).inserted else { return nil }
                        return UsualPerson(id: id, name: refs.name(of: id) ?? name)
                    }
                }
                return Made(all: all, invited: invited, usual: usual, people: refs)
            }.value
            guard !Task.isCancelled else { return }
            invitedIDs = made.invited
            usualIDs = made.usual.mapValues { $0.map { (id: $0.id, name: $0.name) } }
            people = made.people
            all = made.all
            loaded = true
            // The points take the keys their series has now (one save, only on a change).
            if let owner, book.points.contains(where: { $0.seriesID != nil && $0.isOpen }) {
                var copy = book
                if copy.refreshKeys(made.all) { owner.changeNextTime { $0.refreshKeys(made.all) } }
            }
        }
    }

    /// The owner's open points for an upcoming meeting: its series' and its invited people's.
    func points(for meeting: UpcomingMeeting) -> [NextTimePoint] {
        let refs = people
        return book.points(for: SeriesCatalog.series(of: meeting, in: all), people: invitedIDs[meeting.id] ?? [], canonical: { refs.canonical($0) })
    }

    /// Reads the book again when its file changed.
    func reload(_ paths: Paths) {
        let file = paths.nextTime.appendingPathComponent(NextTimeBook.fileName)
        let date = (try? FileManager.default.attributesOfItem(atPath: file.path))?[.modificationDate] as? Date
        guard date != bookDate || bookDate == nil else { return }
        bookDate = date
        if let read = NextTimeBook.peek(in: paths.nextTime) {
            if read != book { book = read }
            bookReadable = true
        } else {
            bookReadable = false
        }
    }

    /// Changes the book on disk. A book that cannot be read is never replaced.
    func change(_ paths: Paths, _ change: (inout NextTimeBook) -> Void) {
        do {
            book = try NextTimeBook.change(in: paths.nextTime, change)
            bookDate = (try? FileManager.default.attributesOfItem(atPath: paths.nextTime.appendingPathComponent(NextTimeBook.fileName).path))?[.modificationDate] as? Date
            bookReadable = true
        } catch {
            Log.error("Saving the points for next time failed: \(error)")
            bookReadable = false
        }
    }

}

extension AppController {
    /// Makes the catalog when something it reads changed. Cheap to call from any view's task.
    func refreshSeries() {
        series.owner = self
        series.reload(paths)
        series.refresh(.init(events: calendarEvents, records: meetings, owner: ownerName, profiles: library.profiles,
                             ownerEmail: UserDefaults.standard.string(forKey: "ownerEmail") ?? "", peopleDir: paths.people), version: meetingsVersion)
    }

    func openSeries(_ id: String) {
        navigation.jumpNext()
        // A link asks to see its series: a Recurring search or filter that hides it is cleared.
        if SeriesShown.linkClearsList(to: id, visible: seriesFilter.visible(series.all).map(\.id)) {
            seriesFilter.query = ""
            seriesFilter.filter = SeriesFilter()
        }
        series.selected = series.series(id)?.id ?? id
        series.asked = true
        series.toOpen = series.selected
        open(.recurring)
    }

    func changeNextTime(_ change: (inout NextTimeBook) -> Void) {
        guard !isInert || DevHooks.preview else { return }
        series.owner = self
        series.change(paths, change)
        // During a call the disk and the network belong to the recording; the sync after the call sends the book.
        if LivePointRules.syncsAfterChange(recording: isRecording) { syncNow() }
    }

    /// The owner's open points for an upcoming meeting: its series' and its people's. Reads no file.
    func nextTimePoints(for meeting: UpcomingMeeting) -> [NextTimePoint] { series.points(for: meeting) }

    /// Adds a point from words, for the search command: "TB" or "Sam Carter". Returns what happened, in words.
    @discardableResult
    func addNextTimePoint(_ text: String, series query: String?, person: String?) -> String {
        let refs = PersonReferences(people: PeopleStore.peek(in: paths.people) ?? [])
        var outcome = NextTimeAdd.Outcome.notFound("")
        changeNextTime { outcome = NextTimeAdd.add(text, series: query, person: person, series: series.all, people: refs, book: &$0) }
        switch outcome {
        case .added(let p): return p.seriesTitle.map { "Saved for the next \($0)" } ?? "Saved for the next time you see \(p.personName ?? "them")"
        case .choose(let titles): return "Choose one: \(titles.joined(separator: ", "))"
        case .notFound(let why): return why
        }
    }

    /// After meetings are written: checks the owner's points against them. Never while a call records, and never
    /// with no points.
    func runNextTimeCheck() {
        guard !isInert, !isRecording, !series.checking, let llm = languageModel else { return }
        refreshSeries()
        guard series.book.points.contains(where: \.isOpen) else { return }
        series.checking = true
        let runner = NextTimeRunner(paths: paths, checker: NextTimeChecker(llm: llm))
        // The runner reads the records from disk and makes its own catalog from them, so the meeting written a
        // moment ago is in its series.
        let events = calendarEvents, records = meetings, owner = ownerName, profiles = library.profiles
        let email = UserDefaults.standard.string(forKey: "ownerEmail") ?? ""
        Task {
            let upcoming = await Task.detached { UpcomingMeeting.from(events, limit: .max, recorded: records) }.value
            let changed = await runner.run(upcoming: upcoming, owner: owner, directory: PersonDirectory(profiles: profiles), ownerEmails: [email],
                                           aliases: SeriesCatalog.aliases(events)) { await MainActor.run { self.isRecording } }
            if changed > 0 {
                series.reload(paths)
                syncNow()
            }
            series.checking = false
        }
    }

}
