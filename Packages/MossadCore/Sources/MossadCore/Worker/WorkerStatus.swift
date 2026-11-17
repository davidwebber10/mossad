import Foundation

/// What a worker says about its profile, in its own folder: counts and one kind of failure, never a title, a name,
/// an address, or a meeting's id. The window app reads this one file of another profile and nothing else.
public struct WorkerStatus: Codable, Equatable, Sendable {
    public static let fileName = "status.json"
    public static let currentVersion = 1
    public static let allowedKeys: Set<String> = ["version", "written", "inWork", "failure", "kind", "count"]

    public enum Kind: String, Codable, CaseIterable, Sendable { case key, transcribe, identify, summarize, write, backup, sync }

    public struct Failure: Codable, Equatable, Sendable {
        public var kind: Kind
        public var count: Int
        public init(kind: Kind, count: Int) {
            self.kind = kind
            self.count = count
        }
    }

    public var version: Int
    public var written: Date
    public var inWork: Int
    public var failure: Failure?

    public init(written: Date, inWork: Int, failure: Failure?) {
        version = Self.currentVersion
        self.written = written
        self.inWork = inWork
        self.failure = failure
    }

    /// The first that applies: a key that is missing, the meetings that fail (the kind of the newest), the backup, the sync.
    /// `incoming`: the meetings that another profile moved here and that wait in `Incoming`, which count in work.
    public static func make(records: [CallRecord], incoming: Int = 0, missing: Set<ServiceSettings.MissingKey>, backupFailed: Int,
                            syncFailed: Bool, now: Date) -> WorkerStatus {
        // A meeting whose move waits is not in work here: nothing processes it.
        let inWork = records.filter { ProcessingStep(status: $0.status) != nil && $0.moveTo == nil }
        var failure: Failure?
        let waiting = (missing.contains(.transcription) ? inWork.filter { $0.status == .recorded }.count : 0)
            + (missing.contains(.notes) ? inWork.filter { $0.status == .identified }.count : 0)
        if waiting > 0 { failure = Failure(kind: .key, count: waiting) }
        if failure == nil {
            let week = now.addingTimeInterval(-7 * 86_400)
            let failing: [(end: Date, kind: Kind)] = records.compactMap { r in
                if ProcessingStep(status: r.status) != nil, r.moveTo == nil, r.attempts > 0, let step = UsageStats.Step(failedAt: r.status) {
                    return (r.end, Kind(step))
                }
                if r.status == .failed, let at = r.failedStep, r.end >= week, let step = UsageStats.Step(failedAt: at) {
                    return (r.end, Kind(step))
                }
                return nil
            }
            if let newest = failing.max(by: { $0.end < $1.end }) {
                failure = Failure(kind: newest.kind, count: failing.filter { $0.kind == newest.kind }.count)
            }
        }
        if failure == nil, backupFailed > 0 { failure = Failure(kind: .backup, count: backupFailed) }
        if failure == nil, syncFailed { failure = Failure(kind: .sync, count: 0) }
        return WorkerStatus(written: now, inWork: inWork.count + max(0, incoming), failure: failure)
    }

    public static func url(root: URL) -> URL { Paths(root: root).worker.appendingPathComponent(fileName) }

    /// Nil: no file, not readable, or a newer version. It reads this one file.
    public static func peek(root: URL) -> WorkerStatus? {
        guard let data = try? Data(contentsOf: url(root: root)),
              let status = try? JSONDecoder().decode(WorkerStatus.self, from: data), status.version <= currentVersion else { return nil }
        return status
    }

    /// One atomic write; makes `<root>/Worker`.
    public func save(root: URL) throws {
        let file = Self.url(root: root)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(self).write(to: file, options: .atomic)
    }
}

extension WorkerStatus.Kind {
    init(_ step: UsageStats.Step) {
        switch step {
        case .transcribe, .detect: self = .transcribe
        case .identify: self = .identify
        case .summarize: self = .summarize
        case .write: self = .write
        }
    }
}

/// The switcher's line under another profile.
public enum WorkerStatusLine {
    /// `since`: when the running worker started. A file written before it is the last worker's: the new one is
    /// starting, and the line shows nothing until its first write.
    public static func text(_ status: WorkerStatus?, running: Bool, gaveUp: Bool, since: Date? = nil) -> String? {
        if gaveUp { return "Not running" }
        guard running, let status else { return nil }
        if let since, status.written < since { return nil }
        if let f = status.failure {
            let one = f.count == 1
            switch f.kind {
            case .key: return one ? "1 meeting waits for a key" : "\(f.count) meetings wait for a key"
            case .transcribe: return "Could not transcribe \(meetings(f.count))"
            case .identify: return "Could not name the voices of \(meetings(f.count))"
            case .summarize: return "Could not summarize \(meetings(f.count))"
            case .write: return one ? "Could not write the note of 1 meeting" : "Could not write the notes of \(f.count) meetings"
            case .backup: return one ? "Could not back up 1 recording" : "Could not back up \(f.count) recordings"
            case .sync: return "Could not sync"
            }
        }
        return status.inWork > 0 ? "\(meetings(status.inWork)) in work" : nil
    }

    private static func meetings(_ n: Int) -> String { n == 1 ? "1 meeting" : "\(n) meetings" }
}
