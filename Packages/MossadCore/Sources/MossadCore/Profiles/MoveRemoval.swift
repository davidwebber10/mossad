import Darwin
import Foundation

/// The first profile's removal of a meeting the target holds. It runs only after the source's rule said `.remove`.
/// Each step reads the record from the call folder, so the folder goes last; each step can run twice; the ledger keeps
/// the steps that ended, so a stop at any line goes on at the next run.
public enum MoveRemoval {
    /// What the removal asks of its caller. There is no default: each one is the caller's real way, and each says
    /// whether it was done, so a step never ends as done with nothing done.
    public struct Actions: Sendable {
        /// By person id, as the People page's delete.
        public var forgetPersona: @Sendable (String) -> Void
        /// Through the one writer of the coach's memory.
        public var coach: @Sendable (@Sendable (inout CoachProfile) -> Void) throws -> Void
        /// Marks every share link of the call as stopping and saves the mark, so the server is told now or at a later
        /// try. The step then reads the saved book: a link of the call that is not marked keeps the step open.
        public var stopShares: @Sendable (String) -> Void
        /// Deletes the backup copies of the record, or saves the delete for a later try (`CloudArchive.rememberDeletes`).
        /// False: neither happened, and the step runs again at the next look.
        public var backup: @Sendable (CallRecord) async -> Bool
        /// `Pipeline.removeMoved(callID:target:)`: the note, its backups, and the call folder.
        public var removeFolder: @Sendable (_ callID: String, _ target: String) async -> Bool

        public init(forgetPersona: @escaping @Sendable (String) -> Void,
                    coach: @escaping @Sendable (@Sendable (inout CoachProfile) -> Void) throws -> Void,
                    stopShares: @escaping @Sendable (String) -> Void, backup: @escaping @Sendable (CallRecord) async -> Bool,
                    removeFolder: @escaping @Sendable (_ callID: String, _ target: String) async -> Bool) {
            self.forgetPersona = forgetPersona
            self.coach = coach
            self.stopShares = stopShares
            self.backup = backup
            self.removeFolder = removeFolder
        }
    }

    /// Each step that has not ended, in order, each saved in the ledger only after it ended. A step that fails, or
    /// cannot be done now, stops the removal until the next run. `stop` is called before each step, inside it, and
    /// before each save, for a test.
    public static func advance(_ out: inout MoveOut, paths: Paths, library: VoiceLibrary, ownerName: String, actions: Actions, now: Date,
                               stop: (String) throws -> Void = { _ in }) async throws {
        while let step = out.nextStep {
            try stop("\(step.rawValue) begins")
            if step == .people, out.people == nil {
                // The people who go are decided once and kept by id, before the first delete: a run after a stop
                // finishes the same list, also for a person who is gone already.
                guard let decided = peopleIDs(out.callID, paths: paths, library: library) else { return }
                try stop("people: save the list")
                out.people = decided
                try out.save(paths)
            }
            guard try await run(step, out: out, paths: paths, library: library, ownerName: ownerName, actions: actions, now: now, stop: stop)
            else { return }
            try stop("\(step.rawValue) ended, before its save")
            out.removed.append(step.rawValue)
            try out.save(paths)
        }
    }

    /// The ids of the people whom only this call made; nil while that cannot be known (no identity yet).
    static func peopleIDs(_ callID: String, paths: Paths, library: VoiceLibrary) -> [String]? {
        guard let identity = library.identity else { return nil }
        guard let r = try? CallRecord.load(from: paths.callDirectory(callID)) else {
            return FileManager.default.fileExists(atPath: paths.callDirectory(callID).path) ? nil : []
        }
        return peopleToRemove(r, people: identity.people.people, samples: identity.samples.samples,
                              others: ProcessingQueue(paths: paths).allRecords().filter { $0.id != callID }).map(\.id.rawValue)
    }

