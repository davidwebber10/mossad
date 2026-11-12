import Foundation
import MossadCore
import SwiftUI
import UIKit

enum PhoneTab: Hashable { case meetings, commitments, chat, analytics, search }

/// Pages Analytics pushes besides people and meetings.
enum AnalyticsRoute: Hashable { case people }

/// The phone's copy of the meetings: pulled from iCloud or the owner's server into the app's folder, then read with the same code
/// the Mac uses. Chats, ratings, replies to the coach, and the coach's memory go back up. Disk reads run off the main
/// thread; a view redraws only for the properties it reads.
@Observable
@MainActor
final class PhoneStore {
    private(set) var meetings: [CallRecord] = []
    /// The meetings by day for the list, as small rows made off the main thread when the meetings change.
    private(set) var days: [MeetingDay] = []
    /// The owner: the owner of the Mac's people, or else the name most often on the mic track.
    private(set) var owner = ""
    /// False until the first read of the folder, so an empty list does not say "No meetings yet" too soon.
    private(set) var loaded = false
    private(set) var profile = CoachProfile()
    /// The Mac's reads of how each person thinks, as the reduced copy that came through the owner's server.
    private(set) var personas: [PersonaSummary] = []
    /// The Mac's people, for a name's person id.
    private(set) var people: [Person] = []
    private(set) var chats: [Chat] = []
    private(set) var commitments = CommitmentBook()
    /// Room recordings made here that the Mac has not turned into meetings yet, from their first second.
    private(set) var outbox = Outbox()
    /// Recordings uploading now: one upload per recording at a time.
    private(set) var uploading: Set<String> = []
    /// The coach's score per meeting, for the lists.
    private(set) var scores: [String: Int] = [:]
    private(set) var syncing = false
    private(set) var lastSync: Date?
    /// The sync problem to show, and why each room recording waits. A single dropped connection is retried
    /// quietly and shows only when it repeats.
    private(set) var syncStatus: SyncStatus = {
        var s = SyncStatus()
        s.show(PhoneStore.hook("MOSSAD_ERROR").flatMap(ErrorPreview.sample))
        return s
    }()
    var error: FriendlyError? { syncStatus.shown }
    /// Bumped when a coach review changes here, so open reviews read it again.
    private(set) var coachVersion = 0
    /// The cards of all calls that wait for an answer, the newest call first.
    private(set) var findings: [CoachFinding] = []
    @ObservationIgnored private var findingsAsk = 0
    /// Bumped when a read of the folder finds the meetings changed, so pages that compute from them run again.
    private(set) var meetingsVersion = 0
    var tab = PhoneTab.meetings
    /// The meetings open in the Meetings tab, for `mossad://call/<id>` links.
    var path: [String] = []
    /// A moment to open a meeting at: the meeting page reads it once and opens the transcript there.
    var moment: Moment?
    /// A short message for a link that cannot open, such as to a meeting that is not on this iPhone yet.
    var notice: String?

    /// The pages open in the Analytics tab; People lives there.
    var analyticsPath = NavigationPath()
    /// A task or a chat that Search asked its tab to open; the tab reads it once.
    var openTask: UUID?
    var openChat: UUID?

    /// Universal search over everything here, rebuilt off the main thread when the data changes.
    private(set) var searchIndex = SearchIndex()
    private(set) var searchSuggestions = SearchSuggestions.empty
    /// Bumped when the index changes, so an open search runs again.
    private(set) var searchVersion = 0
    /// Who the owner meets with, for People and the profiles Search opens.
    private(set) var personStats: [String: PersonStats] = [:]
    @ObservationIgnored private var indexed: (meetings: Int, chats: [Chat])?
    @ObservationIgnored private var indexing: Task<Void, Never>?

    /// The room recorder. The store owns it, so a recording outlives its screen.
    let recorder = RoomRecorder()

    /// Questions about one meeting that are running or failed, by call id, so they outlive the meeting's sections.
    @ObservationIgnored private var meetingChats: [String: ChatRun] = [:]

    struct Moment: Equatable {
        let callID: String
        let at: TimeInterval
        let id = UUID()
    }

    let paths = Paths.live
    /// Where this iPhone syncs: iCloud (the default), the owner's own server, or nowhere.
    private(set) var syncWith = SyncChoice(rawValue: UserDefaults.standard.string(forKey: "syncWith") ?? "") ?? .icloud
    @ObservationIgnored private var engine: (key: String, sync: CloudSync)?
    @ObservationIgnored private let keychain = Keychain.app
    private var chatStore: ChatStore { ChatStore(directory: paths.chats) }
    /// `MOSSAD_ROOT` points the simulator at a sample folder; nothing syncs then.
    private let offline = ProcessInfo.processInfo.environment["MOSSAD_ROOT"] != nil
    /// Every write to a file that a pull also writes (commitments, the coach's memory, chats, reviews), and the
    /// pull itself, run one at a time, so neither saves over what the other merged.
    @ObservationIgnored private let writes = SerialQueue()
    @ObservationIgnored private var syncTask: (key: String, task: Task<Void, Never>)?
    /// The first read of the outbox and the meetings; a sync and a new recording wait for it.
    @ObservationIgnored private var launch: Task<Void, Never>?
    @ObservationIgnored private var outboxRead: Task<Void, Never>?
    /// Recordings whose parts are being joined now, and whether the recovery pass runs: one of each at a time.
    @ObservationIgnored private var joining: Set<String> = []
    @ObservationIgnored private var recovering = false
    @ObservationIgnored private var loading: Task<Void, Never>?

