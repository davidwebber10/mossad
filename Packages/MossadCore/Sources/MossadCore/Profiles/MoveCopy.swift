import CryptoKit
import Darwin
import Foundation

/// The end of the process at a sub-step, in a test: no clean-up runs after it, as after a real stop.
public struct MoveStop: Error, Equatable {
    public init() {}
}

/// Low file operations of a move: an exclusive `rename(2)` that refuses another volume, and `F_FULLFSYNC`.
public enum MoveFiles {
    /// The meeting's folder is on another volume: a rename cannot move it in one step.
    public struct OtherVolume: Error {}
    /// The place of a rename is taken: an exclusive rename never replaces anything.
    public struct Taken: Error {}
    public struct Failed: Error { public var code: Int32 }

    public typealias Rename = (String, String) -> Int32

    /// `renamex_np` with `RENAME_EXCL`: one atomic step, never onto an existing name, not even an empty folder. Returns 0
    /// or the `errno`.
    public static func exclusive(_ from: String, _ to: String) -> Int32 { renamex_np(from, to, UInt32(RENAME_EXCL)) == 0 ? 0 : errno }

    public static func rename(_ from: URL, to: URL, with rename: Rename = exclusive) throws {
        switch rename(from.path, to.path) {
        case 0: return
        case EXDEV: throw OtherVolume()
        case EEXIST, ENOTEMPTY: throw Taken()
        case let code: throw Failed(code: code)
        }
    }

    /// The file or folder on the disk itself, not only in the cache of the system.
    public static func fullSync(_ url: URL) throws {
        let fd = open(url.path, O_RDONLY)
        guard fd >= 0 else { throw Failed(code: errno) }
        defer { close(fd) }
        if fcntl(fd, F_FULLFSYNC) != 0, fsync(fd) != 0 { throw Failed(code: errno) }
    }
}

/// The first profile's copy of a meeting into the target's `Incoming/<id>.<token>.part`, checked file by file, with
/// `move.json` written last; then one exclusive rename publishes it as `Incoming/<id>`. The first profile's folder never
/// changes. A failure removes the part; a stop (the end of the process) leaves it, and the next launch copies again.
public enum MoveCopy {
    public struct Source: Equatable, Sendable {
        public var from: URL
        /// The path under `Incoming/<id>`: "call/me.caf".
        public var path: String
    }

    public struct Plan: Equatable, Sendable {
        public var to: String
        /// Prepared.
        public var record: CallRecord
        public var ownerKeys: [String]
        public var files: [Source]
        /// The chats that go, prepared.
        public var chats: [Chat]
        /// The chats of the call that read other things: deleted in this profile with the meeting.
        public var deletedChats: [UUID]
        public var bytes: Int64
    }

    public enum Refused: Error, Equatable { case inWork, unknownFile }
    public struct NotTheSame: Error {}
    public typealias OtherVolume = MoveFiles.OtherVolume

    public static func plan(_ callID: String, in paths: Paths, to target: String, owner: OwnerIdentity, fetched: URL?) throws -> Plan {
        let dir = paths.callDirectory(callID)
        let r = try CallRecord.load(from: dir)
        let names = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        if MovedFiles.inWork(names) { throw Refused.inWork }
        if !MovedFiles.unknown(names).isEmpty { throw Refused.unknownFile }
        var files = try MovedFiles.list(in: dir).map { Source(from: dir.appendingPathComponent($0), path: "\(MoveMarker.callFolder)/\($0)") }
        if let fetched, !files.contains(where: { $0.path == "\(MoveMarker.callFolder)/\(Recording.fileName)" }) {
            files.append(Source(from: fetched, path: "\(MoveMarker.callFolder)/\(Recording.fileName)"))
        }
        let others = Set(ProcessingQueue(paths: paths).allRecords().filter { $0.id != callID }.map(\.title))
        let chats = ChatStore(directory: paths.chats).all().filter { $0.callID == callID }
        let split = MovedChats.split(chats, title: r.title, otherTitles: others)
        let bytes = files.reduce(Int64(0)) { $0 + (size($1.from) ?? 0) }
        return Plan(to: target, record: MovedRecord.prepared(r, to: target), ownerKeys: MovedRecord.ownerKeys(r, owner: owner), files: files,
                    chats: split.moved, deletedChats: split.deleted.map(\.id), bytes: bytes)
    }

    /// No audio on this Mac, and a backup copy that the record names.
    public static func needsFetch(_ r: CallRecord, in dir: URL) -> Bool {
        let fm = FileManager.default
        let none = [Recording.fileName, "me.caf", "them.caf"].allSatisfy { !fm.fileExists(atPath: dir.appendingPathComponent($0).path) }
        return none && r.cloudKey != nil
    }

    public static func size(_ url: URL) -> Int64? {
        ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.int64Value
    }

    /// Copies one file in pieces of 1 MB, synced to the disk, and gives the source's size and hash as read.
    public typealias FileCopy = (URL, URL, (Int64) -> Void) throws -> (size: Int64, sha256: String)

    public static func file(_ from: URL, _ to: URL, _ progress: (Int64) -> Void) throws -> (size: Int64, sha256: String) {
        let input = try FileHandle(forReadingFrom: from)
        defer { try? input.close() }
        FileManager.default.createFile(atPath: to.path, contents: nil)
        let output = try FileHandle(forWritingTo: to)
        defer { try? output.close() }
        var hasher = SHA256Hasher()
        var total: Int64 = 0
        while let chunk = try input.read(upToCount: 1 << 20), !chunk.isEmpty {
            try output.write(contentsOf: chunk)
            hasher.update(chunk)
            total += Int64(chunk.count)
            progress(total)
        }
        try output.synchronize()
        if fcntl(output.fileDescriptor, F_FULLFSYNC) != 0 { try output.synchronize() }
        return (total, hasher.hex)
    }

