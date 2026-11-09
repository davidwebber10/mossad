import Foundation

/// The coach's score of each meeting, for the lists. A review file is decoded only when it changed since the last
/// read: the iPhone asks at every return to the app, and reading every review each time grows with every meeting.
public final class CoachScoreCache: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [String: (stamp: String, score: Int?)] = [:]
    private var decodes = 0
    /// How many review files were decoded so far, for tests.
    var decodeCount: Int { lock.withLock { decodes } }

    public init() {}

    /// The scores of the meetings that have one, and a stamp that changes when any review file was added, changed,
    /// or removed.
    public func read(ids: [String], directory: (String) -> URL) -> (scores: [String: Int], stamp: Int) {
        var scores: [String: Int] = [:]
        var stamps = Hasher()
        var kept: [String: (stamp: String, score: Int?)] = [:]
        for id in ids.sorted() {
            let dir = directory(id)
            let path = dir.appendingPathComponent(CoachReview.fileName).path
            guard let a = try? FileManager.default.attributesOfItem(atPath: path) else { continue }
            let stamp = "\(a[.size] as? Int ?? 0)|\((a[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0)|\(a[.systemFileNumber] as? Int ?? 0)"
            stamps.combine(id)
            stamps.combine(stamp)
            let entry: (stamp: String, score: Int?)
            if let hit = lock.withLock({ entries[path] }), hit.stamp == stamp {
                entry = hit
            } else {
                entry = (stamp, CoachReview.load(in: dir)?.scorecard?.score)
                lock.withLock { decodes += 1 }
            }
            kept[path] = entry
            if let score = entry.score { scores[id] = score }
        }
        lock.withLock { entries = kept }
        return (scores, stamps.finalize())
    }
}
