import Foundation
import MossadCore
import SwiftUI

enum PhoneTab: Hashable { case meetings, commitments, chat, analytics, search }

/// Pages Analytics pushes besides people and meetings.
enum AnalyticsRoute: Hashable { case people }

/// The phone's copy of the meetings: pulled from iCloud or the owner's server into the app's folder, then read with the same code
/// the Mac uses. Chats, ratings, replies to the coach, and the coach's memory go back up.
@MainActor
final class PhoneStore: ObservableObject {
    @Published private(set) var meetings: [CallRecord] = []
    @Published private(set) var profile = CoachProfile()
    @Published private(set) var chats: [Chat] = []
    @Published private(set) var commitments = CommitmentBook()
    /// Room recordings made here that the Mac has not turned into meetings yet; `sent` once iCloud has them.
    @Published private(set) var outbox: [Outgoing] = []

    struct Outgoing: Codable, Identifiable, Equatable {
        var recording: PhoneRecording
        var sent = false
        var id: String { recording.id }
    }
    /// The coach's score per meeting, for the lists.
    @Published private(set) var scores: [String: Int] = [:]
    @Published private(set) var syncing = false
    @Published private(set) var lastSync: Date?
    @Published private(set) var error: String?
    /// Bumped when a coach review changes here, so open reviews read it again.
    @Published private(set) var coachVersion = 0
    @Published var tab = PhoneTab.meetings
    /// The meetings open in the Meetings tab, for `mossad://call/<id>` links.
    @Published var path: [String] = []
    /// A moment to open a meeting at: the meeting page reads it once and opens the transcript there.
    @Published var moment: Moment?

    /// The pages open in the Analytics tab; People lives there.
    @Published var analyticsPath = NavigationPath()
    /// A task or a chat that Search asked its tab to open; the tab reads it once.
    @Published var openTask: UUID?
    @Published var openChat: UUID?

    /// Universal search over everything here, rebuilt off the main thread when the data changes.
    @Published private(set) var searchIndex = SearchIndex()
    @Published private(set) var searchSuggestions = SearchSuggestions.empty
    /// Bumped when the index changes, so an open search runs again.
    @Published private(set) var searchVersion = 0
    /// Who the owner meets with, for People and the profiles Search opens.
    @Published private(set) var personStats: [String: PersonStats] = [:]
    private var indexed: (meetings: [CallRecord], chats: [Chat])?
    private var indexing: Task<Void, Never>?

    struct Moment: Equatable {
        let callID: String
        let at: TimeInterval
        let id = UUID()
    }

