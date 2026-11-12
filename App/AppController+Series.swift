import Foundation
import MossadCore

/// The recurring meetings, made off the main thread from the meetings and the calendar, and the owner's points for
/// next time, read again when the file changes (Chat, the MCP, and the phone write it too).
@MainActor
final class SeriesModel: ObservableObject {
    @Published private(set) var all: [MeetingSeries] = [] { willSet { owner?.objectWillChange.send() } }
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

    func series(_ id: String?) -> MeetingSeries? { id.flatMap { id in all.first { $0.id == id || $0.keys.contains(id) } } }

    /// Makes the catalog again when the meetings, the invites, or the people changed.
    func refresh(records: [CallRecord], upcoming: [UpcomingMeeting], owner: String, profiles: [VoiceProfile], ownerEmail: String, version: Int) {
        var h = Hasher()
        h.combine(version)
        h.combine(owner)
        for u in upcoming { h.combine(u.id); h.combine(u.seriesID); h.combine(u.attendees) }
        for p in profiles { h.combine(p.name); h.combine(p.email) }
        let key = h.finalize()
        guard key != builtFor else { return }
        builtFor = key
        building?.cancel()
        building = Task {
            let made = await Task.detached(priority: .userInitiated) {
                SeriesCatalog.build(records: records, upcoming: upcoming, owner: owner, directory: PersonDirectory(profiles: profiles), ownerEmails: [ownerEmail])
            }.value
            guard !Task.isCancelled else { return }
            all = made
            loaded = true
        }
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

    /// Sample points for a preview, from `MOSSAD_NEXT_TIME=<file>` (a made-up `next-time.json`).
    func usePreview(_ book: NextTimeBook) {
        self.book = book
        bookDate = .distantFuture
    }
}

extension AppController {
    /// Makes the catalog when something it reads changed. Cheap to call from any view's task.
    func refreshSeries() {
        series.owner = self
        series.reload(paths)
        series.refresh(records: meetings, upcoming: calendarUpcoming, owner: ownerName, profiles: library.profiles,
                       ownerEmail: UserDefaults.standard.string(forKey: "ownerEmail") ?? "", version: meetingsVersion)
    }

    func openSeries(_ id: String) {
        series.selected = id
        open(.recurring)
    }

    func changeNextTime(_ change: (inout NextTimeBook) -> Void) {
        guard !isInert || DevHooks.preview else { return }
        series.owner = self
        series.change(paths, change)
        syncNow()
    }

    /// The saved ids of the invited people of an upcoming meeting, on a sure match.
    func invitedPersonIDs(_ meeting: UpcomingMeeting) -> [String] {
        let refs = PersonReferences(people: PeopleStore.peek(in: paths.people) ?? [])
        let invited = MeetingPrep.invited(meeting.attendees, owner: ownerName, directory: PersonDirectory(profiles: library.profiles),
                                          ownerEmails: [UserDefaults.standard.string(forKey: "ownerEmail") ?? ""])
        return invited.compactMap { $0.person.flatMap { refs.id(for: $0) } }
    }

    /// The owner's open points for an upcoming meeting: its series' and its people's.
    func nextTimePoints(for meeting: UpcomingMeeting) -> [NextTimePoint] {
        series.book.points(for: SeriesCatalog.series(of: meeting, in: series.all), people: invitedPersonIDs(meeting))
    }

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
        let records = meetings, all = series.all
        Task {
            let changed = await runner.run(records: records, series: all) { await MainActor.run { self.isRecording } }
            if changed > 0 {
                series.reload(paths)
                syncNow()
            }
            series.checking = false
        }
    }

}
