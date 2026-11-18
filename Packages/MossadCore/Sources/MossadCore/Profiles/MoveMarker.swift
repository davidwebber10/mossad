import Foundation

/// The one file of a move in the target's `Incoming/<id>`. The first profile writes it as `move.json`, last, into a
/// whole copy; the target takes it over with one rename to `claimed.json` and then writes its own half into it. The
/// owner's Cancel takes it back with a rename to `cancelled.json`. Only one of the two renames can succeed, so a claim
/// and a cancel never both win. It holds ids, a token, speaker keys, sizes, hashes, and file names: never a title, a
/// name, or an address. The token is made once for each move and is also in the first profile's ledger: a marker of
/// another move (another profile's meeting with the same id, or an older move of this id) is never acted on.
public struct MoveMarker: Codable, Equatable, Sendable {
    public static let fileName = "move.json", claimedName = "claimed.json", cancelledName = "cancelled.json"
    public static let partSuffix = ".part", callFolder = "call", chatsFolder = "chats", arrivalName = "arrival.json"
    public static let currentVersion = 1
    public static let allowedKeys: Set<String> = ["version", "callID", "from", "to", "made", "token", "files", "path", "size", "sha256",
                                                  "ownerKeys", "intake", "finalID", "refusal", "count", "chatIDs",
                                                  "arrived", "tries", "waits", "lastTry", "points", "pointIDs"]

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
    /// Where a take-in that failed after the file check waits: a kind from this list, never a title or a name.
    public enum TakeInWait: String, Codable, CaseIterable, Sendable { case voices, record, chats, failed, points }

    public var version: Int
    public var callID: String
    public var from: String
    public var to: String
    public var made: Date
    /// Made once for each move, and kept in the first profile's ledger.
    public var token: String
    /// Paths under `Incoming/<id>`: "call/call.json", "chats/<uuid>.json".
    public var files: [File]
    /// The speaker keys that were the owner in the first profile.
    public var ownerKeys: [String]
    /// The target's half.
    public var intake: Intake?
    public var finalID: String?
    public var refusal: Refusal?
    /// The files the target checked in its `Audio` against `files` (count, sizes, hashes) before it wrote `taken`.
    public var count: Int?
    /// The chat id of the first profile to the id it gets here.
    public var chatIDs: [String: String]?
    /// The points for next time that go with the meeting (`MovedPoints`), beside `call/` and never in `files`: an
    /// older target checks each file of `files` in its `Audio`, and does not read this field. Nil when none goes, and
    /// then the marker is as before.
    public var points: File?
    /// The ids the points get here, in the file's order: decided once with the chats' ids.
    public var pointIDs: [String]?
    /// The target's first half ended: `call/call.json` is the record as it arrives (or `call/arrival.json` is, until
    /// its rename).
    public var arrived: Bool?
    /// The failed tries of the rename into `Audio`: after `MoveIntake.maxTries` the target refuses. Also the failed
    /// tries of the part after the file check (`waits`), which never refuses: it waits longer after each (`MoveRetry`).
    public var tries: Int?
    /// Review N2: where the part after the file check waits, and its last try.
    public var waits: TakeInWait?
    public var lastTry: Date?

    public init(callID: String, from: String, to: String, made: Date, token: String, files: [File], ownerKeys: [String]) {
        version = Self.currentVersion
        self.callID = callID
        self.from = from
        self.to = to
        self.made = made
        self.token = token
        self.files = files
        self.ownerKeys = ownerKeys
    }

    /// What a side sees. A file that does not decode, or of a newer version, is not known: never acted on.
    /// `cancelled`: the owner took it back (`cancelled.json`); nil when that file does not read.
    public enum Look: Equatable, Sendable { case missing, incoming(MoveMarker), claimed(MoveMarker), cancelled(MoveMarker?), unknown }

    /// The marker of this ledger's move: its token, its call, and its target.
    public func isMine(of out: MoveOut) -> Bool { token == out.token && callID == out.callID && to == out.to }

    /// The target took the meeting in and checked every file of `files` in its `Audio`.
    public var heldWhole: Bool { intake == .taken && !files.isEmpty && count == files.count }

