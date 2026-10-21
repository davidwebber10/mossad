import Foundation

/// On-disk layout under `~/Mossad`.
public struct Paths: Sendable {
    public let root: URL

    public init(root: URL) {
        self.root = root
    }

    /// `~/Mossad`, or `$MOSSAD_ROOT` when set (for trying the app against a demo folder).
    public static let live = Paths(root: ProcessInfo.processInfo.environment["MOSSAD_ROOT"].map { URL(fileURLWithPath: $0) }
        ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Mossad"))

    public var meetings: URL { root.appendingPathComponent("Meetings") }
    public var audio: URL { root.appendingPathComponent("Audio") }
    public var voices: URL { root.appendingPathComponent("Voices") }
    public var logs: URL { root.appendingPathComponent("Logs") }

    public func callDirectory(_ id: String) -> URL {
        audio.appendingPathComponent(id)
    }

    public func ensureDirectories() throws {
        for dir in [meetings, audio, voices, logs] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }
}
