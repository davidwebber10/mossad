import Foundation

/// The one file of a move in the target's `Incoming/<id>`. The first profile writes it as `move.json`, last, into a
/// whole copy; the target takes it over with one rename to `claimed.json` and then writes its own half into it. The
/// owner's Cancel takes it back with a rename to `cancelled.json`. Only one of the two renames can succeed, so a claim
/// and a cancel never both win. It holds ids, speaker keys, sizes, hashes, and file names: never a title, a name, or
/// an address.
public struct MoveMarker: Codable, Equatable, Sendable {
    public static let fileName = "move.json", claimedName = "claimed.json", cancelledName = "cancelled.json"
    public static let partSuffix = ".part", callFolder = "call", chatsFolder = "chats", arrivalName = "arrival.json"
    public static let currentVersion = 1
    public static let allowedKeys: Set<String> = ["version", "callID", "from", "to", "made", "files", "path", "size", "sha256",
                                                  "ownerKeys", "intake", "finalID", "refusal", "chatIDs"]

    public struct File: Codable, Equatable, Sendable {
        public var path: String
        public var size: Int64
        public var sha256: String

        public init(path: String, size: Int64, sha256: String) {
            self.path = path
            self.size = size
            self.sha256 = sha256
        }
    }

    public enum Intake: String, Codable, Sendable { case takingIn, taken, refused }
    public enum Refusal: String, Codable, Sendable { case idTaken, unreadable, notWhole }

    public var version: Int
    public var callID: String
    public var from: String
    public var to: String
    public var made: Date
    /// Paths under `Incoming/<id>`: "call/call.json", "chats/<uuid>.json".
    public var files: [File]
    /// The speaker keys that were the owner in the first profile.
    public var ownerKeys: [String]
    /// The target's half.
    public var intake: Intake?
    public var finalID: String?
    public var refusal: Refusal?
    /// The chat id of the first profile to the id it gets here.
    public var chatIDs: [String: String]?

    public init(callID: String, from: String, to: String, made: Date, files: [File], ownerKeys: [String]) {
        version = Self.currentVersion
        self.callID = callID
        self.from = from
        self.to = to
        self.made = made
        self.files = files
        self.ownerKeys = ownerKeys
    }

    /// What a side sees. A file that does not decode, or of a newer version, is not known: never acted on.
    public enum Look: Equatable, Sendable { case missing, incoming(MoveMarker), claimed(MoveMarker), unknown }

    public static func folder(_ callID: String, in target: Paths) -> URL {
        target.incoming.appendingPathComponent(callID)
    }

    /// Reads `claimed.json`, else `move.json`, and nothing else. No folder, or neither file, is `.missing`.
    public static func look(_ folder: URL) -> Look {
        let fm = FileManager.default
        for (name, claimed) in [(claimedName, true), (fileName, false)] {
            let url = folder.appendingPathComponent(name)
            guard fm.fileExists(atPath: url.path) else { continue }
            guard let data = try? Data(contentsOf: url), let marker = decode(data) else { return .unknown }
            return claimed ? .claimed(marker) : .incoming(marker)
        }
        return .missing
    }

    private struct Versioned: Decodable { var version: Int }

    static func decode(_ data: Data) -> MoveMarker? {
        guard let v = try? JSONDecoder.move.decode(Versioned.self, from: data), v.version <= currentVersion else { return nil }
        return try? JSONDecoder.move.decode(MoveMarker.self, from: data)
    }

    /// One atomic write, under the name of its side.
    public func save(in folder: URL, claimed: Bool) throws {
        try JSONEncoder.move.encode(self).write(to: folder.appendingPathComponent(claimed ? Self.claimedName : Self.fileName), options: .atomic)
    }

    /// The target's claim: `move.json` becomes `claimed.json`. False when the file is gone (taken back) or already claimed.
    public static func claim(_ folder: URL) -> Bool {
        rename(folder.appendingPathComponent(fileName), to: folder.appendingPathComponent(claimedName))
    }

