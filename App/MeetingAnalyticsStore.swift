import Foundation
import MossadCore

/// The numbers of the meeting page's Analytics tab, worked out off the main thread and kept.
///
/// Three things keep the work small. A meeting's numbers are kept under a `Key` of cheap stamps and counters. One
/// task makes the numbers of a call, and a second asker waits for it. And when the key changed only because some
/// meeting changed, the numbers are made again only if that meeting is one this call is compared with: the facts
/// of every earlier meeting are kept apart (`MeetingFactsCache`, which reads only a changed meeting), and their
/// stamps say whether this call's history is still the same.
@MainActor
final class MeetingAnalyticsStore {
    static let shared = MeetingAnalyticsStore()

    /// What the tab can see change, as cheap counters and stamps: no words are compared.
    struct Key: Hashable, Sendable {
        /// `MeetingAnalytics.stamp` of the record.
        var record: Int
        var owner: String
        /// The saved people's names and emails.
        var people: Int
        var coach: Int
        var commitments: Int
        /// Counts every change of any meeting.
        var meetings: Int
    }

    /// What the numbers are really made from. Two keys that differ only in `meetings` often have one of these.
    private struct Inputs: Equatable, Sendable {
        var record: Int
        var owner: String
        var people: Int
        var coach: Int
        var commitments: Int
        /// The ids and stamps of the meetings that started before this call.
        var history: Int
        /// The usage log's size and date: a new cost for this call changes it.
        var usage: String
    }

    private struct Entry {
        var key: Key
        var inputs: Inputs
        var value: MeetingAnalytics
    }

    private static let limit = 16
    private var entries: [String: Entry] = [:]
    /// Call ids, the one used last at the end.
    private var order: [String] = []
    private var running: [String: (key: Key, task: Task<(Inputs, MeetingAnalytics), Never>)] = [:]
    private let facts = MeetingFactsCache()

    func cached(_ callID: String, key: Key) -> MeetingAnalytics? {
        entries[callID].flatMap { $0.key == key ? $0.value : nil }
    }

    /// The numbers for `record`: from the cache, from the task that is making them, or made now on another thread.
    func analytics(for record: CallRecord, key: Key, controller: AppController) async -> MeetingAnalytics {
        if let hit = cached(record.id, key: key) { return hit }
        if let now = running[record.id], now.key == key { return await now.task.value.1 }
        let records = controller.meetings, usage = controller.usage, paths = controller.paths
        let profiles = controller.library.profiles, facts = facts
        let before = entries[record.id].map { ($0.inputs, $0.value) }
        let task = Task.detached(priority: .userInitiated) { () -> (Inputs, MeetingAnalytics) in
            let history = facts.facts(for: records, owner: key.owner)
            var stamps = Hasher()
            for f in history where f.id != record.id && f.start < record.start {
                stamps.combine(f.id)
                stamps.combine(f.stamp)
            }
            let log = try? FileManager.default.attributesOfItem(atPath: paths.usage.appendingPathComponent(UsageLog.fileName).path)
            let inputs = Inputs(record: key.record, owner: key.owner, people: key.people, coach: key.coach, commitments: key.commitments,
                                history: stamps.finalize(),
                                usage: "\((log?[.size] as? NSNumber)?.intValue ?? 0)|\((log?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0)")
            // Another meeting changed, and this call is not compared with it: the numbers stand.
            if let before, before.0 == inputs { return (inputs, before.1) }
            let book = (try? CommitmentBook.load(from: paths.commitments)) ?? CommitmentBook()
            let logged = usage.events(forCall: record.id)
            let made = MeetingAnalytics(record: record, owner: key.owner, review: CoachReview.load(in: paths.callDirectory(record.id)),
                                        usage: logged.events, usageSince: logged.since, history: history,
                                        // Read for the few meetings of the series only, and only when the numbers are made.
                                        value: { CoachReview.load(in: paths.callDirectory($0))?.value?.rating },
                                        people: PersonDirectory(profiles: profiles), commitments: book.items)
            return (inputs, made)
        }
        running[record.id] = (key, task)
        let (inputs, made) = await task.value
        if running[record.id]?.key == key { running[record.id] = nil }
        // A later ask can have finished first; its numbers are newer.
        if let newer = entries[record.id], newer.key.meetings > key.meetings { return made }
        entries[record.id] = Entry(key: key, inputs: inputs, value: made)
        order.removeAll { $0 == record.id }
        order.append(record.id)
        while order.count > Self.limit { entries[order.removeFirst()] = nil }
        return made
    }
}
