import Foundation

/// On-disk layout under `~/Mossad`.
public struct Paths: Sendable {
    public let root: URL

    public init(root: URL) {
        self.root = root
    }

    /// `~/Mossad`, or `$MOSSAD_ROOT` when set (for trying the app against a demo folder).
    public static let live = Paths(root: ProcessInfo.processInfo.environment["MOSSAD_ROOT"].map { URL(fileURLWithPath: $0) } ?? home)

    #if os(macOS)
    private static let home = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Mossad")
    #else
    /// On the iPhone, the meetings synced from the Mac live in the app's own Documents folder.
    private static let home = URL.documentsDirectory.appendingPathComponent("Mossad")
    #endif

    public var meetings: URL { root.appendingPathComponent("Meetings") }
    public var audio: URL { root.appendingPathComponent("Audio") }
    public var voices: URL { root.appendingPathComponent("Voices") }
    public var logs: URL { root.appendingPathComponent("Logs") }
    /// The coach's profile of the owner: patterns, the current focus, and notes on each person.
    public var coach: URL { root.appendingPathComponent("Coach") }
    /// One JSON file per chat in the Chat tab.
    public var chats: URL { root.appendingPathComponent("Chats") }
    /// What the iCloud sync last uploaded or fetched.
    public var sync: URL { root.appendingPathComponent("Sync") }
    /// `usage.jsonl`: each billed request, for the costs in Analytics.
    public var usage: URL { root.appendingPathComponent("Usage") }

    public func callDirectory(_ id: String) -> URL {
        audio.appendingPathComponent(id)
    }

    public func ensureDirectories() throws {
        for dir in [meetings, audio, voices, logs, coach] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }
}
