import Foundation
import MossadCore

enum PhoneTab: Hashable { case meetings, commitments, chat, people, analytics }

/// The phone's copy of the meetings: pulled from iCloud into the app's folder, then read with the same code
/// the Mac uses. Chats, ratings, replies to the coach, and the coach's memory go back up.
@MainActor
final class PhoneStore: ObservableObject {
    @Published private(set) var meetings: [CallRecord] = []
    @Published private(set) var profile = CoachProfile()
    @Published private(set) var chats: [Chat] = []
    @Published private(set) var commitments = CommitmentBook()
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

    let paths = Paths.live
    private lazy var cloud = CloudSync(paths: paths)
    private var chatStore: ChatStore { ChatStore(directory: paths.chats) }
    /// `MOSSAD_ROOT` points the simulator at a sample folder; nothing syncs then.
    private let offline = ProcessInfo.processInfo.environment["MOSSAD_ROOT"] != nil

    init() {
        reload()
        // Development hooks for screenshots: `MOSSAD_OPEN=<call id>` opens a meeting, `MOSSAD_TAB` picks a tab.
        if let id = ProcessInfo.processInfo.environment["MOSSAD_OPEN"], !id.isEmpty { path = [id] }
        switch ProcessInfo.processInfo.environment["MOSSAD_TAB"] {
        case "chat": tab = .chat
        case "commitments": tab = .commitments
        case "people": tab = .people
        case "analytics": tab = .analytics
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

    func sync() async {
        guard !syncing else { return }
        syncing = true
        defer { syncing = false }
        if !offline {
            do {
                try await cloud.pull(includeMeetings: true)
                try await cloud.pushShared()
                error = nil
                lastSync = Date()
            } catch {
                self.error = "Could not reach iCloud: \(error.localizedDescription)"
            }
        }
        reload()
    }

    func reload() {
        meetings = MeetingIndex(paths: paths).all()
        profile = (try? CoachProfile.load(from: paths.coach)) ?? CoachProfile()
        chats = chatStore.all()
        commitments = (try? CommitmentBook.load(from: paths.commitments)) ?? CommitmentBook()
        scores = Dictionary(uniqueKeysWithValues: meetings.compactMap { r in coach(r.id)?.scorecard.map { (r.id, $0.score) } })
        coachVersion += 1
    }

    /// Sends what changed here to iCloud, in the background.
    private func share() {
        reload()
        guard !offline else { return }
        let cloud = cloud
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
        guard meeting(link.callID) != nil else { return }
        tab = .meetings
        path = [link.callID]
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

    func answer(_ question: String, history: [ChatMessage], onStep: @escaping @Sendable (String) -> Void) async throws -> String {
        guard let llm = languageModel else { throw NoSharedKey() }
        return try await ChatAgent(llm: llm, ownerName: owner).answer(question, history: history, records: meetings, paths: paths, onStep: onStep)
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
