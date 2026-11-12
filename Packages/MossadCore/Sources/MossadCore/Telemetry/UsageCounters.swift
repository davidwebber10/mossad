import Foundation
import Synchronization

/// The few things the statistics count that no record keeps: the days the app ran, and the failures of each kind
/// by day. Only the last 14 days are kept, and only on this Mac.
public struct UsageCounters: Codable, Equatable, Sendable {
    /// "2026-11-12" for each day the app ran, in the Mac's time zone.
    public var activeDays: Set<String> = []
    /// Day, then the kind of failure, then how many.
    public var errors: [String: [String: Int]] = [:]

    public init() {}

    static let keepDays = 14

    public mutating func markActive(at date: Date, calendar: Calendar = .current) {
        activeDays.insert(Self.day(date, calendar))
        prune(now: date, calendar: calendar)
    }

    public mutating func record(_ step: UsageStats.Step, at date: Date, calendar: Calendar = .current) {
        errors[Self.day(date, calendar), default: [:]][step.rawValue, default: 0] += 1
        prune(now: date, calendar: calendar)
    }

    /// The days of the last 7, today among them, on which the app ran.
    public func daysActive7(now: Date, calendar: Calendar = .current) -> Int {
        activeDays.intersection(Self.days(7, before: now, calendar)).count
    }

    public func errors7(now: Date, calendar: Calendar = .current) -> [UsageStats.Step: Int] {
        var out: [UsageStats.Step: Int] = [:]
        for day in Self.days(7, before: now, calendar) {
            for (kind, n) in errors[day] ?? [:] {
                if let step = UsageStats.Step(rawValue: kind) { out[step, default: 0] += n }
            }
        }
        return out
    }

    /// Forgets the days before the last 14. A date in the past (a clock that went back) removes nothing newer.
    private mutating func prune(now: Date, calendar: Calendar) {
        guard let first = calendar.date(byAdding: .day, value: -(Self.keepDays - 1), to: calendar.startOfDay(for: now)) else { return }
        let cutoff = Self.day(first, calendar)
        activeDays = activeDays.filter { $0 >= cutoff }
        errors = errors.filter { $0.key >= cutoff }
    }

    static func day(_ date: Date, _ calendar: Calendar) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    static func days(_ count: Int, before now: Date, _ calendar: Calendar) -> Set<String> {
        let today = calendar.startOfDay(for: now)
        return Set((0..<count).compactMap { calendar.date(byAdding: .day, value: -$0, to: today).map { day($0, calendar) } })
    }
}

/// `usage-stats.json` in the Usage folder: the counters, changed from any thread. Never synced.
public final class UsageCounterStore: Sendable {
    public static let fileName = "usage-stats.json"
    private let file: URL
    /// True after `delete()`: a count already on its way when the owner turned the statistics off writes nothing.
    private let closed = Mutex(false)

    public init(directory: URL) {
        file = directory.appendingPathComponent(Self.fileName)
    }

    public func read() -> UsageCounters {
        closed.withLock { _ in load() }
    }

    public func markActive(at date: Date = Date()) {
        change { $0.markActive(at: date) }
    }

    public func record(_ step: UsageStats.Step, at date: Date = Date()) {
        change { $0.record(step, at: date) }
    }

    /// Turning the statistics off forgets what was counted, and nothing is counted until `reopen()`.
    public func delete() {
        closed.withLock { closed in
            closed = true
            try? FileManager.default.removeItem(at: file)
        }
    }

    /// Turning the statistics on again.
    public func reopen() {
        closed.withLock { $0 = false }
    }

    private func change(_ body: (inout UsageCounters) -> Void) {
        closed.withLock { closed in
            guard !closed else { return }
            var c = load()
            let before = c
            body(&c)
            guard c != before, let data = try? JSONEncoder().encode(c) else { return }
            try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: file, options: .atomic)
        }
    }

    private func load() -> UsageCounters {
        (try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode(UsageCounters.self, from: $0) } ?? UsageCounters()
    }
}
