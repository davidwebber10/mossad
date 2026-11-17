import Darwin
import Foundation

/// The target's half of a move: one step at a time, each a durable change that a stop (the end of the process) at any
/// line leaves resumable from the marker and the folders. Only the profile's own process runs it (its worker, or its
/// window app while it is active): that process holds the profile's folder lock.
public struct MoveIntake: Sendable {
    public let paths: Paths
    /// This profile's id: only a marker addressed to it is taken in.
    public let me: String
    private let library: VoiceLibrary
    private let ownerName: @Sendable () -> String
    private let voiceFingerprints: @Sendable () -> Bool
    private let stop: @Sendable (String) throws -> Void
    private let rename: @Sendable (String, String) -> Int32
    private let sync: @Sendable (URL) throws -> Void
    public static let maxTries = 5

    public init(paths: Paths, me: String, library: VoiceLibrary, ownerName: @escaping @Sendable () -> String,
                voiceFingerprints: @escaping @Sendable () -> Bool, stop: @escaping @Sendable (String) throws -> Void = { _ in },
                rename: @escaping @Sendable (String, String) -> Int32 = MoveFiles.exclusive,
                sync: @escaping @Sendable (URL) throws -> Void = MoveFiles.fullSync) {
        self.sync = sync
        self.paths = paths
        self.me = me
        self.library = library
        self.ownerName = ownerName
        self.voiceFingerprints = voiceFingerprints
        self.stop = stop
        self.rename = rename
    }

    /// `Incoming` has a published folder with `move.json`, or a `claimed.json` that is not taken or refused.
    public static func hasWork(_ paths: Paths) -> Bool { !waiting(paths).isEmpty }

    public func waiting() -> [String] { Self.waiting(paths) }

    /// The meetings that wait here and are not in `Audio` yet, for the worker's status: a count, never an id.
    public static func waitingCount(_ paths: Paths) -> Int {
        waiting(paths).filter { FileManager.default.fileExists(atPath: MoveMarker.folder($0, in: paths).appendingPathComponent(MoveMarker.callFolder).path) }.count
    }

