import Foundation

/// `foreground.json`, beside the registry: who the app in front is, whether a call records, and whether the
/// workers must stop. State, not an event: a worker that starts late reads the truth at its next check.
public struct ForegroundState: Codable, Equatable, Sendable {
    public static let fileName = "foreground.json"
    public static let currentVersion = 1

    public var version: Int
    public var pid: Int32
    /// The start time of that pid, so a reused pid is not taken for the app. Nil in a file written by hand.
    public var started: Date?
    public var recording: Bool
    public var stopping: Bool

    public init(pid: Int32, started: Date?, recording: Bool, stopping: Bool = false) {
        version = Self.currentVersion
        self.pid = pid
        self.started = started
        self.recording = recording
        self.stopping = stopping
    }

    /// Beside the registry in use: the real folder, or the folder of the `MOSSAD_PROFILES` file.
    public static func url(home: URL, environment: [String: String]) -> URL {
        if let file = environment["MOSSAD_PROFILES"], !file.isEmpty {
            return URL(fileURLWithPath: file).deletingLastPathComponent().appendingPathComponent(fileName)
        }
        return ProfileRegistry.folder(home: home).appendingPathComponent(fileName)
    }

    public enum Read: Equatable, Sendable { case state(ForegroundState), missing, unreadable }

    /// A newer version, or a file that does not decode, is unreadable: then a worker assumes that a call records.
    public static func read(_ file: URL) -> Read {
        guard let data = try? Data(contentsOf: file) else {
            return FileManager.default.fileExists(atPath: file.path) ? .unreadable : .missing
        }
        guard let state = try? JSONDecoder().decode(ForegroundState.self, from: data), state.version <= currentVersion else { return .unreadable }
        return .state(state)
    }

    /// Each write of the app: its start, a `resume` (after a refused or taken-back switch, or a delete), a restart
    /// of a worker, a change (a call, a stop for a switch), and the quit.
    public enum Write: CaseIterable, Sendable {
        case start, resume, restart, change, quit
        /// The app is the app in front again: the file becomes its own, whoever wrote it last.
        public var takesOver: Bool {
            switch self {
            case .start, .resume, .restart: true
            case .change, .quit: false
            }
        }
    }

    /// An app writes the file only while it is the app in front. Its start takes the file over (`takeOver`); any
    /// later write leaves a file of another app that lives (the new app after a switch) as it is, so an old app's
    /// quit cannot stop the new app's workers.
    public static func mayWrite(over read: Read, pid: Int32, alive: (ForegroundState) -> Bool, takeOver: Bool = false) -> Bool {
        guard !takeOver, case .state(let state) = read, state.pid != pid else { return true }
        return !alive(state)
    }

    public func write(to file: URL) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(self).write(to: file, options: .atomic)
    }
}

/// Facts about a process, asked of the kernel for that one pid. Looking never takes a lock.
public enum ProcessFacts {
    /// The start time of that pid, or nil when no such process lives.
    public static func startTime(of pid: Int32) -> Date? {
        guard pid > 0 else { return nil }
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var name: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&name, 4, &info, &size, nil, 0) == 0, size > 0, info.kp_proc.p_pid == pid else { return nil }
        let t = info.kp_proc.p_un.__p_starttime
        return Date(timeIntervalSince1970: Double(t.tv_sec) + Double(t.tv_usec) / 1_000_000)
    }

    /// The parent of that pid, or nil when no such process lives.
    public static func parent(of pid: Int32) -> Int32? {
        guard pid > 0 else { return nil }
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var name: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&name, 4, &info, &size, nil, 0) == 0, size > 0, info.kp_proc.p_pid == pid else { return nil }
        return info.kp_eproc.e_ppid
    }

    /// The pid lives, and its start time is within 1 s of `started` when one is given.
    public static func isAlive(pid: Int32, started: Date?) -> Bool {
        guard let now = startTime(of: pid) else { return false }
        guard let started else { return true }
        return abs(now.timeIntervalSince(started)) <= 1
    }
}

/// The pure rule of a worker's watch: what each read of the foreground file means.
public struct ForegroundWatch: Equatable, Sendable {
    public enum Stop: String, Sendable { case told, foregroundGone, noForeground }
    public enum Order: Equatable, Sendable { case work(callRecords: Bool), stop(Stop) }

    /// The last good read.
    public private(set) var known: ForegroundState?

    public init() {}

    public mutating func next(_ read: ForegroundState.Read, alive: (ForegroundState) -> Bool) -> Order {
        switch read {
        case .state(let state):
            if state.stopping { return .stop(.told) }
            guard alive(state) else { return .stop(.foregroundGone) }
            known = state
            return .work(callRecords: state.recording)
        case .missing:
            return .stop(known == nil ? .noForeground : .foregroundGone)
        case .unreadable:
            // Unknown is not "no call": a file that cannot be read means a call records, while the app lives.
            guard let known else { return .stop(.noForeground) }
            return alive(known) ? .work(callRecords: true) : .stop(.foregroundGone)
        }
    }
}
