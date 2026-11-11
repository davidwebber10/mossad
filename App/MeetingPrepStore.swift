import Foundation
import MossadCore

/// What an upcoming meeting's page shows (`MeetingPrep`), worked out off the main thread and kept.
///
/// A page is made in two steps. The first has everything that the records and the tasks say (last time, the
/// action items, the promises): it needs no history of talk and comes at once. The second adds each person's
/// fact and the series' usual numbers, from the facts of every earlier meeting. Those come from the cache that
/// the meeting page's Analytics tab fills, so a meeting is read for its talk time one time for both; the first
/// read after a launch takes the longest.
///
/// The finished page is kept under a `Key` of cheap stamps and counters. One task makes the page of a meeting,
/// and a second asker waits for it. A page made while the tasks could not be read is never kept: the next ask
/// reads them again.
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
        /// The reads of how people think, which come in after a coach change.
        var reads: Int
        var commitments: Int
        /// Counts every change of any meeting.
        var meetings: Int
        /// "The last 90 days" moves with the day.
        var day: Int
        /// Tasks marked done on the page, which stay on it.
        var keep: Set<UUID>

        @MainActor
        init(_ meeting: UpcomingMeeting, keep: Set<UUID> = [], controller: AppController) {
            var invite = Hasher()
            invite.combine(meeting.id)
            invite.combine(meeting.end)
            invite.combine(meeting.attendees)
            invite.combine(meeting.link)
            var people = Hasher()
            for p in controller.library.profiles { people.combine(p.name); people.combine(p.email) }
            self.meeting = invite.finalize()
            owner = controller.ownerName
            self.people = people.finalize()
            coach = controller.coachVersion
            var reads = Hasher()
            for (id, r) in controller.personaReads.sorted(by: { $0.key < $1.key }) { reads.combine(id); reads.combine(r.updated); reads.combine(r.card?.lines.count) }
            reads.combine(controller.personasOn)
            self.reads = reads.finalize()
            commitments = controller.commitmentsVersion
            meetings = controller.meetingsVersion
            day = Int(Calendar.current.startOfDay(for: Date()).timeIntervalSince1970)
            self.keep = keep
        }
    }

    private static let limit = 12
    private var entries: [String: (key: Key, value: MeetingPrep, asked: Int)] = [:]
    /// Meeting ids, the one used last at the end.
    private var order: [String] = []
    private var running: [String: (key: Key, task: Task<MeetingPrep, Never>)] = [:]
    /// Counts the asks, so a page that was asked for earlier never replaces one asked for later.
    private var asks = 0

    func cached(_ id: String, key: Key) -> MeetingPrep? {
        entries[id].flatMap { $0.key == key ? $0.value : nil }
    }

    /// Everything a page is made from, taken on the main actor.
    private struct Inputs: Sendable {
        let meeting: UpcomingMeeting
        let owner: String
        let records: [CallRecord]
        let profiles: [VoiceProfile]
        let coach: CoachProfile
        let reads: [String: PersonaSummary]
        let people: URL
        let ownerEmails: [String]
        let commitments: URL
        let keep: Set<UUID>

        func prep(facts: [MeetingFacts]?) -> MeetingPrep {
            // Nil when the file is there and cannot be read: the page then says so, not "no tasks".
            MeetingPrep(meeting: meeting, owner: owner, records: records, facts: facts, commitments: CommitmentBook.peek(in: commitments)?.items,
                        people: PersonDirectory(profiles: profiles), ownerEmails: ownerEmails, keep: keep,
                        memory: coach, saved: CoachPeople(people: PeopleStore.peek(in: people) ?? []), reads: reads)
        }
    }

    private func inputs(_ meeting: UpcomingMeeting, key: Key, controller: AppController) -> Inputs {
        // The coach's memory as the other pages show it: read one time for each change of it.
        Inputs(meeting: meeting, owner: key.owner, records: controller.meetings, profiles: controller.library.profiles,
               coach: controller.shownCoachProfile, reads: controller.personasOn ? controller.personaReads : [:], people: controller.paths.people, ownerEmails: [UserDefaults.standard.string(forKey: "ownerEmail") ?? ""],
               commitments: controller.paths.commitments, keep: key.keep)
    }

    /// The page's first step: what the records and the tasks say, with no history of talk. Never kept.
    func first(for meeting: UpcomingMeeting, key: Key, controller: AppController) async -> MeetingPrep {
        if let hit = cached(meeting.id, key: key) { return hit }
        let inputs = inputs(meeting, key: key, controller: controller)
        return await Task.detached(priority: .userInitiated) { inputs.prep(facts: nil) }.value
    }

    /// The whole page for `meeting`: from the cache, from the task that is making it, or made now on another thread.
    func prep(for meeting: UpcomingMeeting, key: Key, controller: AppController) async -> MeetingPrep {
        if let hit = cached(meeting.id, key: key) { return hit }
        if let now = running[meeting.id], now.key == key { return await now.task.value }
        asks += 1
        let asked = asks
        let inputs = inputs(meeting, key: key, controller: controller), facts = MeetingAnalyticsStore.shared.facts
        let task = Task.detached(priority: .userInitiated) {
            inputs.prep(facts: facts.facts(for: inputs.records, owner: inputs.owner))
        }
        running[meeting.id] = (key, task)
        let made = await task.value
        if running[meeting.id]?.key == key { running[meeting.id] = nil }
        // A later ask can have finished first; its page is newer. A page with no tasks to read is not the truth
        // for long.
        if let newer = entries[meeting.id], newer.asked > asked { return made }
        guard made.tasksKnown else { return made }
        entries[meeting.id] = (key, made, asked)
        order.removeAll { $0 == meeting.id }
        order.append(meeting.id)
        while order.count > Self.limit { entries[order.removeFirst()] = nil }
        return made
    }
}
