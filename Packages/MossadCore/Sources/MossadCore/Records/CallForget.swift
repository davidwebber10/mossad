import Darwin
import Foundation

/// The removal of everything Mossad made of one call, for a move to another profile, a Delete, and the cut of a
/// recording into parts. Each step reads the record from the call folder, so the folder goes last; each step can run
/// twice; the caller's ledger keeps the steps that ended, so a stop at any line goes on at the next run.
public enum CallForget {
    /// The steps in order. A move runs its own step for people between `voices` and `coach` (`MoveRemoval`).
    public enum Step: String, Codable, CaseIterable, Sendable { case voices, coach, books, shares, backup, notes, folder }

    /// Why the call goes. Only the books and the notes differ.
    public enum Purpose: Sendable, Equatable {
        /// The meeting left for another profile; `gone` is the people who went with it, `went` the points the target took
        /// (nil for a ledger of an older build: see `NextTimeBook.forget`).
        case move(gone: Set<String>, went: Set<UUID>?)
        /// The owner deleted it. No person goes: the owner deletes a person on the People page.
        case delete
        /// The recording was cut into parts: the owner's ticks and the live chat go to the part in which they were made.
        case cut([CutPart])
    }

    /// A part of a cut recording, for what goes to it by time.
    public struct CutPart: Codable, Equatable, Sendable {
        public var id: String
        /// Where the part begins in the original's recording, in seconds.
        public var from: TimeInterval
        public var start: Date
        public var end: Date

        public init(id: String, from: TimeInterval, start: Date, end: Date) {
            self.id = id
            self.from = from
            self.start = start
            self.end = end
        }

        /// The part that holds second `at` of the original: the last that begins at or before it.
        static func holding(_ at: TimeInterval, in parts: [CutPart]) -> CutPart? {
            parts.sorted { $0.from < $1.from }.last { $0.from <= at } ?? parts.min { $0.from < $1.from }
        }

        /// The part that ran at wall time `date`.
        static func running(at date: Date, in parts: [CutPart]) -> CutPart? {
            parts.sorted { $0.start < $1.start }.last { $0.start <= date } ?? parts.min { $0.start < $1.start }
        }
    }

    /// What the removal asks of its caller, each one the caller's real way.
    public struct Actions: Sendable {
        /// Through the one writer of the coach's memory.
        public var coach: @Sendable (@Sendable (inout CoachProfile) -> Void) throws -> Void
        /// Marks every share link of the call as stopping and saves the mark.
        public var stopShares: @Sendable (String) -> Void
        /// Deletes the backup copies of the record, or saves the delete for a later try. False: neither happened.
        public var backup: @Sendable (CallRecord) async -> Bool
        /// The note, its backups, and the call folder.
        public var removeFolder: @Sendable (_ callID: String) async -> Bool

        public init(coach: @escaping @Sendable (@Sendable (inout CoachProfile) -> Void) throws -> Void,
                    stopShares: @escaping @Sendable (String) -> Void, backup: @escaping @Sendable (CallRecord) async -> Bool,
                    removeFolder: @escaping @Sendable (_ callID: String) async -> Bool) {
            self.coach = coach
            self.stopShares = stopShares
            self.backup = backup
            self.removeFolder = removeFolder
        }

        /// The actions on the files alone, for a process that holds nothing of them in memory (a worker, a command):
        /// the coach's file, the share book (the window app tells the server), and the remembered backup deletes.
        public static func files(paths: Paths, removeFolder: @escaping @Sendable (String) async -> Bool) -> Actions {
            Actions(
                coach: { change in
                    var profile = try CoachProfile.load(from: paths.coach)
                    let before = profile
                    change(&profile)
                    if profile != before { try profile.save(to: paths.coach) }
                },
                stopShares: { callID in
                    var book = ShareBook.load(from: paths.shares)
                    let before = book
                    book.markStopping(callID: callID)
                    if book != before { try? book.save(to: paths.shares) }
                },
                backup: { CloudArchive.rememberDeletes(of: $0, paths: paths) },
                removeFolder: removeFolder)
        }
    }

