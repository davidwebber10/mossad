import Foundation

/// Sync between the Mac and the iPhone through a record store: iCloud's private database, or the owner's own
/// server. The Mac pushes finished meetings and the coach's memory; the phone pulls them into its own copy of
/// the folder layout, so the same readers work on both. Chats, review notes, the memory, and commitments go
/// both ways; room recordings go from the phone to the Mac.
public actor CloudSync {
    static let meetingType = "Meeting"
    static let profileType = "CoachProfile"
    static let profileName = "coach-profile"
    static let chatType = "Chat"
    static let notesType = "CoachNotes"
    static let commitmentsType = "Commitments"
    static let recordingType = "Recording"
    /// Assets make big requests, so stay well under CloudKit's 400 changes a request.
    static let batch = 50

    private let store: any RecordStore
    private let paths: Paths
    private let now: @Sendable () -> Date
    private var prepared = false

    public init(paths: Paths, store: any RecordStore, now: @escaping @Sendable () -> Date = Date.init) {
        self.paths = paths
        self.store = store
        self.now = now
    }

    /// iCloud, as before.
    public init(paths: Paths) {
        self.init(paths: paths, store: CloudKitStore())
    }

    private func prepare() async throws {
        guard !prepared else { return }
        try await store.prepare()
        prepared = true
    }

    private func loadState() throws -> SyncState { try SyncState.load(from: paths.sync, fileName: store.stateFileName) }

    /// Loads the state, changes it, and saves it with no await in between. A push and a pull can run at the same
    /// time on this actor; a copy held across a network call would write the other's change away.
    private func update(_ change: (inout SyncState) -> Void) throws {
        var s = try loadState()
        change(&s)
        try s.save(to: paths.sync, fileName: store.stateFileName)
    }

    /// Record names become folder and file names here, so a store that was taken over must not choose them.
    static func isSafeName(_ name: String) -> Bool {
        // A leading dot covers "." (the folder itself) and hidden files.
        !name.isEmpty && !name.hasPrefix(".") && !name.contains("..") && !name.hasSuffix(".") && name.count <= 200
            && name.unicodeScalars.allSatisfy { $0.isASCII && (CharacterSet.alphanumerics.contains($0) || "._-".unicodeScalars.contains($0)) }
    }

    /// A chat, a profile, or a meeting whose content cannot be used (it does not decode) is left behind after this
    /// many pulls, so one bad record cannot stop the sync for good. A phone recording is never left by a count; see
    /// `PendingRecording`.
    static let maxRecordFailures = 5

    /// What a failed record means for the next pull.
    enum Failure { case passes, local, content }

    /// - `passes`: the network or a busy server; the same request works later.
    /// - `local`: this device could not write (a full disk, no permission). Nothing is wrong with the record.
    /// - `content`: the record itself cannot be used, or the store no longer has its data.
    static func kind(of error: Error) -> Failure {
        if TransientRetry.isTransient(error) || error is URLError || error is CancellationError { return .passes }
        if case .http(let code, _) = error as? ServerError { return code == 404 || code == 410 ? .content : .passes }
        let e = error as NSError
        if e.domain == NSCocoaErrorDomain, (CocoaError.fileWriteUnknown.rawValue...CocoaError.fileWriteVolumeReadOnly.rawValue).contains(e.code) { return .local }
        if e.domain == NSPOSIXErrorDomain, [ENOSPC, EACCES, EPERM, EROFS, EDQUOT, EIO, ENOENT].contains(Int32(e.code)) { return .local }
        // Core Audio's file errors while the track is written: disk full, no permission, locked volume or file.
        if e.domain == NSOSStatusErrorDomain, [-34, -54, -61, -44, -45, -46].contains(e.code) { return .local }
        if let under = e.userInfo[NSUnderlyingErrorKey] as? Error, kind(of: under) == .local { return .local }
        return .content
    }

    static let recordingBackoff: [TimeInterval] = [300, 900, 3600, 3 * 3600, 6 * 3600]
    /// A phone recording is tried for this long after its first failure that was not this Mac's or the network's.
    static let recordingGiveUp: TimeInterval = 7 * 86_400
    /// After this long the owner is told that a recording has not arrived.
    static let recordingTellAfter: TimeInterval = 86_400

    struct MissingAsset: Error, CustomStringConvertible {
        var name: String
        var description: String { "\(name) came without its data" }
    }

    private func scratch() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mossad-sync-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func file(_ data: Data, _ name: String, in dir: URL) throws -> URL {
        let url = dir.appendingPathComponent(name)
        try data.write(to: url)
        return url
    }

    // MARK: Mac

    /// Uploads new and changed meetings, deletes removed ones, and returns how many changed.
    /// A meeting is deleted in the store only when its folder is gone here (a delete or a merge). One that is
    /// being processed again, or whose record cannot be read, stays; a folder list that fails stops the push.
    @discardableResult
    public func push() async throws -> Int {
        try await prepare()
        let withView = store.wantsMeetingView
        let scan = try ProcessingQueue(paths: paths).scan()
        let payloads = scan.records.filter(SyncPayload.isSyncable).map {
            SyncPayload(record: $0, coach: CoachReview.load(in: paths.callDirectory($0.id)), view: withView)
        }
        let plan = try loadState().plan(payloads, present: scan.folders)
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }

        var changed = 0
        for chunk in stride(from: 0, to: plan.upload.count, by: Self.batch).map({ Array(plan.upload[$0..<min($0 + Self.batch, plan.upload.count)]) }) {
            let records = try chunk.map { try meetingRecord($0, in: dir) }
            let saved = try await store.save(records)
            try update { state in
                for p in chunk where saved.contains(p.id) { state.uploaded[p.id] = p.hash }
            }
            changed += chunk.filter { saved.contains($0.id) }.count
        }
        if !plan.delete.isEmpty {
            let gone = try await store.delete(plan.delete)
            try update { state in
                for id in gone { state.uploaded[id] = nil }
            }
            changed += gone.count
        }
        return changed
    }

    private func meetingRecord(_ p: SyncPayload, in dir: URL) throws -> StoredRecord {
        var fields: [String: StoredValue] = [
            "title": .string(p.fields.title), "start": .date(p.fields.start), "end": .date(p.fields.end),
            "platform": .string(p.fields.platform), "tags": .strings(p.fields.tags), "status": .string(p.fields.status),
        ]
        if let h = p.fields.headline { fields["headline"] = .string(h) }
        if let k = p.fields.kind { fields["kind"] = .string(k) }
        var files = ["record": try file(p.record, "\(p.id)-record.json", in: dir)]
        if let coach = p.coach { files["coach"] = try file(coach, "\(p.id)-coach.json", in: dir) }
        if let view = p.view { files["view"] = try file(view, "\(p.id)-view.json", in: dir) }
        return StoredRecord(name: p.id, type: Self.meetingType, fields: fields, files: files)
    }

    // MARK: Both devices

    /// Uploads chats, the owner's notes on reviews, and the coach's memory when they changed here, and deletes
    /// the chats that were deleted here. A chat that is only missing (its file does not decode) is never deleted.
    @discardableResult
    public func pushShared() async throws -> Int {
        try await prepare()
        let chats = ChatStore(directory: paths.chats)
        var payloads = chats.all().map(SharedPayload.chat)
        for r in ProcessingQueue(paths: paths).allRecords() {
            if let review = CoachReview.load(in: paths.callDirectory(r.id)), let notes = SharedPayload.notes(callID: r.id, review: review) {
                payloads.append(notes)
            }
        }
        // A file that was set aside is empty here until a pull merged the store's copy: sending it now would
        // replace the good copy on the other device.
        let waiting = Self.syncedFiles(paths).map(StoredFile.awaitsMerge)
        if !waiting[0], FileManager.default.fileExists(atPath: paths.coach.appendingPathComponent(CoachProfile.fileName).path),
           let profile = try? CoachProfile.load(from: paths.coach) {
            payloads.append(.profile(profile))
        }
        if !waiting[1], FileManager.default.fileExists(atPath: paths.commitments.appendingPathComponent(CommitmentBook.fileName).path),
           let book = try? CommitmentBook.load(from: paths.commitments) {
            payloads.append(.commitments(book))
        }
        let deleted = chats.deleted()
        let plan = try loadState().planShared(payloads, deletedChats: deleted)
        guard !plan.upload.isEmpty || !plan.delete.isEmpty else { return 0 }
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        var changed = 0
        for chunk in stride(from: 0, to: plan.upload.count, by: Self.batch).map({ Array(plan.upload[$0..<min($0 + Self.batch, plan.upload.count)]) }) {
            let records = try chunk.map { p -> StoredRecord in
                let type = switch p.kind {
                case .chat: Self.chatType
                case .notes: Self.notesType
                case .profile: Self.profileType
                case .commitments: Self.commitmentsType
                }
                let name = Self.recordName(p.key)
                return StoredRecord(name: name, type: type, files: ["data": try file(p.data, "\(name).json", in: dir)])
            }
            let saved = try await store.save(records)
            let done = chunk.filter { saved.contains(Self.recordName($0.key)) }
            try update { state in
                for p in done { state.uploaded[p.key] = p.hash }
            }
            changed += done.count
        }
        if !plan.delete.isEmpty {
            let gone = try await store.delete(plan.delete.map(Self.recordName))
            let done = plan.delete.filter { gone.contains(Self.recordName($0)) }
            try update { state in
                for key in done { state.uploaded[key] = nil }
            }
            // The store has the delete now; the note of it can go.
            let ids = Set(done.compactMap { UUID(uuidString: String($0.dropFirst("chat:".count))) })
            chats.setDeleted(chats.deleted().subtracting(ids))
            changed += done.count
        }
        return changed
    }

    /// "chat:<uuid>" becomes "chat-<uuid>"; the profile keeps its own name.
    static func recordName(_ key: String) -> String {
        key == "profile" ? profileName : key.replacingOccurrences(of: ":", with: "-")
    }

    // MARK: Phone

    /// Sends a room recording to the Mac. Returns once the store has it, so the phone can keep its copy until then.
    public func upload(_ p: PhoneRecording, audio: URL) async throws {
        try await prepare()
        var fields: [String: StoredValue] = ["start": .date(p.start), "end": .date(p.end)]
        if let t = p.title { fields["title"] = .string(t) }
        let name = PhoneRecording.recordName(p.id)
        let saved = try await store.save([StoredRecord(name: name, type: Self.recordingType, fields: fields, files: ["audio": audio])])
        guard saved.contains(name) else { throw ServerError.http(0, "The recording did not upload.") }
    }

    /// Fetches what changed since the last pull into the local folders, and returns how many records changed.
    /// The Mac leaves out meetings: it wrote them, and the copies in the store are trimmed.
    ///
    /// The change token moves only past a page whose records all arrived. A record that could not be read stops the
    /// token, so the next pull gets the page again; what did arrive is applied a second time without harm. The pull
    /// then throws, so the failure shows. A phone recording that fails does not stop the token: it goes on a list
    /// and is tried again by name (see `PendingRecording`), so one bad recording cannot hold back every other change.
    @discardableResult
    public func pull(includeMeetings: Bool = true) async throws -> Int {
        var token = try loadState().changeToken
        // A profile or a commitment book that was set aside starts empty here. Read the whole store once, so the
        // other device's copy is merged in before this device sends anything of its own.
        let recovering = Self.syncedFiles(paths).filter(StoredFile.awaitsMerge)
        if !recovering.isEmpty { token = nil }
        var changed = 0
        var imported: [String] = []
        defer {
            // An imported recording lives on the Mac now; remove the copy in the store.
            if !imported.isEmpty {
                let names = imported, store = store
                Task { await store.discard(names) }
            }
        }
        if !includeMeetings { changed += try await retryRecordings(&imported) }
        while true {
            let changes = try await store.changes(since: token)
            let before = try loadState().failures ?? [:]
            var failures = before
            var blocked: Error?
            func failed(_ name: String, _ error: Error) {
                switch Self.kind(of: error) {
                case .passes, .local:
                    Log.error("Sync could not get \(name); it is tried again on the next sync: \(error)")
                    blocked = blocked ?? error
                case .content where (failures[name] ?? 0) + 1 < Self.maxRecordFailures:
                    failures[name, default: 0] += 1
                    Log.error("Sync could not take \(name) (try \(failures[name] ?? 1) of \(Self.maxRecordFailures)): \(error)")
                    blocked = blocked ?? error
                case .content:
                    failures[name] = nil
                    Log.error("Sync gave up on \(name) after \(Self.maxRecordFailures) tries; it stays in the store: \(error)")
                }
            }
            for record in changes.modified {
                guard Self.isSafeName(record.name) else {
                    Log.error("Sync left out a record with a name that cannot be a file name")
                    continue
                }
                if record.type == Self.recordingType {
                    // Only the Mac processes recordings.
                    guard !includeMeetings else { continue }
                    // Sent again by the phone: a recording Mossad stopped trying starts fresh.
                    try update { $0.recordings?.removeAll { $0.name == record.name && $0.gaveUp == true } }
                    do {
                        try await importRecording(record)
                        imported.append(record.name)
                        changed += 1
                        try update { $0.recordings?.removeAll { $0.name == record.name } }
                    } catch {
                        try keep(record, after: error)
                    }
                    continue
                }
                do {
                    if try await store(record, includeMeetings: includeMeetings) { changed += 1 }
                    failures[record.name] = nil
                } catch {
                    failed(record.name, error)
                }
            }
            for f in changes.failed where Self.isSafeName(f.name) { failed(f.name, f.error) }
            var chatsGone: [String] = []
            var recordingsGone: [String] = []
            for deletion in changes.deleted where Self.isSafeName(deletion.name) {
                switch deletion.type {
                case Self.meetingType where includeMeetings:
                    try? FileManager.default.removeItem(at: paths.callDirectory(deletion.name))
                case Self.chatType:
                    if let id = UUID(uuidString: String(deletion.name.dropFirst("chat-".count))) {
                        // Deleted on the other device: not a delete made here, so nothing to send back.
                        ChatStore(directory: paths.chats).delete(id, record: false)
                        chatsGone.append("chat:\(id.uuidString)")
                    }
                case Self.recordingType:
                    // The phone took it back, or this Mac imported it: nothing left to wait for.
                    recordingsGone.append(deletion.name)
                    continue
                default: continue
                }
                changed += 1
            }
            let stop = blocked != nil
            try update { state in
                for key in chatsGone { state.uploaded[key] = nil }
                state.recordings?.removeAll { recordingsGone.contains($0.name) }
                state.failures = failures.isEmpty ? nil : failures
                if !stop { state.changeToken = changes.token }
            }
            if let blocked { throw blocked }
            token = changes.token
            if !changes.more {
                // The whole store was read: whatever copy it has of a recovered file is merged in now.
                for url in recovering { StoredFile.merged(url) }
                return changed
            }
        }
    }

    /// The files that both devices write, and that must take the other device's copy first after a recovery.
    static func syncedFiles(_ paths: Paths) -> [URL] {
        [paths.coach.appendingPathComponent(CoachProfile.fileName), paths.commitments.appendingPathComponent(CommitmentBook.fileName)]
    }

    /// No store is connected, so there is no other copy to wait for: a recovered file is what there is.
    public static func nothingToMerge(paths: Paths) {
        for url in syncedFiles(paths) { StoredFile.merged(url) }
    }

    // MARK: Phone recordings that did not import

    /// Puts a recording that failed on the list, or updates it. The list is tried again with a growing pause.
    /// The 7 days count only from a failure that is about the recording; a full disk or no network never ends it.
    private func keep(_ record: ChangedRecord, after error: Error) throws {
        let time = now(), kind = Self.kind(of: error)
        try update { state in
            var list = state.recordings ?? []
            var p = list.first { $0.name == record.name }
                ?? PendingRecording(name: record.name, start: record.fields["start"]?.date, end: record.fields["end"]?.date,
                                    title: record.fields["title"]?.string, firstFailure: time, attempts: 0, next: time, reason: "")
            p.attempts += 1
            p.reason = String(String(describing: error).prefix(300))
            p.next = time.addingTimeInterval(Self.recordingBackoff[min(p.attempts, Self.recordingBackoff.count) - 1])
            if kind == .content {
                p.countedSince = p.countedSince ?? time
                if time.timeIntervalSince(p.countedSince ?? time) >= Self.recordingGiveUp { p.gaveUp = true }
            }
            list.removeAll { $0.name == record.name }
            list.append(p)
            state.recordings = list
            if p.gaveUp == true {
                Log.error("The iPhone recording \(record.name) could not be imported for 7 days; Mossad stops trying. It stays in the store and on the iPhone: \(error)")
            } else {
                Log.error("Importing the iPhone recording \(record.name) failed (try \(p.attempts)); the next try is at \(p.next.formatted(date: .omitted, time: .shortened)): \(error)")
            }
        }
    }

    /// Tries the recordings on the list whose pause is over. Returns how many were imported.
    private func retryRecordings(_ imported: inout [String]) async throws -> Int {
        let due = (try loadState().recordings ?? []).filter { $0.gaveUp != true && $0.next <= now() }
        var done = 0
        for p in due {
            let known = ChangedRecord(name: p.name, type: Self.recordingType, fields: p.fields, assetKeys: ["audio"])
            do {
                guard let record = try await store.refetch(known) else {
                    try update { $0.recordings?.removeAll { $0.name == p.name } }
                    continue
                }
                try await importRecording(record)
                imported.append(p.name)
                done += 1
                try update { $0.recordings?.removeAll { $0.name == p.name } }
            } catch {
                try keep(known, after: error)
            }
        }
        return done
    }

    /// The recordings the owner must hear about now, each one time: one that has not arrived for a day, and one
    /// that Mossad stopped trying.
    public func recordingNotices() throws -> [PendingRecording] {
        let time = now()
        var out: [PendingRecording] = []
        try update { state in
            for i in (state.recordings ?? []).indices {
                let p = state.recordings![i]
                if p.gaveUp == true, p.toldGaveUp != true {
                    state.recordings![i].toldGaveUp = true
                    state.recordings![i].told = true
                    out.append(p)
                } else if p.gaveUp != true, p.told != true, time.timeIntervalSince(p.firstFailure) >= Self.recordingTellAfter {
                    state.recordings![i].told = true
                    out.append(p)
                }
            }
        }
        return out
    }

    /// Turns a phone recording into a call. Returns once the call exists here, including from an earlier pull;
    /// throws when it could not be made, so the store keeps its copy and a later pull tries again.
    private func importRecording(_ record: ChangedRecord) async throws {
        var id = String(record.name.dropFirst("rec-".count))
        guard !id.isEmpty, !id.hasPrefix("."), let start = record.fields["start"]?.date, let end = record.fields["end"]?.date else {
            throw MissingAsset(name: record.name)
        }
        func exists(_ id: String) -> Bool {
            FileManager.default.fileExists(atPath: paths.callDirectory(id).appendingPathComponent(CallRecord.fileName).path)
        }
        if exists(id) {
            // Call IDs are start times on both devices. A Mac call that began in the same second is another
            // meeting; the recording then gets its own ID instead of being taken as imported.
            guard let mine = try? CallRecord.load(from: paths.callDirectory(id)), mine.bundleID != PhoneRecording.bundleID else { return }
            id += "-iphone"
            if exists(id) { return }
        }
        guard let data = try await store.data(record, "audio") else { throw MissingAsset(name: record.name) }
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let audio = try file(data, "\(id).m4a", in: dir)
        try PhoneRecording.importAudio(audio, recording: PhoneRecording(id: id, start: start, end: end, title: record.fields["title"]?.string), into: paths)
        Log.info("Imported the iPhone recording \(id)")
    }

    /// Returns whether the record changed something here. Throws when its data could not be fetched or read.
    private func store(_ record: ChangedRecord, includeMeetings: Bool) async throws -> Bool {
        func data(_ key: String) async throws -> Data? { try await store.data(record, key) }
        func decoded<T: Decodable>(_ type: T.Type) async throws -> T {
            guard let raw = try await data("data") else { throw MissingAsset(name: record.name) }
            return try JSONDecoder.callRecord.decode(T.self, from: raw)
        }
        switch record.type {
        case Self.meetingType where includeMeetings:
            let dir = paths.callDirectory(record.name)
            let call = try await data("record"), coach = try await data("coach")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            if let call { try call.write(to: dir.appendingPathComponent("call.json"), options: .atomic) }
            if let coach {
                var remote = try JSONDecoder.callRecord.decode(CoachReview.self, from: coach)
                // Ratings or replies made here and not yet merged by the Mac stay.
                if let local = CoachReview.load(in: dir) { remote = remote.mergingNotes(from: local) }
                try remote.save(in: dir)
            }
        case Self.profileType:
            let remote = try await decoded(CoachProfile.self)
            // Throws when the file here cannot be read: it is moved aside first, never merged over as if empty.
            let local = try CoachProfile.load(from: paths.coach)
            // The Mac's coach writes the coaching fields; the phone takes them, the Mac keeps its own.
            // After a recovery the profile here is empty, so the Mac takes its own coaching fields back too.
            let merged = local.merged(with: remote, takeCoaching: includeMeetings || StoredFile.awaitsMerge(Self.syncedFiles(paths)[0]))
            guard merged != local else { return false }
            try merged.save(to: paths.coach)
            // The answers to the cards that came from the other device are kept with their calls too.
            if merged.answers != local.answers { FindingStore.mirror(merged.answers, paths: paths) }
        case Self.chatType:
            let remote = try await decoded(Chat.self)
            let chats = ChatStore(directory: paths.chats)
            // A chat deleted here stays deleted; the next push deletes it in the store.
            guard !chats.deleted().contains(remote.id) else { return false }
            let local = try chats.load(remote.id)
            let kept = local.map { Chat.merged($0, remote) } ?? remote
            guard kept != local else { return false }
            try chats.save(kept)
        case Self.commitmentsType:
            let remote = try await decoded(CommitmentBook.self)
            let local = try CommitmentBook.load(from: paths.commitments)
            let merged = local.merged(with: remote)
            guard merged != local else { return false }
            try merged.save(to: paths.commitments)
        case Self.notesType:
            let notes = try await decoded(ReviewNotes.self)
            let dir = paths.callDirectory(String(record.name.dropFirst("notes-".count)))
            guard let review = CoachReview.load(in: dir) else { return false }
            var incoming = review
            incoming.feedback = notes.feedback
            incoming.thread = notes.thread
            let merged = review.mergingNotes(from: incoming)
            guard merged != review else { return false }
            try merged.save(in: dir)
        default:
            return false
        }
        return true
    }
}
