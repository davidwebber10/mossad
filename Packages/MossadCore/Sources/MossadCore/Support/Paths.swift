import Foundation

/// On-disk layout under `~/Mossad`.
public struct Paths: Sendable {
    public let root: URL

    public init(root: URL) {
        self.root = root
    }

    /// `~/Mossad` (`~/Mossad Rehearsal` for the Rehearsal app), or `$MOSSAD_ROOT` when set (for trying the app
    /// against a demo folder).
    #if os(macOS)
    public static let live = Paths(root: AppIdentity.current.dataRoot(home: FileManager.default.homeDirectoryForCurrentUser,
                                                                     environment: ProcessInfo.processInfo.environment))
    #else
    /// On the iPhone, the meetings synced from the Mac live in the app's own Documents folder.
    public static let live = Paths(root: ProcessInfo.processInfo.environment["MOSSAD_ROOT"].map { URL(fileURLWithPath: $0) }
        ?? URL.documentsDirectory.appendingPathComponent("Mossad"))
    #endif

    public var meetings: URL { root.appendingPathComponent("Meetings") }
    public var audio: URL { root.appendingPathComponent("Audio") }
    public var voices: URL { root.appendingPathComponent("Voices") }
    public var logs: URL { root.appendingPathComponent("Logs") }
    /// The coach's profile of the owner: patterns, the current focus, and notes on each person.
    public var coach: URL { root.appendingPathComponent("Coach") }
    /// One JSON file per chat in the Chat tab.
    public var chats: URL { root.appendingPathComponent("Chats") }
    public var commitments: URL { root.appendingPathComponent("Commitments") }
    /// The owner's points for the next meeting of a series or the next time they see a person.
    public var nextTime: URL { root.appendingPathComponent("NextTime") }
    /// What the iCloud sync last uploaded or fetched.
    public var sync: URL { root.appendingPathComponent("Sync") }
    /// The owner's share links, so they can be updated or stopped.
    public var shares: URL { root.appendingPathComponent("Shares") }
    /// The upcoming meetings the owner chose not to record.
    public var noRecord: URL { root.appendingPathComponent("NoRecord") }
    /// `upcoming.json`: the calendar's events as the app last read them, for the tools of other AI apps, which
    /// cannot read the calendar themselves.
    public var calendar: URL { root.appendingPathComponent("Calendar") }
    /// `usage.jsonl`: each billed request, for the costs in Analytics.
    public var usage: URL { root.appendingPathComponent("Usage") }

    /// The people (`people.json`, with its log and the migration's plan and report), the HR export, and the
    /// owner's matches to it. Only the people sync, from the Mac to the phone, as `SyncedPeople` (a list of allowed
    /// fields); the log, the HR data, the matches, and `local.json` never do.
    public var people: URL { root.appendingPathComponent("People") }

    /// Copies made before a migration changed a file, so it can be undone by hand.
    public var backups: URL { root.appendingPathComponent("Backups") }

    public func callDirectory(_ id: String) -> URL {
        audio.appendingPathComponent(id)
    }

    public func ensureDirectories() throws {
        for dir in [meetings, audio, voices, logs, coach, people] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }
}