    /// Whether the volume has room for the copy; nil when not known.
    public static func room(for bytes: Int64, at folder: URL) -> Bool? {
        var probe = folder
        while !FileManager.default.fileExists(atPath: probe.path), probe.pathComponents.count > 1 { probe.deleteLastPathComponent() }
        guard let free = (try? probe.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?.volumeAvailableCapacityForImportantUsage
        else { return nil }
        return free > bytes + 50_000_000
    }

    public static func part(_ callID: String, token: String, incoming: URL) -> URL {
        incoming.appendingPathComponent("\(callID).\(token)\(MoveMarker.partSuffix)")
    }

    /// This move's own part is there, whole: its `move.json` is in it.
    public static func hasPart(_ callID: String, token: String, incoming: URL) -> Bool {
        FileManager.default.fileExists(atPath: part(callID, token: token, incoming: incoming).appendingPathComponent(MoveMarker.fileName).path)
    }

    /// Makes `Incoming/<id>.<token>.part` whole and checked, with `move.json` last, each synced to the disk. Any
    /// failure removes the part and throws; a stop leaves it as it is. `stop` is called before each sub-step.
    public static func write(_ plan: Plan, from: String, token: String, incoming: URL, now: Date, copy: FileCopy = file,
                             progress: @escaping (Double) -> Void = { _ in }, stop: (String) throws -> Void = { _ in }) throws -> MoveMarker {
        let fm = FileManager.default
        let folder = part(plan.record.id, token: token, incoming: incoming)
        do {
            try stop("clear the part")
            if fm.fileExists(atPath: folder.path) { try fm.removeItem(at: folder) }
            try stop("make the part")
            try fm.createDirectory(at: folder.appendingPathComponent(MoveMarker.callFolder), withIntermediateDirectories: true)
            var files: [MoveMarker.File] = []
            var done: Int64 = 0
            for source in plan.files {
                try stop("copy \(source.path)")
                let to = folder.appendingPathComponent(source.path)
                try fm.createDirectory(at: to.deletingLastPathComponent(), withIntermediateDirectories: true)
                let base = done
                let read = try copy(source.from, to) { progress(plan.bytes > 0 ? Double(base + $0) / Double(plan.bytes) : 0) }
                done += read.size
                // Read back from the disk: the copy is what the target will check.
                guard size(to) == read.size, try FileHash.sha256(of: to) == read.sha256, try FileHash.sha256(of: source.from) == read.sha256
                else { throw NotTheSame() }
                files.append(MoveMarker.File(path: source.path, size: read.size, sha256: read.sha256))
            }
            try stop("write the record")
            files.append(try written(plan.record, as: "\(MoveMarker.callFolder)/\(CallRecord.fileName)", in: folder))
            for chat in plan.chats {
                try stop("write a chat")
                files.append(try written(chat, as: "\(MoveMarker.chatsFolder)/\(chat.id.uuidString).json", in: folder))
            }
            try stop("sync the folder")
            try MoveFiles.fullSync(folder.appendingPathComponent(MoveMarker.callFolder))
            let marker = MoveMarker(callID: plan.record.id, from: from, to: plan.to, made: now, token: token,
                                    files: files.sorted { $0.path < $1.path }, ownerKeys: plan.ownerKeys)
            try stop("write the marker")
            try marker.save(in: folder, claimed: false)
            try MoveFiles.fullSync(folder.appendingPathComponent(MoveMarker.fileName))
            try MoveFiles.fullSync(folder)
            return marker
        } catch is MoveStop {
            throw MoveStop()
        } catch {
            try? fm.removeItem(at: folder)
            throw error
        }
    }

    /// Writes a value as JSON, synced, and checks that the file decodes to it.
    private static func written<T: Codable & Equatable>(_ value: T, as path: String, in folder: URL) throws -> MoveMarker.File {
        let url = folder.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(value).write(to: url, options: .atomic)
        try MoveFiles.fullSync(url)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard try decoder.decode(T.self, from: Data(contentsOf: url)) == value, let s = size(url) else { throw NotTheSame() }
        return MoveMarker.File(path: path, size: s, sha256: try FileHash.sha256(of: url))
    }

    /// The part becomes `Incoming/<id>` in one exclusive rename; another volume refuses.
    public static func publish(_ callID: String, token: String, incoming: URL, rename: MoveFiles.Rename = MoveFiles.exclusive,
                               stop: (String) throws -> Void = { _ in }) throws {
        let from = part(callID, token: token, incoming: incoming)
        guard hasPart(callID, token: token, incoming: incoming) else { throw CocoaError(.fileNoSuchFile) }
        try stop("publish")
        try MoveFiles.rename(from, to: incoming.appendingPathComponent(callID), with: rename)
        try? MoveFiles.fullSync(incoming)
    }
}

/// SHA-256 in pieces, as lowercase hex.
struct SHA256Hasher {
    private var hasher = SHA256()
    mutating func update(_ data: Data) { hasher.update(data: data) }
    var hex: String { hasher.finalize().map { String(format: "%02x", $0) }.joined() }
}