    /// A development hook for screenshots, read only with a sample folder so a real install never sees one.
    static func hook(_ name: String) -> String? {
        let env = ProcessInfo.processInfo.environment
        return env["MOSSAD_ROOT"] == nil ? nil : env[name]
    }

    /// `MOSSAD_APPEARANCE=dark|light`.
    static var previewScheme: ColorScheme? {
        switch hook("MOSSAD_APPEARANCE") {
        case "dark": return .dark
        case "light": return .light
        default: return nil
        }
    }

    init() {
        // Development hooks for screenshots: `MOSSAD_OPEN=<call id>` opens a meeting, `MOSSAD_TAB` picks a tab.
        if let id = ProcessInfo.processInfo.environment["MOSSAD_OPEN"], !id.isEmpty { path = [id] }
        // `MOSSAD_MOMENT=<call id>@<seconds>` opens a meeting at a moment, as a commitment does.
        if let m = Self.hook("MOSSAD_MOMENT")?.split(separator: "@"), m.count == 2, let at = TimeInterval(m[1]) {
            path = [String(m[0])]
            moment = Moment(callID: String(m[0]), at: at)
        }
        switch ProcessInfo.processInfo.environment["MOSSAD_TAB"] {
        case "commitments": tab = .commitments
        case "chat": tab = .chat
        case "people":
            tab = .analytics
            analyticsPath.append(AnalyticsRoute.people)
        case "analytics": tab = .analytics
        case "search": tab = .search
        default: break
        }
        // The first frame does not wait for the disk.
        let outboxRead = Task { await readOutbox() }
        self.outboxRead = outboxRead
        launch = Task {
            await outboxRead.value
            await load(meetings: true)
            // Joining a long recording takes a while; a sync does not wait for it.
            Task {
                await recoverRecordings()
                await sendOutbox()
            }
        }
    }

    /// The AI the Mac shares through iCloud Keychain, when the owner turned that on.
    var languageModel: (any LanguageModel)? {
        guard let shared = SharedAIKey.load(), let provider = AIProvider(rawValue: shared.provider) else { return nil }
        return provider.model(shared.model, apiKey: shared.key, usage: nil)
    }

    // MARK: Loading

    private struct Snapshot: Sendable {
        var meetings: [CallRecord]?
        /// False when the meetings read the same as the ones on screen; compared here, off the main thread.
        var changed = true
        var days: [MeetingDay] = []
        var owner = ""
        var scores: [String: Int] = [:]
        /// Changes when any meeting's review file did; nil when the meetings were not read.
        var coachStamp: Int?
        var profile: CoachProfile
        var personas: [PersonaSummary] = []
        var people: [Person] = []
        var chats: [Chat]
        var commitments: CommitmentBook

        static func read(_ paths: Paths, meetings readMeetings: Bool, shown: [CallRecord]) -> Snapshot {
            var s = Snapshot(profile: (try? CoachProfile.load(from: paths.coach)) ?? CoachProfile(),
                             chats: ChatStore(directory: paths.chats).all(),
                             commitments: (try? CommitmentBook.load(from: paths.commitments)) ?? CommitmentBook())
            s.personas = SyncedPersonas.load(from: paths.coach)?.personas ?? []
            s.people = PeopleStore.peek(in: paths.people) ?? []
            guard readMeetings else { return s }
            let meetings = MeetingIndex(paths: paths).all()
            s.meetings = meetings
            s.changed = meetings != shown
            s.days = MeetingGroups.byDay(meetings).map { MeetingDay(date: $0.date, title: $0.title, rows: $0.records.map(MeetingRow.init)) }
            var counts: [String: Int] = [:]
            for r in meetings { for (key, name) in r.speakerNames where key.hasPrefix("me:") { counts[name, default: 0] += 1 } }
            // The owner as the Mac's people say, else the name most often on the mic track (a Mac from before ids).
            let owner = PeopleStore.peek(in: paths.people)?.first { $0.isOwner && $0.isLive && !$0.displayName.isEmpty }?.displayName
            s.owner = owner ?? counts.max { $0.value < $1.value }?.key ?? ""
            // Only the reviews whose file changed are read again.
            let coach = PhoneStore.coachScores.read(ids: meetings.map(\.id)) { paths.callDirectory($0) }
            s.scores = coach.scores
            s.coachStamp = coach.stamp
            return s
        }
    }

    /// Reads the folder off the main thread and shows the result. The meetings (each `call.json` with its full
    /// transcript) are read only when asked: an edit to a task or a chat does not read them again.
    func load(meetings readMeetings: Bool) async {
        let previous = loading
        let paths = paths
        let task = Task {
            await previous?.value
            let shown = meetings
            let s = await Task.detached(priority: .userInitiated) { Snapshot.read(paths, meetings: readMeetings, shown: shown) }.value
            apply(s)
        }
        loading = task
        await task.value
    }

