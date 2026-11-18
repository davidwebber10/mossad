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
            if step == .voices || step == .people, out.people == nil {
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
        guard let others = otherRecords(excluding: callID, paths: paths) else { return nil }
        return peopleToRemove(r, people: identity.people.people, samples: identity.samples.samples, others: others).map(\.id.rawValue)
    }

    /// Why a removal step that did not end waits, as far as this profile can tell.
    static func waitKind(_ step: MoveOut.Step, library: VoiceLibrary) -> MoveOut.Wait {
        if library.identity == nil, [.voices, .people].contains(step) { return .peopleNotReady }
        switch step {
        case .shares: return .shareNotSaved
        case .backup: return .backupNotDone
        case .folder: return .folderNotRemoved
        default: return .failed
        }
    }

    /// Every other meeting's record; nil when one cannot be read or `Audio` does not list: that meeting may be one of
    /// the person's, so nobody goes until it reads.
    static func otherRecords(excluding callID: String, paths: Paths) -> [CallRecord]? {
        guard let names = MoveIntake.audioNames(paths.audio, missingIsEmpty: true) else { return nil }
        var out: [CallRecord] = []
        for name in names.sorted() where name != callID && !name.hasPrefix(".") {
            let dir = paths.audio.appendingPathComponent(name)
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: dir.path, isDirectory: &isDir), isDir.boolValue else { continue }
            guard FileManager.default.fileExists(atPath: dir.appendingPathComponent(CallRecord.fileName).path) else { continue }
            guard let r = try? CallRecord.load(from: dir) else { return nil }
            out.append(r)
        }
        return out
    }

    /// No live link of the call is left in a book that reads; a book that does not read is not known.
    static func sharesStopped(_ callID: String, paths: Paths) -> Bool {
        guard let book = try? ShareBook.loadChecked(from: paths.shares) else { return false }
        return !book.links.contains { $0.callID == callID && $0.stopping != true }
    }

    /// One step. True when it ended, also when the call folder is gone already. False stops the removal until the
    /// next run: a failure, or a step that cannot be done now (no identity yet, a share mark not saved). Every step but
    /// `people` is the one removal of a call (`CallForget`), which a Delete and a cut run too.
    public static func run(_ step: MoveOut.Step, out: MoveOut, paths: Paths, library: VoiceLibrary, ownerName: String,
                           actions: Actions, now: Date, stop: (String) throws -> Void = { _ in }) async throws -> Bool {
        let callID = out.callID
        guard MovePaths.isID(callID) else { return false }
        guard step == .people else {
            guard let shared = CallForget.Step(rawValue: step.rawValue) else { return false }
            let to = out.to
            let forget = CallForget.Actions(coach: actions.coach, stopShares: actions.stopShares, backup: actions.backup,
                                            removeFolder: { await actions.removeFolder($0, to) })
            let went = out.points.map { ids in out.pointsTaken == true ? Set(ids.compactMap(UUID.init(uuidString:))) : [] }
            return try await CallForget.run(shared, callID: callID, purpose: .move(gone: Set(out.people ?? []), went: went), paths: paths,
                                            library: library, ownerName: ownerName, actions: forget, now: now, stop: stop)
        }
        // The folder is gone: each step before it ended in an earlier run.
        guard let r = try? CallRecord.load(from: paths.callDirectory(callID)) else {
            return !FileManager.default.fileExists(atPath: paths.callDirectory(callID).path)
        }
        do {
            guard let identity = library.identity else { return false }
            let store = identity.people
            // The list was decided once, maybe days ago: at the delete the rule is applied again to each person as
            // they are now, and a record that does not read keeps everyone.
            guard let others = otherRecords(excluding: callID, paths: paths) else { return false }
            var goes: Set<String> = []
            for id in out.people ?? [] {
                let person = store.people.first { $0.id.rawValue == id }
                if let person, person.isLive,
                   peopleToRemove(r, people: [person], samples: identity.samples.samples, others: others, ofCall: Set(out.people ?? [])).isEmpty { continue }
                goes.insert(id)
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
            // The migration's plan and report name the call and the people: written again without them.
            try stop("people: the migration files")
            try PeopleMigration.forget(callID: callID, people: goes, paths: paths)
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
        try CallForget.removeFolder(callID, paths: paths, outside: paths.moves, forgetLog: true, stop: stop)
    }

    /// The people whom only this meeting made. Asked after the `voices` step.
    /// A person is of the call by the record's ids or labels, by a sample the call taught (a rename since does not hide
    /// it), or by `ofCall` (decided before the samples went). Only samples of other calls keep them.
    public static func peopleToRemove(_ r: CallRecord, people: [Person], samples: [VoiceSample], others: [CallRecord],
                                      ofCall: Set<String> = []) -> [Person] {
        let voiceIDs = Set((r.speakerPeople ?? [:]).values).union(ofCall)
            .union(samples.filter { $0.callID == r.id }.compactMap { $0.personID?.rawValue })
        let voiceNames = Set(r.speakerNames.values)
        let kept: Set<SourceKind> = [.orgChart, .googleDirectory, .googleContacts, .migration]
        return people.filter { p in
            guard p.isLive, !p.isOwner, p.created >= r.start, !kept.contains(p.origin) else { return false }
            guard voiceIDs.contains(p.id.rawValue) || voiceNames.contains(p.displayName) else { return false }
            guard !samples.contains(where: { $0.personID == p.id && $0.callID != r.id }) else { return false }
            return !others.contains { o in
                (o.speakerPeople ?? [:]).values.contains(p.id.rawValue) || o.speakerNames.values.contains(p.displayName)
                    || (o.invitees ?? []).contains { $0.personID == p.id.rawValue }
            }
        }
    }
}
