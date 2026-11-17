import Foundation

/// When a worker runs its queue and its sync: the queue every hour, the sync every 5 minutes (longer after failures,
/// an hour at most), never a sync while a call records, and at once after a pass that changed something.
public struct WorkerPace: Equatable, Sendable {
    public enum Work: Equatable, Sendable { case queue, sync }

    public static let syncEvery: TimeInterval = 300, queueEvery: TimeInterval = 3600, syncMost: TimeInterval = 3600, callLook: TimeInterval = 5

    public var lastSync: Date?
    public var lastQueue: Date?
    public var syncFailures = 0
    /// A pass changed something: the sync is due at once.
    public var syncSoon = false

    public init() {}

    /// 300 × 2^failures, 3600 at most.
    public static func syncWait(failures: Int) -> TimeInterval {
        min(syncMost, syncEvery * pow(2, Double(min(failures, 10))))
    }

    public func due(now: Date, callRecords: Bool) -> (work: [Work], sleep: TimeInterval) {
        var work: [Work] = []
        let queueAt = lastQueue.map { $0.addingTimeInterval(Self.queueEvery) } ?? now
        let syncAt = syncSoon ? now : lastSync.map { $0.addingTimeInterval(Self.syncWait(failures: syncFailures)) } ?? now
        if queueAt <= now { work.append(.queue) }
        let syncDue = syncAt <= now
        if syncDue, !callRecords { work.append(.sync) }
        let nextQueue = work.contains(.queue) ? now.addingTimeInterval(Self.queueEvery) : queueAt
        var sleep = nextQueue.timeIntervalSince(now)
        if syncDue && callRecords {
            sleep = min(sleep, Self.callLook)
        } else {
            let nextSync = work.contains(.sync) ? now.addingTimeInterval(Self.syncWait(failures: syncFailures)) : syncAt
            sleep = min(sleep, nextSync.timeIntervalSince(now))
        }
        return (work, max(1, sleep))
    }

    public mutating func synced(ok: Bool, at: Date) {
        lastSync = at
        syncSoon = false
        syncFailures = ok ? 0 : syncFailures + 1
    }

    public mutating func queued(at: Date) { lastQueue = at }

    public mutating func changed() { syncSoon = true }
}