    nonisolated private static let coachScores = CoachScoreCache()
    @ObservationIgnored private var coachStamp: Int?

    private func apply(_ s: Snapshot) {
        // After a change made here (a note on a review) the open review reads again. After a read of the folder,
        // only when a review file or the coach's memory changed: this runs at every return to the app.
        let coachChanged = s.meetings == nil || s.coachStamp != coachStamp || profile != s.profile
        if s.meetings != nil { coachStamp = s.coachStamp }
        if let m = s.meetings {
            if s.changed {
                meetings = m
                meetingsVersion += 1
            }
            // The day titles ("Today") move with the clock, also when no meeting changed.
            if days != s.days { days = s.days }
            if owner != s.owner { owner = s.owner }
            if scores != s.scores { scores = s.scores }
            if !loaded { loaded = true }
            settleOutbox()
        }
        if profile != s.profile { profile = s.profile }
        let readsChanged = personas != s.personas
        if readsChanged { personas = s.personas }
        if people != s.people { people = s.people }
        if chats != s.chats { chats = s.chats }
        if commitments != s.commitments { commitments = s.commitments }
        if coachChanged || readsChanged {
            coachVersion += 1
            refreshFindings()
        }
        refreshSearch()
    }

    /// The meetings the search index holds, to find what changed.
    @ObservationIgnored private var indexedRecords: [String: CallRecord] = [:]

    /// Builds the search index again when meetings or chats changed, and only swaps the tasks when only they did.
    private func refreshSearch() {
        let meetings = meetings, chats = chats, tasks = commitments.items
        if let indexed, indexed.meetings == meetingsVersion, indexed.chats == chats {
            searchIndex.setTasks(tasks)
            searchVersion += 1
            return
        }
        indexed = (meetingsVersion, chats)
        let voices = paths.voices
        indexing?.cancel()
        let base = searchIndex, old = indexedRecords
        indexing = Task {
            let people = await Task.detached { VoiceLibrary(directory: voices).profiles }.value
            let records = Dictionary(meetings.map { ($0.id, $0) }, uniquingKeysWith: { _, b in b })
            // A few changed meetings are put into the index one by one; a build of the whole index is for the
            // first time and for many changes at once.
            let changed = records.filter { old[$0.key] != $0.value }.map(\.value), removed = old.keys.filter { records[$0] == nil }
            let index: SearchIndex
            if old.isEmpty || changed.count + removed.count > 20 {
                index = await SearchIndex.build(records: meetings, people: people, tasks: tasks, chats: chats)
            } else {
                index = await Task.detached(priority: .userInitiated) {
                    var next = base
                    for r in changed { next.update(r) }
                    for id in removed { next.removeMeeting(id: id) }
                    next.setPeople(people)
                    next.setChats(chats)
                    return next
                }.value
            }
            let stats = await Task.detached(priority: .userInitiated) { PersonStatistics.compute(meetings) }.value
            guard !Task.isCancelled else { return }
            indexedRecords = records
            var latest = index
            latest.setTasks(commitments.items)
            searchIndex = latest
            searchSuggestions = latest.suggestions()
            personStats = stats
            searchVersion += 1
        }
    }

    // MARK: Sync

    /// The server this iPhone uses: the one set up here, or the one the Mac shared through iCloud Keychain.
    var server: ServerConnection? {
        if let text = UserDefaults.standard.string(forKey: "serverAddress"), let address = ServerConnection.address(from: text),
           let secret = keychain.get(.serverSecret) {
            return ServerConnection(address: address, secret: secret)
        }
        return ServerPairing.shared()
    }

    /// "iCloud" or "your server", for messages.
    var place: String { syncWith == .server ? "your server" : "iCloud" }

    /// The store in use and its name, which the outbox keeps for each upload.
    private var cloud: (key: String, sync: CloudSync)? {
        guard !offline else { return nil }
        let key: String
        let store: any RecordStore
        switch syncWith {
        case .icloud: key = "icloud"; store = CloudKitStore()
        case .server:
            guard let c = server else { return nil }
            key = "server:\(c.address.absoluteString)"
            store = ServerStore(c)
        case .off: return nil
        }
        if let engine, engine.key == key { return engine }
        let sync = CloudSync(paths: paths, store: store)
        engine = (key, sync)
        return engine
    }

    func choose(_ choice: SyncChoice) {
        guard choice != syncWith else { return }
        use(choice)
    }

    /// Moves to a store (also to another server): the sync for the old one stops, and one for the new one starts now.
    private func use(_ choice: SyncChoice) {
        syncWith = choice
        UserDefaults.standard.set(choice.rawValue, forKey: "syncWith")
        engine = nil
        syncStatus.show(nil)
        lastSync = nil
        syncTask?.task.cancel()
        syncTask = nil
        syncing = false
        Task { await sync() }
    }

    /// Keeps a checked server on this iPhone and syncs with it.
    func connect(_ c: ServerConnection) {
        do { try keychain.set(c.secret, for: .serverSecret) } catch { Log.error("Saving the server secret failed: \(error)") }
        UserDefaults.standard.set(c.address.absoluteString, forKey: "serverAddress")
        use(.server)
    }