    /// A call id that fails `MovePaths.isID` gives a hidden name that is never there, never `Incoming` itself.
    public static func folder(_ callID: String, in target: Paths) -> URL {
        target.incoming.appendingPathComponent(MovePaths.isID(callID) ? callID : MovePaths.notAnID)
    }

    /// Reads `claimed.json`, else `move.json`, else `cancelled.json`. The target's claim can come between the first two
    /// tests, so `claimed.json` is tested again when `move.json` is not there. No folder, or no file, is `.missing`.
    /// `afterFirstTest` is for a test: it runs between the first two tests.
    public static func look(_ folder: URL, afterFirstTest: (() -> Void)? = nil, beforeRead: (() -> Void)? = nil) -> Look {
        if let seen = read(folder.appendingPathComponent(claimedName), claimed: true) { return seen }
        afterFirstTest?()
        // A `move.json` that does not read may be one that B renamed in that moment: `claimed.json` is tested again
        // before it is called unknown.
        let incoming = read(folder.appendingPathComponent(fileName), claimed: false, beforeRead: beforeRead)
        if let incoming, incoming != .unknown { return incoming }
        if let seen = read(folder.appendingPathComponent(claimedName), claimed: true) { return seen }
        if incoming == .unknown { return .unknown }
        let cancelled = folder.appendingPathComponent(cancelledName)
        if FileManager.default.fileExists(atPath: cancelled.path) {
            return .cancelled((try? Data(contentsOf: cancelled)).flatMap(decode))
        }
        return .missing
    }

    /// Nil when the file is not there.
    private static func read(_ url: URL, claimed: Bool, beforeRead: (() -> Void)? = nil) -> Look? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        beforeRead?()
        guard let data = try? Data(contentsOf: url), let marker = decode(data) else { return .unknown }
        return claimed ? .claimed(marker) : .incoming(marker)
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
    /// Made once for this move; the marker carries it.
    public var token: String
    public var afterCall: Bool
    /// The removal steps that ended, by their raw names (a newer build's step is kept as text).
    public var removed: [String]
    /// Why, saved with the state `.cancelling`.
    public var cancel: MovePlan.Cancel?
    /// The ids of the people whom only this call made, decided once before the `people` step deletes the first.
    public var people: [String]?
    /// Review N2: the failed tries of the removal step that waits (`waitsAt`), the last one, why, and since when. Gone
    /// once the step ends.
    public var tries: Int?
    public var lastTry: Date?
    public var waitsAt: String?
    public var because: Wait?
    public var waitsSince: Date?
    /// The target took the meeting and has not finished after the last wait step: where it waits.
    public var targetWaits: MoveMarker.TakeInWait?

    /// Why a removal step waits, as far as this profile can tell.
    public enum Wait: String, Codable, CaseIterable, Sendable { case peopleNotReady, shareNotSaved, backupNotDone, folderNotRemoved, failed }

    public init(callID: String, to: String, started: Date, afterCall: Bool = false, token: String = MoveOut.newToken()) {
        version = Self.currentVersion
        self.callID = callID
        self.to = to
        state = .copying
        self.started = started
        self.token = token
        self.afterCall = afterCall
        removed = []
    }

    /// A random token: two UUIDs, no id of the Mac or the owner.
    public static func newToken() -> String { (UUID().uuidString + UUID().uuidString).replacingOccurrences(of: "-", with: "").lowercased() }

    /// The first removal step that has not ended; nil when all have.
    public var nextStep: Step? { Step.allCases.first { !removed.contains($0.rawValue) } }

    public static func url(_ callID: String, paths: Paths) -> URL {
        paths.moves.appendingPathComponent((MovePaths.isID(callID) ? callID : MovePaths.notAnID) + ".json")
    }