    /// One step. True when it ended, also when the call folder is gone already. False stops the removal until the
    /// next run: a failure, or a step that cannot be done now.
    public static func run(_ step: Step, callID: String, purpose: Purpose, paths: Paths, library: VoiceLibrary, ownerName: String,
                           actions: Actions, now: Date, stop: (String) throws -> Void = { _ in }) async throws -> Bool {
        guard MovePaths.isID(callID) else { return false }
        if step == .folder { return await actions.removeFolder(callID) }
        // The folder is gone: each step before it ended in an earlier run.
        guard let r = try? CallRecord.load(from: paths.callDirectory(callID)) else {
            return !FileManager.default.fileExists(atPath: paths.callDirectory(callID).path)
        }
        do {
            switch step {
            case .voices:
                // Without the samples' own record nothing can be forgotten: not now, never "done". A recording that was
                // never identified taught no voice, so there is nothing to wait for (not for a move: its rule is kept).
                guard library.identity != nil else {
                    if case .move = purpose { return false }
                    return r.speakerEmbeddings.isEmpty && r.status == .recorded
                }
                let owner = OwnerIdentity.read(name: ownerName, paths: paths).speakerKeys(in: r)
                for (key, name) in r.speakerNames.sorted(by: { $0.key < $1.key }) {
                    guard let voice = r.speakerEmbeddings[key] else { continue }
                    let from = owner.contains(key) ? (library.owner?.name ?? name) : name
                    try stop("voices: forget \(key)")
                    try library.forget(callID: callID, speakerKey: key, from: from, voice: voice)
                }
                // By the samples' own call id: a label that a rename or a merge made old finds nothing above.
                try stop("voices: forget the call's samples")
                try library.forgetSamples(ofCall: callID)
            case .coach:
                try stop("coach: the memory")
                // A move takes the owner's answers and what they confirmed with it. A Delete and a cut keep them, as the
                // Delete always did: each answer is a signal about the coaching, not about the meeting.
                if case .move = purpose {
                    try actions.coach { $0.forgetMoved(callID: callID) }
                } else {
                    try actions.coach { $0.forget(callID: callID) }
                }
                try stop("coach: the runner")
                CoachRunner.forget(callID, paths: paths)
                try stop("coach: the reads")
                _ = PersonaStore(paths: paths).forget(callID: callID, at: now)
            case .books:
                try stop("books: the tasks")
                var tasks = try CommitmentBook.load(from: paths.commitments)
                if tasks.forget(callID: callID, at: now) > 0 { try tasks.save(to: paths.commitments) }
                try stop("books: the points")
                switch purpose {
                case let .move(gone, went):
                    // Exactly the points that went and that the target took (the ledger's list, as the points are now); a
                    // ledger of an older build has no list and empties what it emptied before.
                    let live = Set((library.identity?.people.people ?? []).filter(\.isLive).map(\.id.rawValue))
                    let leaving = gone.subtracting(live)
                    _ = try NextTimeBook.change(in: paths.nextTime) { _ = $0.forget(callID: callID, record: r, gone: leaving, went: went, at: now) }
                case .delete:
                    _ = try NextTimeBook.change(in: paths.nextTime) { _ = $0.forget(callID: callID, record: r, gone: [], at: now) }
                case let .cut(parts):
                    _ = try NextTimeBook.change(in: paths.nextTime) { _ = $0.handOver(callID: callID, to: parts, at: now) }
                    try stop("books: the live chat")
                    handOverLiveChats(callID: callID, to: parts, paths: paths)
                }
                try stop("books: the chats")
                _ = ChatStore(directory: paths.chats).deleteChats(forCall: callID)
            case .shares:
                try stop("shares: stop")
                actions.stopShares(callID)
                // A link of the call that is still live on the server, with no saved mark, is a leak: not done.
                guard MoveRemoval.sharesStopped(callID, paths: paths) else { return false }
            case .backup:
                try stop("backup: delete")
                guard await actions.backup(r) else { return false }
            case .notes:
                // The notes of a cut recording may still belong to one of its parts.
                if case .cut = purpose { break }
                try stop("notes: remember")
                RemovedNotes.add(r, paths: paths)
            case .folder:
                break
            }
            return true
        } catch is MoveStop {
            throw MoveStop()
        } catch {
            if case .move = purpose {
                Log.error("Move: the removal stopped at its \(step.rawValue) step; the next run goes on: \(error)")
            } else {
                Log.error("The removal of \(callID) stopped at its \(step.rawValue) step; the next run goes on: \(error)")
            }
            return false
        }
    }

    /// The chats asked during the call go to the part in which their first question was asked; the others go with
    /// the original.
    static func handOverLiveChats(callID: String, to parts: [CutPart], paths: Paths) {
        let store = ChatStore(directory: paths.chats)
        for var chat in store.all() where chat.callID == callID && chat.messages.contains(where: { $0.live == true }) {
            let asked = chat.messages.compactMap(\.asked).min() ?? chat.created
            guard let part = CutPart.running(at: asked, in: parts) else { continue }
            chat.callID = part.id
            do { try store.save(chat) } catch {
                // A part marked for another profile takes no chat: the chat goes with the original.
                Log.info("A live chat of \(callID) could not go to its part: \(error)")
            }
        }
    }

