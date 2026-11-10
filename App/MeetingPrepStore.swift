import Foundation
import MossadCore

/// What an upcoming meeting's page shows (`MeetingPrep`), worked out off the main thread and kept.
///
/// A page's numbers are kept under a `Key` of cheap stamps and counters. One task makes the numbers of a meeting,
/// and a second asker waits for it. The facts of the earlier meetings come from the cache that the meeting page's
/// Analytics tab fills, so a meeting is read for its talk time one time for both.
@MainActor
final class MeetingPrepStore {
    static let shared = MeetingPrepStore()

    /// What the page can see change, as cheap counters and stamps: no words are compared.
    struct Key: Hashable, Sendable {
        /// The invite's title, times, and people.
        var meeting: Int
        var owner: String
        /// The saved people's names and emails.
        var people: Int
        var coach: Int
        var commitments: Int
        /// Counts every change of any meeting.
        var meetings: Int
        /// "The last 90 days" moves with the day.
        var day: Int

        @MainActor
        init(_ meeting: UpcomingMeeting, controller: AppController) {
            var invite = Hasher()
            invite.combine(meeting.id)
            invite.combine(meeting.end)
            invite.combine(meeting.attendees)
            var people = Hasher()
            for p in controller.library.profiles { people.combine(p.name); people.combine(p.email) }
            self.meeting = invite.finalize()
            owner = controller.ownerName
            self.people = people.finalize()
            coach = controller.coachVersion
            commitments = controller.commitmentsVersion
            meetings = controller.meetingsVersion
            day = Int(Calendar.current.startOfDay(for: Date()).timeIntervalSince1970)
        }
    }

    private static let limit = 12
    private var entries: [String: (key: Key, value: MeetingPrep)] = [:]
    /// Meeting ids, the one used last at the end.
    private var order: [String] = []
    private var running: [String: (key: Key, task: Task<MeetingPrep, Never>)] = [:]

    func cached(_ id: String, key: Key) -> MeetingPrep? {
        entries[id].flatMap { $0.key == key ? $0.value : nil }
    }

    /// The page for `meeting`: from the cache, from the task that is making it, or made now on another thread.
    func prep(for meeting: UpcomingMeeting, key: Key, controller: AppController) async -> MeetingPrep {
        if let hit = cached(meeting.id, key: key) { return hit }
        if let now = running[meeting.id], now.key == key { return await now.task.value }
        let records = controller.meetings, paths = controller.paths, profiles = controller.library.profiles
        // The coach's memory as the other pages show it: read one time for each change of it.
        let facts = MeetingAnalyticsStore.shared.facts, coach = controller.shownCoachProfile.people
        let task = Task.detached(priority: .userInitiated) { () -> MeetingPrep in
            let book = (try? CommitmentBook.load(from: paths.commitments)) ?? CommitmentBook()
            return MeetingPrep(meeting: meeting, owner: key.owner, records: records, facts: facts.facts(for: records, owner: key.owner),
                               commitments: book.items, people: PersonDirectory(profiles: profiles), coach: coach)
        }
        running[meeting.id] = (key, task)
        let made = await task.value
        if running[meeting.id]?.key == key { running[meeting.id] = nil }
        // A later ask can have finished first; its page is newer.
        if let newer = entries[meeting.id], newer.key.meetings > key.meetings { return made }
        entries[meeting.id] = (key, made)
        order.removeAll { $0 == meeting.id }
        order.append(meeting.id)
        while order.count > Self.limit { entries[order.removeFirst()] = nil }
        return made
    }
}