    let paths = Paths.live
    /// Where this iPhone syncs: iCloud (the default), the owner's own server, or nowhere.
    @Published private(set) var syncWith = SyncChoice(rawValue: UserDefaults.standard.string(forKey: "syncWith") ?? "") ?? .icloud
    private var engine: (key: String, sync: CloudSync)?
    private let keychain = Keychain()
    private var chatStore: ChatStore { ChatStore(directory: paths.chats) }
    /// `MOSSAD_ROOT` points the simulator at a sample folder; nothing syncs then.
    private let offline = ProcessInfo.processInfo.environment["MOSSAD_ROOT"] != nil

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
        reload()
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
    }

    /// The owner: the name most often on the mic track, which is the Mac owner's own.
    var owner: String {
        var counts: [String: Int] = [:]
        for r in meetings { for (key, name) in r.speakerNames where key.hasPrefix("me:") { counts[name, default: 0] += 1 } }
        return counts.max { $0.value < $1.value }?.key ?? ""
    }

    /// The AI the Mac shares through iCloud Keychain, when the owner turned that on.
    var languageModel: (any LanguageModel)? {
        guard let shared = SharedAIKey.load(), let provider = AIProvider(rawValue: shared.provider) else { return nil }
        return provider.model(shared.model, apiKey: shared.key, usage: nil)
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

    private var cloud: CloudSync? {
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
        if let engine, engine.key == key { return engine.sync }
        let sync = CloudSync(paths: paths, store: store)
        engine = (key, sync)
        return sync
    }

    func choose(_ choice: SyncChoice) {
        guard choice != syncWith else { return }
        syncWith = choice
        UserDefaults.standard.set(choice.rawValue, forKey: "syncWith")
        engine = nil
        error = nil
        lastSync = nil
        Task { await sync() }
    }

    /// Keeps a checked server on this iPhone and syncs with it.
    func connect(_ c: ServerConnection) {
        try? keychain.set(c.secret, for: .serverSecret)
        UserDefaults.standard.set(c.address.absoluteString, forKey: "serverAddress")
        engine = nil
        syncWith = .icloud
        choose(.server)
    }

    func disconnectServer() {
        keychain.delete(.serverSecret)
        UserDefaults.standard.removeObject(forKey: "serverAddress")
        choose(.icloud)
    }

    func sync() async {
        guard !syncing else { return }
        syncing = true
        defer { syncing = false }
        if let cloud {
            do {
                // One quiet second try: a phone that just woke the app often has no route for a moment.
                try await TransientRetry.run {
                    try await cloud.pull(includeMeetings: true)
                    try await cloud.pushShared()
                }
                await sendOutbox()
                error = nil
                lastSync = Date()
            } catch is CancellationError {
                // The app stopped its own request (a refresh let go, a view closed): not a failure to show.
            } catch let e as URLError where e.code == .cancelled {
            } catch {
                self.error = "Could not reach \(place): \((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)"
            }
        } else if syncWith == .server, !offline {
            error = "Connect your server in Settings."
        }
        reload()
    }

    func reload() {
        meetings = MeetingIndex(paths: paths).all()
        profile = (try? CoachProfile.load(from: paths.coach)) ?? CoachProfile()
        chats = chatStore.all()
        commitments = (try? CommitmentBook.load(from: paths.commitments)) ?? CommitmentBook()
        loadOutbox()
        scores = Dictionary(uniqueKeysWithValues: meetings.compactMap { r in coach(r.id)?.scorecard.map { (r.id, $0.score) } })
        coachVersion += 1
        refreshSearch()
    }

    /// Builds the search index again when meetings or chats changed, and only swaps the tasks when only they did.
    private func refreshSearch() {
        let meetings = meetings, chats = chats, tasks = commitments.items
        if let indexed, indexed.meetings == meetings, indexed.chats == chats {
            searchIndex.setTasks(tasks)
            searchVersion += 1
            return
        }
        indexed = (meetings, chats)
        let people = VoiceLibrary(directory: paths.voices).profiles
        indexing?.cancel()
        indexing = Task {
            let index = await SearchIndex.build(records: meetings, people: people, tasks: tasks, chats: chats)
            let stats = await Task.detached(priority: .userInitiated) { PersonStatistics.compute(meetings) }.value
            guard !Task.isCancelled else { return }
            var latest = index
            latest.setTasks(commitments.items)
            searchIndex = latest
            searchSuggestions = latest.suggestions()
            personStats = stats
            searchVersion += 1
        }
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

    @Published private(set) var recentSearches = UserDefaults.standard.stringArray(forKey: "recentSearches") ?? []

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

    /// Sends what changed here to the sync store, in the background.
    private func share() {
        reload()
        guard let cloud else { return }
        Task { try? await cloud.pushShared() }
    }

    func coach(_ id: String) -> CoachReview? { CoachReview.load(in: paths.callDirectory(id)) }
    func meeting(_ id: String) -> CallRecord? { meetings.first { $0.id == id } }

    func openMeeting(_ id: String) {
        guard meeting(id) != nil else { return }
        tab = .meetings
        path = [id]
    }

    func open(_ link: ChatLink) {
        showMoment(link.callID, at: link.at)
    }

    /// Opens a meeting, at a moment when there is one, as the Mac does for a commitment or a chat link.
    func showMoment(_ id: String, at: TimeInterval?) {
        guard meeting(id) != nil else { return }
        tab = .meetings
        path = [id]
        moment = at.map { Moment(callID: id, at: $0) }
    }

    // MARK: Chat

    func save(_ chat: Chat) {
        try? chatStore.save(chat)
        chats = chatStore.all()
    }

    func delete(_ chat: Chat) {
        chatStore.delete(chat.id)
        share()
    }

    func answer(_ question: String, history: [ChatMessage], about callID: String? = nil,
                onStep: @escaping @Sendable (String) -> Void) async throws -> String {
        guard let llm = languageModel else { throw NoSharedKey() }
        return try await ChatAgent(llm: llm, ownerName: owner).answer(question, history: history, records: meetings, paths: paths,
                                                                      about: callID, onStep: onStep)
    }

    /// Writes the chat's short summary for later chats to recall, then syncs it.
    func finish(_ id: UUID) {
        share()
        guard let llm = languageModel, let chat = chats.first(where: { $0.id == id }) else { return }
        let owner = owner, store = chatStore
        Task {
            guard let summary = try? await ChatAgent(llm: llm, ownerName: owner).summarize(chat),
                  var latest = store.all().first(where: { $0.id == id }) else { return }
            latest.summary = summary
            try? store.save(latest)
            share()
        }
    }

    // MARK: Room recordings

    var recordingsFolder: URL { paths.root.appendingPathComponent("Recordings") }
    private var outboxFile: URL { recordingsFolder.appendingPathComponent("outbox.json") }

    private func loadOutbox() {
        var list = (try? JSONDecoder().decode([Outgoing].self, from: Data(contentsOf: outboxFile))) ?? []
        // Done once the Mac's meeting for it has arrived.
        let arrived = Set(meetings.map(\.id))
        let done = list.filter { $0.sent && arrived.contains($0.id) }
        for d in done { try? FileManager.default.removeItem(at: recordingsFolder.appendingPathComponent("\(d.id).m4a")) }
        list.removeAll { d in done.contains { $0.id == d.id } }
        if !done.isEmpty { saveOutbox(list) }
        outbox = list
    }

    private func saveOutbox(_ list: [Outgoing]) {
        try? FileManager.default.createDirectory(at: recordingsFolder, withIntermediateDirectories: true)
        try? JSONEncoder().encode(list).write(to: outboxFile, options: .atomic)
        outbox = list
    }

    func send(_ recording: PhoneRecording, audio: URL) {
        saveOutbox(outbox + [Outgoing(recording: recording)])
        Task { await sendOutbox() }
    }

    /// Uploads what iCloud does not have yet. The audio stays here until the meeting comes back from the Mac.
    func sendOutbox() async {
        guard let cloud else { return }
        for item in outbox where !item.sent {
            let audio = recordingsFolder.appendingPathComponent("\(item.id).m4a")
            do {
                try await cloud.upload(item.recording, audio: audio)
                var list = outbox
                if let i = list.firstIndex(where: { $0.id == item.id }) { list[i].sent = true }
                saveOutbox(list)
            } catch {
                self.error = "The recording is saved on this iPhone and will be sent when \(place) is reachable."
            }
        }
    }

    // MARK: Commitments

    func changeCommitments(_ change: (inout CommitmentBook) -> Void) {
        var book = (try? CommitmentBook.load(from: paths.commitments)) ?? CommitmentBook()
        change(&book)
        try? book.save(to: paths.commitments)
        share()
    }

    func saveCommitment(_ c: Commitment) {
        changeCommitments { book in
            if book.items.contains(where: { $0.id == c.id }) { book.update(c.id) { $0 = c } } else { book.items.append(c) }
        }
    }

    func toggleDone(_ id: UUID) { changeCommitments { $0.update(id) { $0.done = $0.done == nil ? Date() : nil } } }
    func deleteCommitment(_ id: UUID) { changeCommitments { $0.delete(id) } }

    // MARK: Coach

    /// Saves a 👍 or 👎 on one point. A note goes to the coach as a reply, so it can learn from it.
    func rate(callID: String, point: CoachPoint, agree: Bool, note: String?) async throws {
        let dir = paths.callDirectory(callID)
        guard var review = CoachReview.load(in: dir), let record = meeting(callID) else { return }
        let feedback = CoachFeedback(agree: agree, note: note)
        review.feedback[point.title] = feedback
        try review.save(in: dir)
        var profile = profile
        profile.remember(feedback, on: point, callID: callID, title: record.title)
        try profile.save(to: paths.coach)
        share()
        if let note { try await reply(callID: callID, message: "About your point “\(point.title)”: \(note)") }
    }

    /// Sends a reply to the coach about one review; the answer joins the review's thread, and any new
    /// guidance joins the coach's memory.
    func reply(callID: String, message: String) async throws {
        guard let llm = languageModel else { throw NoSharedKey() }
        let dir = paths.callDirectory(callID)
        guard let review = CoachReview.load(in: dir), let record = meeting(callID) else { return }
        let answer = try await CoachResponder(llm: llm, ownerName: owner).respond(to: message, review: review, record: record, profile: profile)
        var latest = CoachReview.load(in: dir) ?? review
        latest.thread += [ChatMessage(role: .user, text: message), ChatMessage(role: .assistant, text: answer.reply)]
        try latest.save(in: dir)
        var profile = (try? CoachProfile.load(from: paths.coach)) ?? profile
        profile.updateGuidance(add: answer.add, remove: answer.remove, at: Date())
        profile.updateFacts(add: answer.addFacts, remove: answer.removeFacts)
        try profile.save(to: paths.coach)
        share()
    }

    func acceptFocus(_ id: UUID, plan: String?) {
        var profile = profile
        profile.acceptFocus(id, plan: plan, at: Date())
        try? profile.save(to: paths.coach)
        share()
    }

    func answerQuestion(_ id: UUID, _ status: CoachQuestion.Status, note: String?) {
        var profile = profile
        profile.answer(id, status, note: note, at: Date())
        try? profile.save(to: paths.coach)
        share()
    }

    func dismissFocus(_ id: UUID) {
        var profile = profile
        profile.dismissFocus(id, at: Date())
        try? profile.save(to: paths.coach)
        share()
    }

    func addFact(_ kind: CoachFact.Kind, _ text: String) {
        var profile = profile
        profile.updateFacts(add: [CoachFact(kind: kind, text: text)], remove: [])
        try? profile.save(to: paths.coach)
        share()
    }

    func removeFact(_ text: String) {
        var profile = profile
        profile.updateFacts(add: [], remove: [text])
        try? profile.save(to: paths.coach)
        share()
    }

    func removeGuidance(_ text: String) {
        var profile = profile
        profile.updateGuidance(add: [], remove: [text], at: Date())
        try? profile.save(to: paths.coach)
        share()
    }
}

struct NoSharedKey: LocalizedError {
    var errorDescription: String? {
        "Chat on the iPhone uses the AI key from your Mac. In Mossad on your Mac, open Settings and turn on “Use my AI key on my iPhone”."
    }
}