    static func waiting(_ paths: Paths) -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: paths.incoming.path)) ?? []
        return names.filter { !$0.hasSuffix(MoveMarker.partSuffix) && !$0.hasPrefix(".") }.sorted().filter { name in
            switch MoveMarker.look(paths.incoming.appendingPathComponent(name)) {
            case .incoming: true
            case .claimed(let m): m.intake == nil || m.intake == .takingIn
            default: false
            }
        }
    }

    /// The target's naming of the voices, saved before anything is learned.
    static let namingName = "naming.json"

    private func folder(_ callID: String) -> URL { MoveMarker.folder(callID, in: paths) }
    private func callFolder(_ callID: String) -> URL { folder(callID).appendingPathComponent(MoveMarker.callFolder) }

    /// The folder names of `Audio` and every id that left this profile.
    private func taken() -> Set<String> {
        Set((try? FileManager.default.contentsOfDirectory(atPath: paths.audio.path)) ?? []).union(MoveOut.leftIDs(paths))
    }

    /// Does the one step that `MovePlan.target` names for this folder, and returns it.
    @discardableResult
    public func step(_ callID: String) -> MovePlan.TargetStep {
        (try? stepOrStop(callID)) ?? .wait
    }

    /// This profile has its own move of this id that is not done, or a ledger of it that does not read: wait.
    private func ownRemoval(_ callID: String) -> Bool {
        if let out = MoveOut.load(callID, paths: paths) { return MovePlan.ownRemoval(out) }
        return MoveOut.leftIDs(paths).contains(callID) && FileManager.default.fileExists(atPath: MoveOut.url(callID, paths: paths).path)
            && MoveOut.load(callID, paths: paths) == nil
    }

    /// The step; throws `MoveStop` when a test ends the process at a sub-step.
    ///
    /// The order: claim; decide (a refusal here changes nothing of this profile); the first half in `Incoming` (the
    /// naming and the record as it arrives); one rename into `Audio`, the record still marked; the check of every
    /// file; then, and only then, the voices are learned and the chats written, the mark goes, and `taken` is
    /// written. So every refusal comes before this profile learned or wrote anything outside `Incoming`, and leaves
    /// it as it was.
    /// The names in `Audio`; nil when the listing fails. A folder that is not there is empty only when the caller says so.
    static func audioNames(_ audio: URL, missingIsEmpty: Bool = false) -> [String]? {
        if let names = try? FileManager.default.contentsOfDirectory(atPath: audio.path) { return names }
        var isDir: ObjCBool = false
        if missingIsEmpty, !FileManager.default.fileExists(atPath: audio.path, isDirectory: &isDir) { return [] }
        return nil
    }

    func stepOrStop(_ callID: String) throws -> MovePlan.TargetStep {
        guard MovePaths.isID(callID) else { return .nothing }
        // The people store follows the voices: without it a learned voice would make no person.
        if voiceFingerprints(), library.identity == nil { return .wait }
        let look = MoveMarker.look(folder(callID))
        let hasCall = FileManager.default.fileExists(atPath: callFolder(callID).path)
        // A listing that fails is not an empty `Audio`: the step waits.
        guard let names = Self.audioNames(paths.audio, missingIsEmpty: true) else { return .wait }
        let audio = Set(names)
        var held: Bool?
        if case .claimed(let m) = look, m.intake == .takingIn, let f = m.finalID, MovePaths.isID(f), !hasCall, audio.contains(f) { held = checked(m, f) }
        let step = MovePlan.target(look, folder: callID, me: me, callFolder: hasCall, audio: audio, ownRemoval: ownRemoval(callID), held: held)
        do {
            switch step {
            case .claim:
                try stop("claim")
                _ = MoveMarker.claim(folder(callID))
            case .decide:
                guard case .claimed(var m) = look else { return step }
                try decide(&m, callID)
            case .takeIn(let f):
                guard case .claimed(var m) = look, MovePaths.isID(f) else { return step }
                try takeIn(&m, callID, as: f)
            case .markTaken:
                guard case .claimed(var m) = look, let f = m.finalID else { return step }
                try markTaken(&m, callID, f)
            case .refuse(let why):
                guard case .claimed(var m) = look else { return step }
                try refuse(&m, callID, why)
            case .wait, .nothing:
                break
            }
        } catch is MoveStop {
            throw MoveStop()
        } catch {
            Log.error("Move: the take-in of a meeting stopped at a step; the next look goes on: \(error)")
        }
        return step
    }

    /// Each waiting folder to its end. Returns the ids the meetings have here.
    @discardableResult
    public func run() -> [String] {
        var done: [String] = []
        for callID in waiting() {
            for _ in 0..<12 {
                // A stop ends the run, as the end of the process would.
                guard let s = try? stepOrStop(callID) else { return done }
                if s == .wait || s == .nothing { break }
                if case .claimed(let m) = MoveMarker.look(folder(callID)), m.intake == .refused || m.intake == .taken { break }
                if case .takeIn = s, case .claimed(let m) = MoveMarker.look(folder(callID)), (m.tries ?? 0) > 0 { break }
            }
            if case .claimed(let m) = MoveMarker.look(folder(callID)), m.intake == .taken, let f = m.finalID { done.append(f) }
        }
        return done
    }

    // MARK: The steps

    /// `Incoming` and `Audio` on one volume, as the one rename into `Audio` needs. Nil when it cannot be read.
    private func sameVolume() -> Bool? {
        let audio = FileManager.default.fileExists(atPath: paths.audio.path) ? paths.audio : paths.root
        func device(_ url: URL) -> Int? { (try? FileManager.default.attributesOfItem(atPath: url.path))?[.systemNumber] as? Int }
        guard let a = device(paths.incoming), let b = device(audio) else { return nil }
        return a == b
    }

    private func decide(_ m: inout MoveMarker, _ callID: String) throws {
        let record = try? CallRecord.load(from: callFolder(callID))
        // A decision made again after the first half: the record there is the arrival, so its size is not the marker's.
        let again = m.arrived == true
        let whole = !m.files.isEmpty && m.files.allSatisfy { f in
            (again && f.path == "\(MoveMarker.callFolder)/\(CallRecord.fileName)") || MoveCopy.size(folder(callID).appendingPathComponent(f.path)) == f.size
        }
        // An id that is in `Audio` now is taken, also the one chosen before: another meeting took it meanwhile.
        var d = MovePlan.decide(record: record, sizesMatch: whole, id: callID, taken: taken())
        if d.intake == .takingIn, sameVolume() != true { d = (.refused, nil, .notWhole) }
        try stop("decide")
        m.intake = d.intake
        m.finalID = d.finalID
        m.refusal = d.refusal
        m.tries = nil
        if d.intake == .takingIn, m.chatIDs == nil {
            var ids: [String: String] = [:]
            for f in m.files where f.path.hasPrefix(MoveMarker.chatsFolder + "/") {
                let old = String(f.path.dropFirst(MoveMarker.chatsFolder.count + 1).dropLast(5))
                guard MovePaths.isID(old) else { continue }
                ids[old] = UUID().uuidString
            }
            m.chatIDs = ids
        }
        try m.save(in: folder(callID), claimed: true)
    }

    private func takeIn(_ m: inout MoveMarker, _ callID: String, as f: String) throws {
        let call = callFolder(callID)
        let arrival = call.appendingPathComponent(MoveMarker.arrivalName)
        if m.arrived != true || FileManager.default.fileExists(atPath: arrival.path) || (try? CallRecord.load(from: call))?.id != f {
            try firstHalf(&m, callID, as: f)
            return
        }
        // The second half: one rename into `Audio`. Another volume refuses at once; any other failure is tried again a
        // few times, then refused: the first profile keeps its meeting.
        try stop("into Audio")
        try FileManager.default.createDirectory(at: paths.audio, withIntermediateDirectories: true)
        do {
            try MoveFiles.rename(call, to: paths.callDirectory(f), with: rename)
        } catch is MoveFiles.OtherVolume {
            try refuse(&m, callID, .notWhole)
            return
        } catch {
            m.tries = (m.tries ?? 0) + 1
            if m.tries! >= Self.maxTries {
                Log.error("Move: the meeting could not be put into Audio; it is refused, and the first profile keeps it: \(error)")
                try refuse(&m, callID, .notWhole)
            } else {
                try m.save(in: folder(callID), claimed: true)
            }
            return
        }
        try sync(paths.audio)
    }

    /// The naming, decided once and saved beside the marker, and the record as it arrives, in `Incoming` only:
    /// nothing outside `Incoming` changes here.
    private func firstHalf(_ m: inout MoveMarker, _ callID: String, as f: String) throws {
        let call = callFolder(callID)
        let arrival = call.appendingPathComponent(MoveMarker.arrivalName)
        if m.arrived == true, FileManager.default.fileExists(atPath: arrival.path) {
            // A stop between the marker and the rename: the arrival is whole on the disk.
            try stop("arrive")
            guard Darwin.rename(arrival.path, call.appendingPathComponent(CallRecord.fileName).path) == 0 else { throw MoveFiles.Failed(code: errno) }
            return
        }
        if m.arrived == true, var r = try? CallRecord.load(from: call), r.id != f {
            // Decided again under another id after the first half: the arrived record takes it.
            r.id = f
            try stop("write the arrival")
            try r.save(to: call, fileName: MoveMarker.arrivalName)
            try sync(arrival)
            try stop("arrive")
            guard Darwin.rename(arrival.path, call.appendingPathComponent(CallRecord.fileName).path) == 0 else { throw MoveFiles.Failed(code: errno) }
            return
        }
        var r = MovedRecord.prepared(try CallRecord.load(from: call), to: me)
        let saved = folder(callID).appendingPathComponent(Self.namingName)
        if ![.recorded, .transcribed, .recording].contains(r.status) {
            let n = MovedVoices.decide(r, ownerKeys: Set(m.ownerKeys), library: library, ownerName: ownerName(),
                                       fingerprints: voiceFingerprints(), callID: f)
            MovedVoices.name(n, in: &r)
            r.status = MovedRecord.arrival(status: r.status, failedStep: r.failedStep, namesChanged: n.changed)
            try stop("write the naming")
            // Beside the marker, never in the call folder: it must not go into `Audio` with the meeting.
            try JSONEncoder().encode(n).write(to: saved, options: .atomic)
            try sync(saved)
        } else {
            r.status = .recorded
        }
        r.failedStep = nil
        // Marked for this profile until `taken`: no pipeline, queue, sync, or runner here touches it before.
        r.moveTo = me
        r.id = f
        try stop("write the arrival")
        try r.save(to: call, fileName: MoveMarker.arrivalName)
        try sync(arrival)
        try stop("mark arrived")
        m.arrived = true
        try m.save(in: folder(callID), claimed: true)
        try stop("arrive")
        guard Darwin.rename(arrival.path, call.appendingPathComponent(CallRecord.fileName).path) == 0 else { throw MoveFiles.Failed(code: errno) }
    }

    /// After the check of every file: the voices, the chats, the mark off, then `taken`. Each part can run twice.
    private func markTaken(_ m: inout MoveMarker, _ callID: String, _ f: String) throws {
        let dir = paths.callDirectory(f)
        let saved = folder(callID).appendingPathComponent(Self.namingName)
        if let data = try? Data(contentsOf: saved), let naming = try? JSONDecoder().decode(MovedVoices.Naming.self, from: data),
           let r = try? CallRecord.load(from: dir) {
            try stop("learn the voices")
            try MovedVoices.learn(naming, from: r, callID: f, library: library)
        }
        try stop("sync the meeting")
        try sync(dir)
        // The mark goes before the chats: they are new chats of this meeting here.
        if var r = try? CallRecord.load(from: dir), r.moveTo != nil {
            try stop("take the mark off")
            r.moveTo = nil
            try r.save(to: dir)
            try sync(dir.appendingPathComponent(CallRecord.fileName))
        }
        try writeChats(m, callID, as: f)
        if FileManager.default.fileExists(atPath: paths.chats.path) { try sync(paths.chats) }
        try stop("remove the copies of the chats")
        try? FileManager.default.removeItem(at: folder(callID).appendingPathComponent(MoveMarker.chatsFolder))
        try? FileManager.default.removeItem(at: saved)
        try stop("write taken")
        m.intake = .taken
        m.count = m.files.count
        m.tries = nil
        try m.save(in: folder(callID), claimed: true)
        try sync(folder(callID).appendingPathComponent(MoveMarker.claimedName))
    }

    /// Every link of the call in a text follows the id it has here: a link is `mossad://call/<id>` with no more
    /// characters of an id after it.
    static func relink(_ text: String, from: String, to: String) -> String {
        guard from != to else { return text }
        let prefix = "mossad://call/" + from
        var out = "", rest = Substring(text)
        while let r = rest.range(of: prefix) {
            out += rest[..<r.lowerBound]
            let after = rest[r.upperBound...]
            if let next = after.unicodeScalars.first, CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_").contains(next) {
                out += prefix
            } else {
                out += "mossad://call/" + to
            }
            rest = after
        }
        return out + rest
    }

    private func writeChats(_ m: MoveMarker, _ callID: String, as f: String) throws {
        let store = ChatStore(directory: paths.chats)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        for (old, new) in (m.chatIDs ?? [:]).sorted(by: { $0.key < $1.key }) where MovePaths.isID(old) {
            let file = folder(callID).appendingPathComponent("\(MoveMarker.chatsFolder)/\(old).json")
            guard var chat = try? decoder.decode(Chat.self, from: Data(contentsOf: file)), let id = UUID(uuidString: new) else { continue }
            chat.id = id
            chat.callID = f
            for i in chat.messages.indices {
                chat.messages[i].text = Self.relink(chat.messages[i].text, from: m.callID, to: f)
                chat.messages[i].actions = nil
            }
            try stop("write a chat")
            try store.save(chat)
        }
    }

    /// The files in `Audio/<final id>` against the marker: each file that went as it is, by its size and hash; the
    /// record, which arrived rewritten, by its id and this profile's mark. A record whose mark is off passed this check
    /// already (the mark goes only after it): the voices and chats of that run may be there, so it is never refused.
    private func checked(_ m: MoveMarker, _ f: String) -> Bool {
        let dir = paths.callDirectory(f)
        guard let r = try? CallRecord.load(from: dir), r.id == f else { return false }
        if r.moveTo == nil { return true }
        guard r.moveTo == me else { return false }
        var expected: [MoveMarker.File] = [], found: [String: (size: Int64, sha256: String)] = [:]
        for file in m.files where file.path != "\(MoveMarker.callFolder)/\(CallRecord.fileName)" && !file.path.hasPrefix(MoveMarker.chatsFolder + "/") {
            expected.append(file)
            let rel = String(file.path.dropFirst(MoveMarker.callFolder.count + 1))
            guard file.path.hasPrefix(MoveMarker.callFolder + "/"), !rel.split(separator: "/").contains(where: { $0 == ".." || $0.hasPrefix(".") }) else { return false }
            let url = dir.appendingPathComponent(rel)
            if let size = MoveCopy.size(url), let hash = try? FileHash.sha256(of: url) { found[file.path] = (size, hash) }
        }
        return expected.isEmpty || MovePlan.held(expected, found: found)
    }

    /// A refusal comes before this profile learned or wrote anything outside `Incoming`: only the meeting this move put
    /// into `Audio` (still marked for this profile, with this id) goes back out of it. Then `refused`.
    private func refuse(_ m: inout MoveMarker, _ callID: String, _ why: MoveMarker.Refusal) throws {
        if let f = m.finalID, MovePaths.isID(f), !FileManager.default.fileExists(atPath: callFolder(callID).path),
           let inAudio = try? CallRecord.load(from: paths.callDirectory(f)), inAudio.id == f, inAudio.moveTo == me {
            try stop("out of Audio")
            try MoveFiles.rename(paths.callDirectory(f), to: callFolder(callID), with: rename)
        }
        try stop("write refused")
        m.intake = .refused
        m.refusal = why
        try m.save(in: folder(callID), claimed: true)
    }
}
