import Foundation

/// Decoded call records, kept while their `call.json` is unchanged, so a list refresh or a sync decodes only the
/// files that changed. Every save is atomic (a new file), so the file number and the modification time change.
final class RecordCache: @unchecked Sendable {
    static let shared = RecordCache()

    private struct Stamp: Equatable {
        var modified: Date?
        var size: Int?
        var file: Int?
    }

    private let lock = NSLock()
    private var entries: [String: (stamp: Stamp, record: CallRecord)] = [:]
    private var unreadable: [String: Stamp] = [:]
    private var decodes = 0
    /// How many records were decoded from disk so far, for tests of what reads the files.
    var decodeCount: Int { lock.withLock { decodes } }

    /// The record in `dir`, decoded only when the file changed since the last read. Throws when it cannot be read.
    func record(in dir: URL) throws -> CallRecord {
        let url = dir.appendingPathComponent(CallRecord.fileName)
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let stamp = Stamp(modified: attributes[.modificationDate] as? Date, size: (attributes[.size] as? NSNumber)?.intValue,
                          file: (attributes[.systemFileNumber] as? NSNumber)?.intValue)
        if let hit = lock.withLock({ entries[url.path] }), hit.stamp == stamp { return hit.record }
        do {
            let record = try CallRecord.load(from: dir)
            lock.withLock { decodes += 1; entries[url.path] = (stamp, record); unreadable[url.path] = nil }
            return record
        } catch {
            // The file stays where it is: nothing saves over a record that cannot be read. Said once per version
            // of the file, because every list refresh comes through here.
            if lock.withLock({ unreadable.updateValue(stamp, forKey: url.path) != stamp }) {
                Log.error("The record of \(dir.lastPathComponent) cannot be read; the meeting is left out and its files are kept: \(String(describing: error).prefix(200))")
            }
            throw error
        }
    }

    /// Drops the entries under `root` that are not in `kept`, so deleted calls do not stay in memory.
    func prune(root: URL, kept: Set<String>) {
        let prefix = root.path + "/"
        lock.withLock {
            entries = entries.filter { !$0.key.hasPrefix(prefix) || kept.contains($0.key) }
        }
    }
}

/// One read of every call folder: the records, the folders that exist, and the ones whose record could not be read.
public struct RecordScan: Sendable {
    public var records: [CallRecord]
    /// Every call folder's name, readable or not. A folder that is here is not a deleted meeting.
    public var folders: Set<String>
    /// Folders whose `call.json` is missing or could not be read.
    public var unreadable: [String]
}