    /// Nil: no file, a file that does not read, one of a newer version, or one whose ids or token fail `MovePaths`.
    public static func load(_ callID: String, paths: Paths) -> MoveOut? {
        guard MovePaths.isID(callID), let out = (try? Data(contentsOf: url(callID, paths: paths))).flatMap(decode),
              out.callID == callID, MovePaths.isID(out.to), MovePaths.isToken(out.token) else { return nil }
        return out
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

    /// The meetings that the target took in and whose removal here has begun (`removing`, then `done` until the folder
    /// is gone): the sync takes them off the store at once, as if the folder were gone. Before that the meeting is
    /// still this profile's.
    public static func syncHeld(_ paths: Paths) -> Set<String> {
        guard FileManager.default.fileExists(atPath: paths.moves.path) else { return [] }
        return Set(all(paths).moves.filter { $0.state == .removing || $0.state == .done }.map(\.callID))
    }

    /// A move that is not done.
    public static func hasWork(_ paths: Paths) -> Bool {
        all(paths).moves.contains { $0.state != .done }
    }

    private static func ids(_ paths: Paths) -> Set<String> {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: paths.moves.path)) ?? []
        return Set(names.filter { $0.hasSuffix(".json") }.map { String($0.dropLast(5)) })
    }

    /// One atomic write; makes `Moves`.
    /// One atomic write, synced to the disk; makes `Moves`.
    public func save(_ paths: Paths) throws {
        guard MovePaths.isID(callID), MovePaths.isID(to), MovePaths.isToken(token) else { throw MovePaths.Invalid() }
        try FileManager.default.createDirectory(at: paths.moves, withIntermediateDirectories: true)
        let file = Self.url(callID, paths: paths)
        try JSONEncoder.move.encode(self).write(to: file, options: .atomic)
        try MoveFiles.fullSync(file)
    }

    public static func delete(_ callID: String, paths: Paths) {
        guard MovePaths.isID(callID) else { return }
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

/// Why a move of this profile ended without moving, kept in `Moves/<id>.ended` until the window app has shown it: a
/// worker that ends a move while this profile is in the background never deletes it, so the owner reads the reason
/// when they next open the profile. Not a ledger: its name does not end in `.json`, so the id is not counted as one
/// that left. The owner's own Cancel keeps none.
public struct MoveEnded: Codable, Equatable, Sendable {
    public static let suffix = ".ended"
    public var version = 1
    public var callID: String
    public var to: String
    public var why: MovePlan.Cancel
    public var afterCall: Bool
    public var at: Date

    public init(callID: String, to: String, why: MovePlan.Cancel, afterCall: Bool, at: Date) {
        self.callID = callID
        self.to = to
        self.why = why
        self.afterCall = afterCall
        self.at = at
    }

    static func url(_ callID: String, paths: Paths) -> URL {
        paths.moves.appendingPathComponent((MovePaths.isID(callID) ? callID : MovePaths.notAnID) + suffix)
    }

    public func save(_ paths: Paths) throws {
        guard MovePaths.isID(callID), MovePaths.isID(to) else { throw MovePaths.Invalid() }
        try FileManager.default.createDirectory(at: paths.moves, withIntermediateDirectories: true)
        let file = Self.url(callID, paths: paths)
        try JSONEncoder.move.encode(self).write(to: file, options: .atomic)
        try MoveFiles.fullSync(file)
    }

    public static func load(_ callID: String, paths: Paths) -> MoveEnded? {
        guard MovePaths.isID(callID), let data = try? Data(contentsOf: url(callID, paths: paths)),
              let e = try? JSONDecoder.move.decode(MoveEnded.self, from: data), e.version <= 1, e.callID == callID, MovePaths.isID(e.to) else { return nil }
        return e
    }

    /// Every reason not shown yet. One folder listing; it makes no folder.
    public static func all(_ paths: Paths) -> [MoveEnded] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: paths.moves.path)) ?? []
        return names.filter { $0.hasSuffix(suffix) }.map { String($0.dropLast(suffix.count)) }.sorted().compactMap { load($0, paths: paths) }
    }

    /// The window app showed it, or a new move of the id starts: it goes.
    public static func shown(_ callID: String, paths: Paths) {
        guard MovePaths.isID(callID) else { return }
        try? FileManager.default.removeItem(at: url(callID, paths: paths))
    }
}