    /// The call folder is renamed out of `Audio` into `outside` first, in one step, then the note and its two reference
    /// backups go (read from the record in the renamed folder), then the folder. A folder that is gone counts as done.
    /// `forgetLog` also takes the log's lines that name the call or its note.
    static func removeFolder(_ callID: String, paths: Paths, outside: URL, forgetLog: Bool, stop: (String) throws -> Void) throws -> Bool {
        guard MovePaths.isID(callID) else { return false }
        let fm = FileManager.default
        let dir = paths.callDirectory(callID)
        let out = outside.appendingPathComponent("\(callID).removing")
        if fm.fileExists(atPath: dir.path) {
            try stop("folder: out of Audio")
            try fm.createDirectory(at: outside, withIntermediateDirectories: true)
            if fm.fileExists(atPath: out.path) { try fm.removeItem(at: out) }
            guard Darwin.rename(dir.path, out.path) == 0 else { return false }
        }
        if fm.fileExists(atPath: out.path) {
            if let r = try? CallRecord.load(from: out) {
                try stop("folder: the note")
                if let note = r.markdownPath {
                    ReferenceBackup.forget(note: note, paths: paths)
                    try? fm.removeItem(atPath: note)
                }
                ReferenceBackup.forget(callID: callID, paths: paths)
                // The log keeps the note's file name (its title) and the id: those lines go too, before the folder,
                // so a run after a stop does it again from the record.
                if forgetLog {
                    guard Log.forget(naming: [callID, r.markdownPath.map { ($0 as NSString).lastPathComponent } ?? ""], in: paths.logs)
                    else { return false }
                }
            }
            try stop("folder: delete")
            try fm.removeItem(at: out)
        }
        return true
    }

    /// Where a Delete and a cut put a call folder on its way out: never `Moves`, which only a move makes.
    static func deleting(_ paths: Paths) -> URL { paths.root.appendingPathComponent("Deleting") }
}

/// The meetings the owner deleted whose removal has not ended: `deletes.json` in the profile's folder. Each entry keeps
/// the steps that ended, so a quit in the middle goes on at the next launch.
public struct DeleteLedger: Codable, Equatable, Sendable {
    public static let fileName = "deletes.json"

    public struct Entry: Codable, Equatable, Sendable {
        public var callID: String
        public var removed: [String]
        public var started: Date

        public var nextStep: CallForget.Step? { CallForget.Step.allCases.first { !removed.contains($0.rawValue) } }
    }

    public var entries: [Entry] = []

    static func url(_ paths: Paths) -> URL { paths.root.appendingPathComponent(fileName) }

    /// An empty ledger when there is none; nil when the file is there and does not read: then nothing is changed.
    public static func load(_ paths: Paths) -> DeleteLedger? {
        guard let data = try? Data(contentsOf: url(paths)) else {
            return FileManager.default.fileExists(atPath: url(paths).path) ? nil : DeleteLedger()
        }
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return try? d.decode(DeleteLedger.self, from: data)
    }

    public func save(_ paths: Paths) throws {
        guard !entries.isEmpty else {
            try? FileManager.default.removeItem(at: Self.url(paths))
            return
        }
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.sortedKeys]
        try e.encode(self).write(to: Self.url(paths), options: .atomic)
    }

    public func contains(_ callID: String) -> Bool { entries.contains { $0.callID == callID } }
}

extension NextTimeBook {
    /// A recording that was cut: the owner's ticks go to the part in which they were made, by their second; a
    /// "discussed" that the check found is open again (the check runs on each part); nothing else names the
    /// original. Its id goes into `movedCalls`, so a copy from another device cannot bring it back. A point of that
    /// one meeting stays: each part is matched to its own invite.
    @discardableResult
    public mutating func handOver(callID: String, to parts: [CallForget.CutPart], at date: Date = Date()) -> Bool {
        var changed = false
        for i in points.indices {
            guard let done = points[i].done, done.callID == callID else { continue }
            if done.byOwner, let part = CallForget.CutPart.holding(done.at ?? 0, in: parts) {
                points[i].done?.callID = part.id
                points[i].done?.at = done.at.map { $0 - part.from }
            } else {
                points[i].done = nil
            }
            points[i].updated = date
            changed = true
        }
        for i in points.indices {
            let kept = points[i].suggestion
            let before = points[i]
            // A point kept from a suggestion of the original is not emptied: the owner kept its words.
            points[i].suggestion = nil
            _ = Self.clean(&points[i], of: [callID])
            points[i].suggestion = kept
            if points[i] != before {
                points[i].updated = date
                changed = true
            }
        }
        if checked.remove(callID) != nil { changed = true }
        if movedCalls?.contains(callID) != true {
            movedCalls = ((movedCalls ?? []) + [callID]).sorted()
            changed = true
        }
        return changed
    }
}

extension LivePointMarks {
    /// The marks of one part of a cut recording, with their seconds moved back by `from`.
    func divided(from: TimeInterval, to: TimeInterval?) -> LivePointMarks {
        func inside(_ at: TimeInterval) -> Bool { at >= from && (to.map { at < $0 } ?? true) }
        var out = LivePointMarks()
        out.marks = marks.filter { inside($0.at) }.map { Mark(point: $0.point, at: $0.at - from, quote: $0.quote) }
        out.asks = asks.filter { inside($0.at) }.map { Ask(point: $0.point, at: $0.at - from, through: max(0, $0.through - from)) }
        let rejected = (rejected ?? []).filter { inside($0.at) }.map { Mark(point: $0.point, at: $0.at - from, quote: $0.quote) }
        out.rejected = rejected.isEmpty ? nil : rejected
        return out
    }
}