    func disconnectServer() {
        keychain.delete(.serverSecret)
        UserDefaults.standard.removeObject(forKey: "serverAddress")
        choose(.icloud)
    }

    /// Syncs, or waits for the sync already running for the same store, so a pull to refresh ends when it does.
    func sync() async {
        await launch?.value
        let key = cloud?.key ?? "none:\(syncWith.rawValue)"
        if let running = syncTask, running.key == key {
            await running.task.value
            return
        }
        syncTask?.task.cancel()
        let task = Task { await runSync(key: key) }
        syncTask = (key, task)
        syncing = true
        await task.value
        // By task, not by key: an older sync for the same store that ends late must not clear a newer one.
        if syncTask?.task == task {
            syncTask = nil
            syncing = false
        }
    }

    /// One sync with one store. A result for a store that is no longer the choice is dropped.
    private func runSync(key: String) async {
        func current() -> Bool { !Task.isCancelled && (cloud?.key ?? "none:\(syncWith.rawValue)") == key }
        if let cloud = cloud?.sync {
            do {
                // One quiet second try: a phone that just woke the app often has no route for a moment.
                try await writes.run {
                    try await TransientRetry.run {
                        try await cloud.pull(includeMeetings: true)
                        try await cloud.pushShared()
                    }
                }
                if current() {
                    syncStatus.succeeded()
                    lastSync = Date()
                }
            } catch is CancellationError {
                // The app stopped its own request (a refresh let go, a view closed, another store chosen).
            } catch let e as URLError where e.code == .cancelled {
            } catch {
                Log.error("Sync with \(place) failed: \(error)")
                if current() { syncStatus.failed(FriendlyError(error, context: .syncing, service: place)) }
            }
            guard current() else { return }
            await load(meetings: true)
            // Also after a failed pull, so each waiting recording gets its own reason. Upload problems stay on
            // their recordings; a good pull does not clear them.
            await sendOutbox()
            retryUnfinishedRecordings()
        } else {
            if syncWith == .server, !offline { syncStatus.show(FriendlyError(kind: .notConnected, context: .syncing)) }
            await load(meetings: true)
        }
    }

    /// While a room recording waits for its meeting, the app checks now and then without a pull to refresh.
    var waitsForTheMac: Bool {
        // Not for the recording in progress: a sync each minute of a meeting would read every meeting each time.
        let active = recorder.id
        return outbox.entries.contains { $0.id != active } && !offline && syncWith != .off
    }

    // MARK: Opening from Search

    func openTask(_ id: UUID) {
        tab = .commitments
        openTask = id
    }

    func openChat(_ id: UUID) {
        tab = .chat
        openChat = id
    }

    /// The query Search starts with, for screenshots: `MOSSAD_SEARCH=<words>`.
    static var searchHook: String { hook("MOSSAD_SEARCH") ?? "" }

    // MARK: Recent searches

    private(set) var recentSearches = UserDefaults.standard.stringArray(forKey: "recentSearches") ?? []

