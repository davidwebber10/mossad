import Foundation

/// A stored file that is there but does not decode. It was moved aside to `kept`, so no save can write over it.
public struct UnreadableFile: Error, CustomStringConvertible {
    public let url: URL
    public let kept: URL?
    public let reason: String

    public var description: String {
        "\(url.lastPathComponent) could not be read (\(reason))" + (kept.map { "; it was kept as \($0.lastPathComponent)" } ?? "")
    }
}

/// Reads owner data with "missing is empty, unreadable is not empty": a file that does not decode is moved to
/// `name.unreadable-<date>.json` and the read throws, so a later save starts clean and the old data stays on disk.
public enum StoredFile {
    /// The decoded file, or nil when there is no file. A read error (not a decode error) throws and moves nothing.
    public static func load<T: Decodable>(_ type: T.Type, from url: URL, decoder: JSONDecoder = JSONDecoder(),
                                          now: Date = Date()) throws -> T? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let data = try Data(contentsOf: url)
        do {
            return try decoder.decode(T.self, from: data)
        } catch {
            let kept = quarantine(url, now: now)
            let failure = UnreadableFile(url: url, kept: kept, reason: String(describing: error).prefix(200).description)
            Log.error("\(failure)")
            throw failure
        }
    }

    /// Moves a file aside as `name.unreadable-<date>.ext`. Returns where it went, or nil when it could not move.
    @discardableResult
    public static func quarantine(_ url: URL, now: Date = Date()) -> URL? {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmmss"
        let stamp = f.string(from: now)
        let ext = url.pathExtension
        let base = url.deletingPathExtension().lastPathComponent
        var target = url.deletingLastPathComponent().appendingPathComponent("\(base).unreadable-\(stamp)" + (ext.isEmpty ? "" : ".\(ext)"))
        var n = 2
        while FileManager.default.fileExists(atPath: target.path) {
            target = url.deletingLastPathComponent().appendingPathComponent("\(base).unreadable-\(stamp)-\(n)" + (ext.isEmpty ? "" : ".\(ext)"))
            n += 1
        }
        do {
            try FileManager.default.moveItem(at: url, to: target)
            return target
        } catch {
            Log.error("Could not move \(url.lastPathComponent) aside: \(error)")
            return nil
        }
    }

    /// Whether a file name is a copy moved aside, which readers of a folder must skip.
    public static func isQuarantined(_ url: URL) -> Bool { url.lastPathComponent.contains(".unreadable-") }
}
