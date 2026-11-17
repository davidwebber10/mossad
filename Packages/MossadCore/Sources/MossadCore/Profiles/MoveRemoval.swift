import Darwin
import Foundation

/// The first profile's removal of a meeting the target holds. It runs only after the source's rule said `.remove`.
/// Each step reads the record from the call folder, so the folder goes last; each step can run twice; the ledger keeps
/// the steps that ended, so a stop at any line goes on at the next run.
public enum MoveRemoval {
    public struct Actions: Sendable {
        /// By person id, as the People page's delete.
        public var forgetPersona: @Sendable (String) -> Void
        /// Through the one writer of the coach's memory.
        public var coach: @Sendable (@Sendable (inout CoachProfile) -> Void) throws -> Void
        public var stopShares: @Sendable (String) -> Void
        public var backup: @Sendable (CallRecord) async -> Void
        public var removeFolder: @Sendable (String) async -> Bool

        public init(forgetPersona: @escaping @Sendable (String) -> Void,
                    coach: @escaping @Sendable (@Sendable (inout CoachProfile) -> Void) throws -> Void,
                    stopShares: @escaping @Sendable (String) -> Void, backup: @escaping @Sendable (CallRecord) async -> Void,
                    removeFolder: @escaping @Sendable (String) async -> Bool) {
            self.forgetPersona = forgetPersona
            self.coach = coach
            self.stopShares = stopShares
            self.backup = backup
            self.removeFolder = removeFolder
        }
    }

    /// Each step that has not ended, in order, each saved in the ledger when it ended. A step that fails stops the
    /// removal until the next run. `stop` is called before each step and before each save, for a test.
    public static func advance(_ out: inout MoveOut, paths: Paths, library: VoiceLibrary, ownerName: String, actions: Actions, now: Date,
                               stop: (String) throws -> Void = { _ in }) async throws {
        while let step = out.nextStep {
            try stop("\(step.rawValue) begins")
            guard await run(step, callID: out.callID, paths: paths, library: library, ownerName: ownerName, actions: actions, now: now) else { return }
            try stop("\(step.rawValue) ended, before its save")
            out.removed.append(step.rawValue)
            try out.save(paths)
        }
    }

    /// One step. True when it ended, also when the call folder is gone already. False stops the removal until the next run.
    public static func run(_ step: MoveOut.Step, callID: String, paths: Paths, library: VoiceLibrary, ownerName: String,
                           actions: Actions, now: Date) async -> Bool {
        if step == .folder { return await actions.removeFolder(callID) }
        // The folder is gone: each step before it ended in an earlier run.
        guard let r = try? CallRecord.load(from: paths.callDirectory(callID)) else {
            return !FileManager.default.fileExists(atPath: paths.callDirectory(callID).path)
        }
        do {
            switch step {
            case .voices:
                let owner = OwnerIdentity.read(name: ownerName, paths: paths).speakerKeys(in: r)
                for (key, name) in r.speakerNames {
                    guard let voice = r.speakerEmbeddings[key] else { continue }
                    let from = owner.contains(key) ? (library.owner?.name ?? name) : name
                    try library.forget(callID: callID, speakerKey: key, from: from, voice: voice)
                }
            case .people:
                let store = library.identity?.people
                let gone = peopleToRemove(r, people: store?.people ?? [], samples: library.identity?.samples.samples ?? [],
                                          others: ProcessingQueue(paths: paths).allRecords().filter { $0.id != callID })
                for p in gone {
                    actions.forgetPersona(p.id.rawValue)
                    if library.profiles.contains(where: { $0.name == p.displayName }) { try library.delete(p.displayName) }
                    if let store, store.people.contains(where: { $0.id == p.id && $0.isLive }) { try store.delete(p.id) }
                    let id = p.id.rawValue, name = p.displayName
                    try actions.coach { $0.forget(person: id, name: name) }
                }
            case .coach:
                try actions.coach { $0.forgetMoved(callID: callID) }
                CoachRunner.forget(callID, paths: paths)
                _ = PersonaStore(paths: paths).forget(callID: callID, at: now)
            case .books:
                var tasks = try CommitmentBook.load(from: paths.commitments)
                if tasks.forget(callID: callID, at: now) > 0 { try tasks.save(to: paths.commitments) }
                _ = try NextTimeBook.change(in: paths.nextTime) { _ = $0.forget(callID: callID, at: now) }
                _ = ChatStore(directory: paths.chats).deleteChats(forCall: callID)
            case .shares:
                actions.stopShares(callID)
            case .backup:
                await actions.backup(r)
            case .notes:
                RemovedNotes.add(r, paths: paths)
            case .folder:
                break
            }
            return true
        } catch {
            Log.error("Move: the removal stopped at its \(step.rawValue) step; the next run goes on: \(error)")
            return false
        }
    }

    /// The note, its two reference backups, and the call folder: the folder is renamed out of `Audio` first, in one
    /// step, then deleted. A folder that is gone counts as done.
    public static func removeFolder(_ callID: String, paths: Paths) -> Bool {
        (try? removeFolderOrStop(callID, paths: paths, stop: { _ in })) ?? false
    }

    public static func removeFolder(_ callID: String, paths: Paths, stop: (String) throws -> Void) -> Bool {
        (try? removeFolderOrStop(callID, paths: paths, stop: stop)) ?? false
    }

    static func removeFolderOrStop(_ callID: String, paths: Paths, stop: (String) throws -> Void) throws -> Bool {
        let fm = FileManager.default
        let dir = paths.callDirectory(callID)
        let out = paths.moves.appendingPathComponent("\(callID).removing")
        if let r = try? CallRecord.load(from: dir) {
            try stop("folder: the note")
            if let note = r.markdownPath {
                ReferenceBackup.forget(note: note, paths: paths)
                try? fm.removeItem(atPath: note)
            }
            ReferenceBackup.forget(callID: callID, paths: paths)
        }
        if fm.fileExists(atPath: dir.path) {
            try stop("folder: out of Audio")
            try fm.createDirectory(at: paths.moves, withIntermediateDirectories: true)
            if fm.fileExists(atPath: out.path) { try fm.removeItem(at: out) }
            guard Darwin.rename(dir.path, out.path) == 0 else { return false }
        }
        if fm.fileExists(atPath: out.path) {
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
