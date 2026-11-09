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
    /// What the app must still do about a file that was set aside. Kept beside it as `name.recovered`.
    public struct Recovery: Codable, Equatable, Sendable {
        /// The file's own name, such as "profile.json".
        public var file: String
        /// The name of the copy that was set aside.
        public var kept: String
        public var at: Date
        /// The store starts empty and must take the other device's copy before it sends or runs anything: an empty
        /// store that syncs first would replace the good copy everywhere.
        public var awaitsMerge: Bool
        /// The owner was told.
        public var told: Bool
    }

    public enum RecoveryKind: Sendable {
        /// Only on this Mac (voices, share links): start empty and tell the owner.
        case local
        /// Also in the sync store (coach profile, commitments): take that copy first.
        case synced
    }

    static func marker(for url: URL) -> URL { url.appendingPathExtension("recovered") }

    public static func recovery(of url: URL) -> Recovery? {
        (try? Data(contentsOf: marker(for: url))).flatMap { try? JSONDecoder.callRecord.decode(Recovery.self, from: $0) }
    }

    private static func write(_ r: Recovery?, for url: URL) {
        guard let r else { try? FileManager.default.removeItem(at: marker(for: url)); return }
        do { try JSONEncoder.callRecord.encode(r).write(to: marker(for: url), options: .atomic) } catch {
            Log.error("Could not note that \(url.lastPathComponent) was set aside: \(error)")
        }
    }

    /// Whether this file was set aside and its store has not taken the other device's copy yet.
    public static func awaitsMerge(_ url: URL) -> Bool { recovery(of: url)?.awaitsMerge == true }

    /// The other device's copy was merged in, or there is no other copy to wait for.
    public static func merged(_ url: URL) {
        guard var r = recovery(of: url), r.awaitsMerge else { return }
        r.awaitsMerge = false
        write(r.told ? nil : r, for: url)
    }

    /// The files in these folders that were set aside and that the owner has not heard about. Each is marked as
    /// told, so the owner hears of it one time.
    public static func takeUntold(in folders: [URL]) -> [Recovery] {
        var out: [Recovery] = []
        for folder in folders {
            for file in (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
            where file.pathExtension == "recovered" {
                let url = file.deletingPathExtension()
                guard var r = recovery(of: url), !r.told else { continue }
                out.append(r)
                r.told = true
                write(r.awaitsMerge ? r : nil, for: url)
            }
        }
        return out.sorted { $0.at < $1.at }
    }

    /// The decoded file, or nil when there is no file. A read error (not a decode error) throws and moves nothing.
    /// With `recovery`, a file that is set aside leaves a note for the app: tell the owner, and for a synced
    /// store, merge the other device's copy first.
    public static func load<T: Decodable>(_ type: T.Type, from url: URL, decoder: JSONDecoder = JSONDecoder(),
                                          recovery kind: RecoveryKind? = nil, now: Date = Date()) throws -> T? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let data = try Data(contentsOf: url)
        do {
            return try decoder.decode(T.self, from: data)
        } catch {
            let kept = quarantine(url, now: now)
            if let kind, let kept {
                write(Recovery(file: url.lastPathComponent, kept: kept.lastPathComponent, at: now, awaitsMerge: kind == .synced, told: false), for: url)
            }
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
