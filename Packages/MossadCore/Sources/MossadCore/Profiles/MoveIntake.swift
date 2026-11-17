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

    public init(paths: Paths, me: String, library: VoiceLibrary, ownerName: @escaping @Sendable () -> String,
                voiceFingerprints: @escaping @Sendable () -> Bool, stop: @escaping @Sendable (String) throws -> Void = { _ in },
                rename: @escaping @Sendable (String, String) -> Int32 = MoveFiles.exclusive) {
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

    /// The step; throws `MoveStop` when a test ends the process at a sub-step.
    func stepOrStop(_ callID: String) throws -> MovePlan.TargetStep {
        // The people store follows the voices: without it a learned voice would make no person.
        if voiceFingerprints(), library.identity == nil { return .wait }
        let look = MoveMarker.look(folder(callID))
        let hasCall = FileManager.default.fileExists(atPath: callFolder(callID).path)
        let audio = Set((try? FileManager.default.contentsOfDirectory(atPath: paths.audio.path)) ?? [])
        var held: Bool?
        if case .claimed(let m) = look, m.intake == .takingIn, let f = m.finalID, !hasCall, audio.contains(f) { held = checked(m, f) }
        let step = MovePlan.target(look, folder: callID, me: me, callFolder: hasCall, audio: audio,
                                   ownRemoval: MovePlan.ownRemoval(MoveOut.load(callID, paths: paths)), held: held)
        do {
            switch step {
            case .claim:
                try stop("claim")
                _ = MoveMarker.claim(folder(callID))
            case .decide:
                guard case .claimed(var m) = look else { return step }
                try decide(&m, callID)
            case .takeIn(let f):
                guard case .claimed(let m) = look else { return step }
                try takeIn(m, callID, as: f)
            case .markTaken:
                guard case .claimed(var m) = look else { return step }
                // The chats are in `Chats` now; their copies in `Incoming` go before `taken`.
                try stop("remove the copies of the chats")
                try? FileManager.default.removeItem(at: folder(callID).appendingPathComponent(MoveMarker.chatsFolder))
                try? FileManager.default.removeItem(at: folder(callID).appendingPathComponent(Self.namingName))
                try stop("sync the meeting")
                if let f = m.finalID { try? MoveFiles.fullSync(paths.callDirectory(f)) }
                try stop("write taken")
                m.intake = .taken
                m.count = m.files.count
                try m.save(in: folder(callID), claimed: true)
                try? MoveFiles.fullSync(folder(callID).appendingPathComponent(MoveMarker.claimedName))
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
                if case .claimed(let m) = MoveMarker.look(folder(callID)), m.intake == .refused { break }
            }
            if case .claimed(let m) = MoveMarker.look(folder(callID)), m.intake == .taken, let f = m.finalID { done.append(f) }
        }
        return done
    }

    // MARK: The steps

    private func decide(_ m: inout MoveMarker, _ callID: String) throws {
        let record = try? CallRecord.load(from: callFolder(callID))
        let whole = !m.files.isEmpty && m.files.allSatisfy { f in MoveCopy.size(folder(callID).appendingPathComponent(f.path)) == f.size }
        // A record that already arrived (a stop after the first half): its decision is made again with its own id taken out.
        var taken = taken()
        if let f = m.finalID { taken.remove(f) }
        let d = MovePlan.decide(record: record, sizesMatch: whole, id: callID, taken: taken)
        try stop("decide")
        m.intake = d.intake
        m.finalID = d.finalID
        m.refusal = d.refusal
        if d.intake == .takingIn, m.chatIDs == nil {
            var ids: [String: String] = [:]
            for f in m.files where f.path.hasPrefix(MoveMarker.chatsFolder + "/") {
                ids[String(f.path.dropFirst(MoveMarker.chatsFolder.count + 1).dropLast(5))] = UUID().uuidString
            }
            m.chatIDs = ids
        }
        try m.save(in: folder(callID), claimed: true)
    }

    private func takeIn(_ m: MoveMarker, _ callID: String, as f: String) throws {
        let call = callFolder(callID)
        var r = try CallRecord.load(from: call)
        if r.moveTo != nil || r.id != f {
            // The first half: names, voices, chats, then the record that arrived takes the place of call.json.
            let arrival = call.appendingPathComponent(MoveMarker.arrivalName)
            // Beside the marker, never in the call folder: it must not go into `Audio` with the meeting.
            let saved = folder(callID).appendingPathComponent(Self.namingName)
            var naming: MovedVoices.Naming?
            if r.moveTo != nil, let kept = try? CallRecord.load(from: call, fileName: MoveMarker.arrivalName), kept.id == f,
               let data = try? Data(contentsOf: saved), let n = try? JSONDecoder().decode(MovedVoices.Naming.self, from: data) {
                // A run that stopped after its decision: the same decision, never one made again on a library that
                // already learned from this call.
                naming = n
                let source = r
                r = kept
                try stop("learn the voices")
                try MovedVoices.learn(n, from: source, callID: f, library: library)
            } else if r.moveTo != nil {
                let source = r
                if ![.recorded, .transcribed, .recording].contains(r.status) {
                    let n = MovedVoices.decide(r, ownerKeys: Set(m.ownerKeys), library: library, ownerName: ownerName(),
                                               fingerprints: voiceFingerprints(), callID: f)
                    naming = n
                    MovedVoices.name(n, in: &r)
                    r.status = MovedRecord.arrival(status: r.status, failedStep: r.failedStep, namesChanged: n.changed)
                } else {
                    r.status = .recorded
                }
                r.failedStep = nil
                r.moveTo = nil
                r.id = f
                // The decision and the record as it will arrive, on the disk before anything is learned.
                try stop("write the arrival")
                if let naming { try JSONEncoder().encode(naming).write(to: saved, options: .atomic) }
                try r.save(to: call, fileName: MoveMarker.arrivalName)
                try MoveFiles.fullSync(arrival)
                if let naming {
                    try stop("learn the voices")
                    try MovedVoices.learn(naming, from: source, callID: f, library: library)
                }
            } else {
                // Decided again under another id after a stop: the arrived record takes it.
                r.id = f
                try r.save(to: call, fileName: MoveMarker.arrivalName)
            }
            try stop("write the chats")
            try writeChats(m, callID, as: f)
            try stop("arrive")
            guard Darwin.rename(arrival.path, call.appendingPathComponent(CallRecord.fileName).path) == 0 else {
                throw MoveFiles.Failed(code: errno)
            }
            try? FileManager.default.removeItem(at: saved)
            return
        }
        // The second half: one rename into `Audio`. Another volume refuses, and the first half is undone.
        try stop("into Audio")
        try FileManager.default.createDirectory(at: paths.audio, withIntermediateDirectories: true)
        do {
            try MoveFiles.rename(call, to: paths.callDirectory(f), with: rename)
        } catch is MoveFiles.OtherVolume {
            var refused = m
            try refuse(&refused, callID, .notWhole)
        }
        try? MoveFiles.fullSync(paths.audio)
    }

    private func writeChats(_ m: MoveMarker, _ callID: String, as f: String) throws {
        let store = ChatStore(directory: paths.chats)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        for (old, new) in (m.chatIDs ?? [:]).sorted(by: { $0.key < $1.key }) {
            let file = folder(callID).appendingPathComponent("\(MoveMarker.chatsFolder)/\(old).json")
            guard var chat = try? decoder.decode(Chat.self, from: Data(contentsOf: file)), let id = UUID(uuidString: new) else { continue }
            chat.id = id
            chat.callID = f
            for i in chat.messages.indices {
                chat.messages[i].text = chat.messages[i].text.replacingOccurrences(of: "mossad://call/\(m.callID)?", with: "mossad://call/\(f)?")
                    .replacingOccurrences(of: "mossad://call/\(m.callID))", with: "mossad://call/\(f))")
                chat.messages[i].actions = nil
            }
            try store.save(chat)
        }
    }

    /// The files in `Audio/<final id>` against the marker: each file that went as it was by its size and hash; the record
    /// and the chats, which arrived rewritten, by being there and reading.
    private func checked(_ m: MoveMarker, _ f: String) -> Bool {
        let dir = paths.callDirectory(f)
        var expected: [MoveMarker.File] = [], found: [String: (size: Int64, sha256: String)] = [:]
        for file in m.files {
            if file.path == "\(MoveMarker.callFolder)/\(CallRecord.fileName)" {
                guard (try? CallRecord.load(from: dir))?.id == f else { return false }
            } else if file.path.hasPrefix(MoveMarker.chatsFolder + "/") {
                let old = String(file.path.dropFirst(MoveMarker.chatsFolder.count + 1).dropLast(5))
                guard let new = m.chatIDs?[old], let id = UUID(uuidString: new), (try? ChatStore(directory: paths.chats).load(id)) != nil else { return false }
            } else {
                expected.append(file)
                let url = dir.appendingPathComponent(String(file.path.dropFirst(MoveMarker.callFolder.count + 1)))
                if let size = MoveCopy.size(url), let hash = try? FileHash.sha256(of: url) { found[file.path] = (size, hash) }
            }
        }
        return expected.isEmpty || MovePlan.held(expected, found: found)
    }

    /// A refusal first undoes this profile's own half: the meeting it put in `Audio`, the chats, and the voices it
    /// learned from the call. Then `refused`.
    private func refuse(_ m: inout MoveMarker, _ callID: String, _ why: MoveMarker.Refusal) throws {
        if let f = m.finalID {
            var arrived: CallRecord?
            if let inAudio = try? CallRecord.load(from: paths.callDirectory(f)), inAudio.id == f {
                arrived = inAudio
            } else if let here = try? CallRecord.load(from: callFolder(callID)), here.moveTo == nil {
                arrived = here
            }
            if let r = arrived {
                for (key, name) in r.speakerNames { try? library.forget(callID: f, speakerKey: key, from: name, voice: r.speakerEmbeddings[key]) }
            }
            try stop("undo the chats")
            for new in (m.chatIDs ?? [:]).values { if let id = UUID(uuidString: new) { ChatStore(directory: paths.chats).delete(id, record: false) } }
            // A meeting this move put in `Audio` goes back out of it, never one that was there.
            if !FileManager.default.fileExists(atPath: callFolder(callID).path), arrived?.id == f,
               FileManager.default.fileExists(atPath: paths.callDirectory(f).path) {
                try stop("out of Audio")
                try MoveFiles.rename(paths.callDirectory(f), to: callFolder(callID), with: rename)
            }
        }
        try stop("write refused")
        m.intake = .refused
        m.refusal = why
        try m.save(in: folder(callID), claimed: true)
    }
}