    /// The owner's Cancel: `move.json` becomes `cancelled.json`. False when the target claimed it first.
    public static func takeBack(_ folder: URL) -> Bool {
        rename(folder.appendingPathComponent(fileName), to: folder.appendingPathComponent(cancelledName))
    }

    /// `moveItem` fails when the source is gone or the destination is there, so one rename wins.
    private static func rename(_ from: URL, to: URL) -> Bool {
        (try? FileManager.default.moveItem(at: from, to: to)) != nil
    }
}

/// The first profile's own state of one move, in `Moves/<id>.json`. A finished move keeps its file (ids and dates), so
/// an id that left this profile is never used here again.
public struct MoveOut: Codable, Equatable, Sendable {
    public static let currentVersion = 1

    public enum State: String, Codable, CaseIterable, Sendable { case copying, copied, waiting, removing, cancelling, done }
    /// The removal, in order. Each step reads the record from the call folder, so the folder goes last.
    public enum Step: String, Codable, CaseIterable, Sendable { case voices, people, coach, books, shares, backup, notes, folder }

    public var version: Int
    public var callID: String
    public var to: String
    public var state: State
    public var started: Date
    public var afterCall: Bool
    /// The removal steps that ended, by their raw names (a newer build's step is kept as text).
    public var removed: [String]
    /// Why, saved with the state `.cancelling`.
    public var cancel: MovePlan.Cancel?

    public init(callID: String, to: String, started: Date, afterCall: Bool = false) {
        version = Self.currentVersion
        self.callID = callID
        self.to = to
        state = .copying
        self.started = started
        self.afterCall = afterCall
        removed = []
    }

    /// The first removal step that has not ended; nil when all have.
    public var nextStep: Step? { Step.allCases.first { !removed.contains($0.rawValue) } }

    public static func url(_ callID: String, paths: Paths) -> URL {
        paths.moves.appendingPathComponent(callID + ".json")
    }

    /// Nil: no file, a file that does not read, or one of a newer version.
    public static func load(_ callID: String, paths: Paths) -> MoveOut? {
        (try? Data(contentsOf: url(callID, paths: paths))).flatMap(decode)
    }

    private struct Versioned: Decodable { var version: Int }

    static func decode(_ data: Data) -> MoveOut? {
        guard let v = try? JSONDecoder.move.decode(Versioned.self, from: data), v.version <= currentVersion else { return nil }
        return try? JSONDecoder.move.decode(MoveOut.self, from: data)
    }

    /// Every move of this profile, and the ids of the files this build does not act on.
    public static func all(_ paths: Paths) -> (moves: [MoveOut], unknown: [String]) {
        var moves: [MoveOut] = [], unknown: [String] = []
        for id in ids(paths).sorted() {
            if let m = load(id, paths: paths) { moves.append(m) } else { unknown.append(id) }
        }
        return (moves, unknown)
    }

    /// Every id with a file in `Moves`, readable or not: these ids left this profile and are never used here again.
    public static func leftIDs(_ paths: Paths) -> Set<String> { ids(paths) }

    /// A move that is not done.
    public static func hasWork(_ paths: Paths) -> Bool {
        all(paths).moves.contains { $0.state != .done }
    }

    private static func ids(_ paths: Paths) -> Set<String> {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: paths.moves.path)) ?? []
        return Set(names.filter { $0.hasSuffix(".json") }.map { String($0.dropLast(5)) })
    }

    /// One atomic write; makes `Moves`.
    public func save(_ paths: Paths) throws {
        try FileManager.default.createDirectory(at: paths.moves, withIntermediateDirectories: true)
        try JSONEncoder.move.encode(self).write(to: Self.url(callID, paths: paths), options: .atomic)
    }

    public static func delete(_ callID: String, paths: Paths) {
        try? FileManager.default.removeItem(at: url(callID, paths: paths))
    }
}

extension JSONEncoder {
    static var move: JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys, .prettyPrinted]
        e.dateEncodingStrategy = .iso8601
        return e
    }
}

extension JSONDecoder {
    static var move: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }
}
