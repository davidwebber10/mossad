import Foundation

/// How often a paid request for one item (a call's review, a call's commitments, a period's email) failed, and when
/// it may be tried again. The pipeline steps have their own count in `call.json`; this is the same rule for the
/// jobs that run after the pipeline, which before tried a failing call again on every run, each time billed.
public struct RetryLedger: Codable, Equatable, Sendable {
    public static let fileName = "retries.json"
    /// After this many failed tries the item is left out, with its reason, until the owner asks again.
    public static let maxAttempts = 3
    /// The wait after the first, second, and third failure.
    static let backoff: [TimeInterval] = [3600, 6 * 3600, 86_400]

    public struct Entry: Codable, Equatable, Sendable {
        public var attempts: Int
        public var next: Date
        public var reason: String
    }

    public enum State: Equatable, Sendable { case ready, waiting, gaveUp }

    public private(set) var entries: [String: Entry] = [:]

    public init() {}

    public func state(_ key: String, now: Date) -> State {
        guard let e = entries[key] else { return .ready }
        if e.attempts >= Self.maxAttempts { return .gaveUp }
        return e.next <= now ? .ready : .waiting
    }

    public func reason(_ key: String) -> String? { entries[key]?.reason }

    public mutating func fail(_ key: String, reason: String, now: Date) {
        let attempts = (entries[key]?.attempts ?? 0) + 1
        entries[key] = Entry(attempts: attempts, next: now.addingTimeInterval(Self.backoff[min(attempts, Self.backoff.count) - 1]),
                             reason: String(reason.prefix(300)))
    }

    public mutating func clear(_ key: String) { entries[key] = nil }

    /// A failure that the provider did not bill and that can pass by itself: no connection, a busy or failing
    /// server, a missing or refused key. These wait for the next run and never use up tries.
    public static func isUnbilled(_ error: Error) -> Bool {
        if error is URLError || error is MissingAPIKey { return true }
        let code: Int? = switch error {
        case SummaryError.http(let c, _): c
        case ProviderError.http(_, let c, _): c
        case TranscriptionError.http(let c, _): c
        default: nil
        }
        guard let code else { return false }
        return code >= 500 || [401, 403, 408, 429].contains(code)
    }

    /// A ledger that cannot be read starts empty: it only limits retries, and the worst case is one more try.
    public static func load(from dir: URL) -> RetryLedger {
        (try? StoredFile.load(RetryLedger.self, from: dir.appendingPathComponent(fileName), decoder: .coach)) ?? RetryLedger()
    }

    public func save(to dir: URL) {
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try JSONEncoder.coach.encode(self).write(to: dir.appendingPathComponent(Self.fileName), options: .atomic)
        } catch {
            Log.error("Saving the retry list failed: \(error)")
        }
    }
}