    func remember(search: String) {
        let q = search.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return }
        var list = recentSearches.filter { $0.caseInsensitiveCompare(q) != .orderedSame }
        list.insert(q, at: 0)
        recentSearches = Array(list.prefix(8))
        UserDefaults.standard.set(recentSearches, forKey: "recentSearches")
    }

    func clearRecentSearches() {
        recentSearches = []
        UserDefaults.standard.removeObject(forKey: "recentSearches")
    }

    /// Reads back what changed here (not the meetings) and sends it to the sync store, in the background.
    private func share() async {
        await load(meetings: false)
        guard let cloud = cloud?.sync else { return }
        do { _ = try await writes.run { try await cloud.pushShared() } } catch { Log.error("Sending changes to \(place) failed: \(error)") }
    }

    /// Runs a write to shared files in turn with the pull, then shares it.
    private func write(_ what: String, _ work: @escaping @Sendable () throws -> Void) {
        Task {
            do { try await writes.run(work) } catch { Log.error("Saving \(what) failed: \(error)") }
            await share()
        }
    }

    func coach(_ id: String) -> CoachReview? { CoachReview.load(in: paths.callDirectory(id)) }
    func meeting(_ id: String) -> CallRecord? { meetings.first { $0.id == id } }

    func openMeeting(_ id: String) {
        guard meeting(id) != nil else { return notOnThisPhone() }
        tab = .meetings
        path = [id]
    }

    func open(_ link: ChatLink) {
        showMoment(link.callID, at: link.at)
    }

    /// Opens a meeting, at a moment when there is one, as the Mac does for a commitment or a chat link.
    func showMoment(_ id: String, at: TimeInterval?) {
        guard meeting(id) != nil else { return notOnThisPhone() }
        tab = .meetings
        path = [id]
        moment = at.map { Moment(callID: id, at: $0) }
    }

    private func notOnThisPhone() {
        notice = loaded ? "That meeting isn't on this iPhone yet. It arrives after your Mac syncs it." : nil
    }

    // MARK: Chat

    func save(_ chat: Chat) {
        if let i = chats.firstIndex(where: { $0.id == chat.id }) { chats[i] = chat } else { chats.insert(chat, at: 0) }
        let store = chatStore
        Task {
            do { try await writes.run { try store.save(chat) } } catch { Log.error("Saving the chat failed: \(error)") }
        }
    }

    func delete(_ chat: Chat) {
        chats.removeAll { $0.id == chat.id }
        let store = chatStore, id = chat.id
        write("the chat deletion") { store.delete(id) }
    }

    func answer(_ question: String, history: [ChatMessage], about callID: String? = nil,
                onStep: @escaping @Sendable (String) -> Void) async throws -> String {
        guard let llm = languageModel else { throw NoSharedKey() }
        return try await ChatAgent(llm: llm, ownerName: owner).answer(question, history: history, records: meetings, paths: paths,
                                                                      about: callID, onStep: onStep)
    }

    /// Writes the chat's short summary for later chats to recall, then syncs it.
    func finish(_ id: UUID) {
        let llm = languageModel, owner = owner, store = chatStore, writes = writes
        Task {
            // The answer is saved before the summary reads it.
            _ = try? await writes.run {}
            await share()
            guard let llm, let chat = chats.first(where: { $0.id == id }),
                  let summary = try? await ChatAgent(llm: llm, ownerName: owner).summarize(chat) else { return }
            do {
                try await writes.run {
                    guard var latest = store.all().first(where: { $0.id == id }) else { return }
                    latest.summary = summary
                    try store.save(latest)
                }
            } catch { Log.error("Saving the chat summary failed: \(error)") }
            await share()
        }
    }

    /// The run of questions about one meeting, kept here so it outlives the meeting's sections.
    func chatRun(_ callID: String) -> ChatRun {
        if let run = meetingChats[callID] { return run }
        let run = ChatRun()
        meetingChats[callID] = run
        return run
    }

    // MARK: Room recordings

    var recordingsFolder: URL { paths.root.appendingPathComponent("Recordings") }
    private var outboxFile: URL { recordingsFolder.appendingPathComponent(Outbox.fileName) }

    private func saveOutbox() {
        // The entry exists from the start of the recording, so a lost write is repaired by the next launch's scan.
        do { try outbox.save(to: outboxFile) } catch { Log.error("Saving the outbox failed: \(error)") }
        syncStatus.keepUploads(for: Set(outbox.entries.filter { !$0.isSent }.map(\.id)))
    }

    /// Removes recordings whose meeting has arrived from the Mac, with their audio. Only an in-person meeting
    /// counts: ids are start times, and a call on the Mac can start in the same second as a room recording.
    private func settleOutbox() {
        let done = outbox.settle(arrived: Set(meetings.lazy.filter { $0.platform == .inPerson }.map(\.id)))
        guard !done.isEmpty else { return }
        let dir = recordingsFolder
        for id in done { RoomAudio.delete(id, in: dir) }
        saveOutbox()
    }

    /// At launch, before anything else touches the outbox: a file that cannot be read is set aside, and the scan
    /// below fills the outbox again from the audio on disk.
    private func readOutbox() async {
        let file = outboxFile
        let (box, aside) = await Task.detached { Outbox.loadOrSetAside(from: file) }.value
        if let aside { Log.error("The outbox could not be read; it is kept as \(aside.lastPathComponent)") }
        outbox = box
    }

    /// Finishes each recording that the app never finished, and each audio file with no entry, as the Mac does for
    /// its own calls after a crash. It runs at launch, and again after a sync while a recording is not saved.
    private func recoverRecordings() async {
        guard !recovering else { return }
        recovering = true
        defer { recovering = false }
        let dir = recordingsFolder
        guard let audio = await Task.detached(operation: { RoomAudio.ids(in: dir) }).value else {
            // Unknown is not empty: no entry is removed because the folder would not list.
            Log.error("The recordings folder could not be listed; recovery waits")
            return
        }
        for id in outbox.withoutAudio(audioIDs: audio, active: recorder.id) where !joining.contains(id) {
            Log.error("The room recording \(id) has no audio on this iPhone; its entry is removed")
            outbox.remove(id)
            saveOutbox()
        }
        for id in outbox.needsRecovery(audioIDs: audio, active: recorder.id) {
            // Looked at again: the Stop path may have finished it while this pass joined another one.
            guard id != recorder.id, !joining.contains(id), outbox[id].map({ $0.state == .recording }) ?? true else { continue }
            joining.insert(id)
            let found = await Task.detached { () -> (short: Bool, end: Date?) in
                // Once the parts are joined, the file's date is the join's, not the meeting's end.
                (RoomAudio.isSurelyShort(id, in: dir, minimum: ProcessingQueue.minimumCallDuration),
                 RoomAudio.parts(of: id, in: dir).isEmpty ? nil : RoomAudio.lastWrite(of: id, in: dir))
            }.value
            if found.short {
                // Short by every measure: each part opened, and its bytes agree.
                RoomAudio.delete(id, in: dir)
                outbox.remove(id)
                saveOutbox()
                joining.remove(id)
                continue
            }
            if outbox[id] == nil {
                let start = RoomAudio.start(of: id) ?? found.end ?? Date()
                outbox.begin(PhoneRecording(id: id, start: start, end: start, title: nil))
            }
            await join(id, end: found.end, title: nil)
        }
    }

    /// Tries again for recordings that could not be saved, without waiting for the next launch.
    private func retryUnfinishedRecordings() {
        let active = recorder.id
        guard !recovering, outbox.entries.contains(where: { $0.state == .recording && $0.id != active && !joining.contains($0.id) })
        else { return }
        Task {
            await recoverRecordings()
            await sendOutbox()
        }
    }

    /// Joins a stopped recording's parts into the file to send, and puts it in line. The caller has put the id in
    /// `joining`. A part that cannot be read does not hold back the rest: what reads is joined and sent, the bad
    /// part stays on the iPhone under its own name, and the row says so. Any other failure (a full disk) keeps
    /// every part, and the next sync tries again.
    private func join(_ id: String, end: Date?, title: String?) async {
        defer { joining.remove(id) }
        let dir = recordingsFolder
        let result = await Task.detached { () -> Result<RoomAudio.Joined, any Error> in
            do {
                return .success(try RoomAudio.finish(id, in: dir))
            } catch is RoomAudio.Unreadable {
                return Result { try RoomAudio.finish(id, in: dir, salvage: true) }
            } catch {
                return .failure(error)
            }
        }.value
        switch result {
        case .success(let joined):
            let start = outbox[id]?.recording.start ?? Date()
            outbox.finish(id, end: end ?? start.addingTimeInterval(joined.length), title: title)
            if joined.setAside.isEmpty {
                Log.info("Saved the room recording \(id) (\(Int(joined.length)) s)")
            } else {
                Log.error("The room recording \(id) was saved without parts that could not be read; they stay as \(joined.setAside.joined(separator: ", "))")
                outbox.setTrouble(id, .partUnreadable)
            }
        case .failure(let error):
            // The parts stay, and the entry stays `recording`. Logged once, not at each try.
            if outbox[id]?.trouble != .notSaved { Log.error("Saving the room recording \(id) failed: \(error)") }
            outbox.setTrouble(id, .notSaved)
        }
        saveOutbox()
    }

    func startRecording() async {
        // The outbox is read first, so the read never replaces this recording's entry.
        await outboxRead?.value
        guard let rec = await recorder.start(into: recordingsFolder) else { return }
        outbox.begin(rec)
        saveOutbox()
    }

    /// Keeps the name the owner types in the entry, so a recording that the app never finishes still has it.
    func keepRecordingTitle() {
        guard let id = recorder.id, let entry = outbox[id] else { return }
        let t = recorder.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let title = t.isEmpty ? nil : t
        guard entry.recording.title != title else { return }
        outbox.retitle(id, title)
        saveOutbox()
    }

    /// Stops the recording, keeps it unless it is short (or the owner discarded a short one), joins its parts into
    /// one file, and sends it. The phone may be locked right after Stop, so this asks for background time.
    func stopRecording(discard: Bool) {
        guard let stopped = recorder.stop() else { return }
        let dir = recordingsFolder, id = stopped.id
        outbox.retitle(id, stopped.title)
        joining.insert(id)
        Task {
            let time = BackgroundTime("Finish the room recording")
            defer { time.end() }
            let deleted = await Task.detached { () -> Bool in
                let measured = RoomAudio.length(of: id, in: dir)
                if RoomRecording.keep(measured: measured, counted: stopped.counted, discard: discard) { return false }
                // The owner's own "Discard" is enough. Without it, a part that did not open may hold more than the
                // count says, so the files must also be short by every measure.
                guard discard || RoomAudio.isSurelyShort(id, in: dir, minimum: ProcessingQueue.minimumCallDuration) else { return false }
                RoomAudio.delete(id, in: dir)
                return true
            }.value
            if deleted {
                joining.remove(id)
                outbox.remove(id)
                saveOutbox()
                return
            }
            await join(id, end: stopped.end, title: nil)
            await sendOutbox()
        }
    }

    /// Whether a row offers "Remove".
    func canRemoveRecording(_ id: String) -> Bool {
        outbox.canRemove(id, active: recorder.id, busy: uploading.union(joining))
    }

    /// The owner's "Remove": the row, its audio, and any parts set aside. Nothing else deletes a recording that the
    /// Mac does not have.
    func removeRecording(_ id: String) {
        guard canRemoveRecording(id) else { return }
        RoomAudio.delete(id, in: recordingsFolder, setAside: true)
        outbox.remove(id)
        saveOutbox()
        Log.info("The owner removed the room recording \(id)")
    }

    /// The owner's "Send again" on a recording whose meeting has not come back.
    func sendAgain(_ id: String) {
        outbox.sendAgain(id)
        saveOutbox()
        Task { await sendOutbox() }
    }

    /// Uploads what the store does not have yet, and again what it took long ago with no meeting back, or what
    /// another store took. The audio stays here until the meeting comes back from the Mac.
    func sendOutbox() async {
        guard let engine = cloud else { return }
        let key = engine.key, cloud = engine.sync
        let dir = recordingsFolder
        for listed in outbox.due(store: key, now: Date()) {
            // Looked at again here: another pass may have sent it while this one uploaded the one before.
            guard !uploading.contains(listed.id),
                  let entry = outbox.due(store: key, now: Date()).first(where: { $0.id == listed.id }) else { continue }
            uploading.insert(entry.id)
            let time = BackgroundTime("Upload the room recording")
            do {
                try await cloud.upload(entry.recording, audio: RoomAudio.finished(entry.id, in: dir))
                outbox.markSent(entry.id, store: key, at: Date())
                saveOutbox()
                syncStatus.uploaded(entry.id)
            } catch {
                Log.error("Uploading the room recording failed: \(error)")
                syncStatus.uploadFailed(entry.id, FriendlyError(error, context: .uploadingAudio, service: place))
            }
            time.end()
            uploading.remove(entry.id)
        }
    }

    // MARK: Commitments

    /// Shows the change at once, and writes it to the file as it is on disk then, in turn with the pull.
    func changeCommitments(_ change: @escaping @Sendable (inout CommitmentBook) -> Void) {
        change(&commitments)
        let file = paths.commitments
        write("the tasks") {
            var book = (try? CommitmentBook.load(from: file)) ?? CommitmentBook()
            change(&book)
            try book.save(to: file)
        }
    }

    func saveCommitment(_ c: Commitment) {
        changeCommitments { book in
            if book.items.contains(where: { $0.id == c.id }) { book.update(c.id) { $0 = c } } else { book.items.append(c) }
        }
    }

    func toggleDone(_ id: UUID) {
        // The same moment on both copies, so the screen and the file agree.
        let now = Date()
        changeCommitments { $0.update(id) { $0.done = $0.done == nil ? now : nil } }
    }

    func deleteCommitment(_ id: UUID) { changeCommitments { $0.delete(id) } }

    // MARK: Coach

    /// Changes the coach's memory as it is on disk at the time of the write, not the copy on screen.
    private func changeProfile(_ change: @escaping @Sendable (inout CoachProfile) -> Void) {
        change(&profile)
        let file = paths.coach
        write("the coach's memory") {
            var p = (try? CoachProfile.load(from: file)) ?? CoachProfile()
            change(&p)
            try p.save(to: file)
        }
    }

    /// Saves a 👍 or 👎 on one point. A note goes to the coach as a reply, so it can learn from it.
    func rate(callID: String, point: CoachPoint, agree: Bool, note: String?) async throws {
        let dir = paths.callDirectory(callID), coachFile = paths.coach
        guard let record = meeting(callID) else { return }
        let feedback = CoachFeedback(agree: agree, note: note), title = record.title
        try await writes.run {
            guard var review = CoachReview.load(in: dir) else { return }
            review.feedback[point.title] = feedback
            try review.save(in: dir)
            var profile = (try? CoachProfile.load(from: coachFile)) ?? CoachProfile()
            profile.remember(feedback, on: point, callID: callID, title: title)
            try profile.save(to: coachFile)
        }
        await share()
        if let note { try await reply(callID: callID, message: "About your point “\(point.title)”: \(note)") }
    }

    /// Sends a reply to the coach about one review; the answer joins the review's thread, and any new
    /// guidance joins the coach's memory.
    func reply(callID: String, message: String) async throws {
        guard let llm = languageModel else { throw NoSharedKey() }
        let dir = paths.callDirectory(callID), coachFile = paths.coach
        guard let review = CoachReview.load(in: dir), let record = meeting(callID) else { return }
        let answer = try await CoachResponder(llm: llm, ownerName: owner).respond(to: message, review: review, record: record, profile: profile)
        try await writes.run {
            var latest = CoachReview.load(in: dir) ?? review
            latest.thread += [ChatMessage(role: .user, text: message), ChatMessage(role: .assistant, text: answer.reply)]
            try latest.save(in: dir)
            var profile = (try? CoachProfile.load(from: coachFile)) ?? CoachProfile()
            profile.updateGuidance(add: answer.add, remove: answer.remove, at: Date())
            profile.updateFacts(add: answer.addFacts, remove: answer.removeFacts)
            try profile.save(to: coachFile)
        }
        await share()
    }

    func acceptFocus(_ id: UUID, plan: String?) {
        let now = Date()
        changeProfile { $0.acceptFocus(id, plan: plan, at: now) }
    }

    // MARK: Findings

    /// The read of how a person thinks, by the person's id, from the Mac's copy.
    func persona(named name: String) -> PersonaSummary? {
        let saved = CoachPeople(people: people)
        guard let id = saved.id(of: name).map(saved.canonical) else { return nil }
        return personas.first { $0.person == id }
    }

    /// The trait cards of the deck: the phone has the shown traits only, so it asks only about those.
    @ObservationIgnored private var traitCards: [String: CoachFinding] = [:]

    /// The cards of one call that wait for an answer.
    func findings(for record: CallRecord, review: CoachReview) -> [CoachFinding] {
        FindingRules.deck(callID: record.id, date: record.start, review: review, profile: profile, trait: traitCards[record.id])
    }

    /// Reads the cards of all calls again, off the main thread. Only the calls of the last two weeks can have one.
    func refreshFindings() {
        // Development hook for screenshots: `MOSSAD_DECK_CARDS=<file>` is a JSON list of made-up cards to show.
        if let path = Self.hook("MOSSAD_DECK_CARDS"), let data = FileManager.default.contents(atPath: path),
           let sample = try? JSONDecoder().decode([CoachFinding].self, from: data) {
            findings = sample
            return
        }
        let now = Date(), paths = paths, profile = profile
        let recent = meetings.filter { now.timeIntervalSince($0.start) <= FindingRules.expiryDays * 86_400 }.map { ($0.id, $0.start) }
        let saved = CoachPeople(people: people)
        let cardCalls = PersonaFindings.calls(from: meetings, now: now)
        let sources = personas.flatMap { p in p.traits.map { PersonaFindings.Source($0, person: p.person, name: saved.name(of: p.person) ?? "") } }
            .filter { !$0.personName.isEmpty }
        findingsAsk += 1
        let ask = findingsAsk
        Task {
            let (cards, traits) = await Task.detached(priority: .utility) {
                let traits = PersonaFindings.cards(sources, calls: cardCalls, profile: profile, now: now,
                                                   quote: { PersonaReads.words($0, person: $1, paths: paths, saved: saved) })
                let cards = FindingRules.deck(reviews: recent.compactMap { id, start in
                    CoachReview.load(in: paths.callDirectory(id)).map { (callID: id, date: start, review: $0) }
                }, profile: profile, now: now, traits: traits)
                return (cards, traits)
            }.value
            guard ask == findingsAsk else { return }
            traitCards = traits
            if cards != findings { findings = cards }
        }
    }

    /// Saves the owner's answer to a card: in the coach's memory, which goes to the Mac, and next to the call's review.
    func answerFinding(_ finding: CoachFinding, _ verdict: FindingVerdict) {
        let now = Date()
        changeFindings(callID: finding.callID) { $0.answer(finding, verdict, at: now) }
    }

    func takeBackFinding(_ id: String) {
        let now = Date()
        changeFindings(callID: callID(ofAnswer: id)) { $0.takeBack(id, at: now) }
    }

    /// Undo in the list of what was blocked for good: on a goal it only takes the block away.
    func allowFindingAgain(_ id: String) {
        let now = Date()
        changeFindings(callID: callID(ofAnswer: id)) { $0.allowAgain(id, at: now) }
    }

    /// Why the owner said no to a card: guidance for that card.
    func explainFinding(_ id: String, note: String) {
        let now = Date()
        changeFindings(callID: callID(ofAnswer: id)) { $0.explain(id, note: note, at: now) }
    }

    private func callID(ofAnswer id: String) -> String? { profile.answers.first { $0.id == id }?.callID }

    private func changeFindings(callID: String?, _ change: @escaping @Sendable (inout CoachProfile) -> Void) {
        change(&profile)
        let file = paths.coach, paths = paths
        write("the coach's memory") {
            var p = (try? CoachProfile.load(from: file)) ?? CoachProfile()
            change(&p)
            try p.save(to: file)
            if let callID { FindingStore.mirror(p.answers, callID: callID, paths: paths) }
        }
        refreshFindings()
    }

    func answerQuestion(_ id: UUID, _ status: CoachQuestion.Status, note: String?) {
        let now = Date()
        changeProfile { $0.answer(id, status, note: note, at: now) }
    }

    /// "Take it up again" on an ended or learned goal.
    func resumeFocus(_ id: UUID) {
        let now = Date()
        changeProfile { $0.resumeFocus(id, at: now) }
    }

    /// The owner says the goal is learned.
    func learnFocus(_ id: UUID) {
        let now = Date()
        changeProfile { $0.learnFocus(id, at: now) }
    }

    func dismissFocus(_ id: UUID) {
        let now = Date()
        changeProfile { $0.dismissFocus(id, at: now) }
    }

    func addFact(_ kind: CoachFact.Kind, _ text: String) {
        changeProfile { $0.updateFacts(add: [CoachFact(kind: kind, text: text)], remove: []) }
    }

    func removeFact(_ text: String) {
        changeProfile { $0.updateFacts(add: [], remove: [text]) }
    }

    func removeGuidance(_ text: String) {
        let now = Date()
        changeProfile { $0.updateGuidance(add: [], remove: [text], at: now) }
    }
}

/// A question about a meeting while it runs, and its error, kept by the store.
@Observable
@MainActor
final class ChatRun {
    var running = false
    var steps: [String] = []
    var error: FriendlyError? = PhoneStore.hook("MOSSAD_ERROR").flatMap(ErrorPreview.sample)
}

/// Time to finish a step after the owner locks the phone, such as an upload after Stop.
@MainActor
final class BackgroundTime {
    private var id = UIBackgroundTaskIdentifier.invalid

    init(_ name: String) {
        id = UIApplication.shared.beginBackgroundTask(withName: name) { [weak self] in
            MainActor.assumeIsolated { self?.end() }
        }
    }

    func end() {
        guard id != .invalid else { return }
        UIApplication.shared.endBackgroundTask(id)
        id = .invalid
    }
}

struct NoSharedKey: LocalizedError {
    var errorDescription: String? {
        "Chat on the iPhone uses the AI key from your Mac. In Mossad on your Mac, open Settings and turn on “Use my AI key on my iPhone”."
    }
}