    /// One step. True when it ended, also when the call folder is gone already. False stops the removal until the
    /// next run: a failure, or a step that cannot be done now (no identity yet, a share mark not saved).
    public static func run(_ step: MoveOut.Step, out: MoveOut, paths: Paths, library: VoiceLibrary, ownerName: String,
                           actions: Actions, now: Date, stop: (String) throws -> Void = { _ in }) async throws -> Bool {
        let callID = out.callID
        guard MovePaths.isID(callID) else { return false }
        if step == .folder { return await actions.removeFolder(callID, out.to) }
        // The folder is gone: each step before it ended in an earlier run.
        guard let r = try? CallRecord.load(from: paths.callDirectory(callID)) else {
            return !FileManager.default.fileExists(atPath: paths.callDirectory(callID).path)
        }
        do {
            switch step {
            case .voices:
                // Without the samples' own record nothing can be forgotten: not now, never "done".
                guard library.identity != nil else { return false }
                let owner = OwnerIdentity.read(name: ownerName, paths: paths).speakerKeys(in: r)
                for (key, name) in r.speakerNames.sorted(by: { $0.key < $1.key }) {
                    guard let voice = r.speakerEmbeddings[key] else { continue }
                    let from = owner.contains(key) ? (library.owner?.name ?? name) : name
                    try stop("voices: forget \(key)")
                    try library.forget(callID: callID, speakerKey: key, from: from, voice: voice)
                }
            case .people:
                guard let identity = library.identity else { return false }
                let store = identity.people
                for id in out.people ?? [] {
                    let person = store.people.first { $0.id.rawValue == id }
                    let name = person?.displayName ?? ""
                    // The coach forgets first and the person goes last: a stop between them leaves the person, and the
                    // next run does it all again.
                    try stop("people: forget the read of \(id)")
                    actions.forgetPersona(id)
                    try stop("people: the coach forgets \(id)")
                    try actions.coach { $0.forget(person: id, name: name) }
                    if let person, person.isLive {
                        try stop("people: the voice of \(id)")
                        if !name.isEmpty, library.profiles.contains(where: { $0.name == name }) { try library.delete(name) }
                        try stop("people: the person \(id)")
                        if store.people.contains(where: { $0.id == person.id && $0.isLive }) { try store.delete(person.id) }
                    }
                }
            case .coach:
                try stop("coach: the memory")
                try actions.coach { $0.forgetMoved(callID: callID) }
                try stop("coach: the runner")
                CoachRunner.forget(callID, paths: paths)
                try stop("coach: the reads")
                _ = PersonaStore(paths: paths).forget(callID: callID, at: now)
            case .books:
                try stop("books: the tasks")
                var tasks = try CommitmentBook.load(from: paths.commitments)
                if tasks.forget(callID: callID, at: now) > 0 { try tasks.save(to: paths.commitments) }
                try stop("books: the points")
                _ = try NextTimeBook.change(in: paths.nextTime) { _ = $0.forget(callID: callID, at: now) }
                try stop("books: the chats")
                _ = ChatStore(directory: paths.chats).deleteChats(forCall: callID)
            case .shares:
                try stop("shares: stop")
                actions.stopShares(callID)
                // A link of the call that is still live on the server, with no saved mark, is a leak: not done.
                guard !ShareBook.load(from: paths.shares).links.contains(where: { $0.callID == callID && $0.stopping != true }) else { return false }
            case .backup:
                try stop("backup: delete")
                guard await actions.backup(r) else { return false }
            case .notes:
                try stop("notes: remember")
                RemovedNotes.add(r, paths: paths)
            case .folder:
                break
            }
            return true
        } catch is MoveStop {
            throw MoveStop()
        } catch {
            Log.error("Move: the removal stopped at its \(step.rawValue) step; the next run goes on: \(error)")
            return false
        }
    }

    /// The call folder is renamed out of `Audio` first, in one step, then the note and its two reference backups go
    /// (read from the record in the renamed folder), then the folder. A folder that is gone counts as done. Only the
    /// asked id, checked by `MovePaths`.
    public static func removeFolder(_ callID: String, paths: Paths) -> Bool {
        (try? removeFolderOrStop(callID, paths: paths, stop: { _ in })) ?? false
    }

    public static func removeFolder(_ callID: String, paths: Paths, stop: (String) throws -> Void) -> Bool {
        (try? removeFolderOrStop(callID, paths: paths, stop: stop)) ?? false
    }

    static func removeFolderOrStop(_ callID: String, paths: Paths, stop: (String) throws -> Void) throws -> Bool {
        guard MovePaths.isID(callID) else { return false }
        let fm = FileManager.default
        let dir = paths.callDirectory(callID)
        let out = paths.moves.appendingPathComponent("\(callID).removing")
        if fm.fileExists(atPath: dir.path) {
            try stop("folder: out of Audio")
            try fm.createDirectory(at: paths.moves, withIntermediateDirectories: true)
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
                guard Log.forget(naming: [callID, r.markdownPath.map { ($0 as NSString).lastPathComponent } ?? ""], in: paths.logs) else { return false }
            }
            try stop("folder: delete")
            try fm.removeItem(at: out)
        }
        return true
    }

    /// The people whom only this meeting made. Asked after the `voices` step.
    public static func peopleToRemove(_ r: CallRecord, people: [Person], samples: [VoiceSample], others: [CallRecord]) -> [Person] {
        let voiceIDs = Set((r.speakerPeople ?? [:]).values), voiceNames = Set(r.speakerNames.values)
        let kept: Set<SourceKind> = [.orgChart, .googleDirectory, .googleContacts, .migration]
        return people.filter { p in
            guard p.isLive, !p.isOwner, p.created >= r.start, !kept.contains(p.origin) else { return false }
            guard voiceIDs.contains(p.id.rawValue) || voiceNames.contains(p.displayName) else { return false }
            guard !samples.contains(where: { $0.personID == p.id }) else { return false }
            return !others.contains { o in
                (o.speakerPeople ?? [:]).values.contains(p.id.rawValue) || o.speakerNames.values.contains(p.displayName)
                    || (o.invitees ?? []).contains { $0.personID == p.id.rawValue }
            }
        }
    }
}
