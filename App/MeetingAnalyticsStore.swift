import Foundation
import MossadCore

/// The numbers of the meeting page's Analytics tab, worked out off the main thread and kept. A meeting's numbers
/// are made again only when its `Key` changes: the record, the people, the coach, or another meeting changed. The
/// facts of every earlier meeting are kept apart (`MeetingFactsCache`), so a change to one meeting reads one meeting.
@MainActor
final class MeetingAnalyticsStore {
    static let shared = MeetingAnalyticsStore()

    /// Everything the numbers are made from, as cheap counters and stamps: no words are compared.
    struct Key: Hashable {
        /// `MeetingAnalytics.stamp` of the record.
        var record: Int
        var owner: String
        /// The saved people's names and emails.
        var people: Int
        var coach: Int
        var commitments: Int
        var meetings: Int
    }

    private static let limit = 16
    private var entries: [String: (key: Key, value: MeetingAnalytics)] = [:]
    /// Call ids, the one used last at the end.
    private var order: [String] = []
    private let facts = MeetingFactsCache()

    func cached(_ callID: String, key: Key) -> MeetingAnalytics? {
        entries[callID].flatMap { $0.key == key ? $0.value : nil }
    }

    /// The numbers for `record`, from the cache or made now on another thread.
    func analytics(for record: CallRecord, key: Key, controller: AppController) async -> MeetingAnalytics {
        if let hit = cached(record.id, key: key) { return hit }
        let records = controller.meetings, owner = controller.ownerName, usage = controller.usage, paths = controller.paths
        let profiles = controller.library.profiles, facts = facts
        let made = await Task.detached(priority: .userInitiated) {
            let book = (try? CommitmentBook.load(from: paths.commitments)) ?? CommitmentBook()
            return MeetingAnalytics(record: record, owner: owner, review: CoachReview.load(in: paths.callDirectory(record.id)),
                                    usage: usage.all(), history: facts.facts(for: records, owner: owner),
                                    // Read for the few meetings of the series only, and only when the numbers are made.
                                    value: { CoachReview.load(in: paths.callDirectory($0))?.value?.rating },
                                    people: PersonDirectory(profiles: profiles), commitments: book.items)
        }.value
        entries[record.id] = (key, made)
        order.removeAll { $0 == record.id }
        order.append(record.id)
        while order.count > Self.limit { entries[order.removeFirst()] = nil }
        return made
    }
}
