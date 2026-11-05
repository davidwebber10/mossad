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
    private var prepared = false

    public init(paths: Paths, store: any RecordStore) {
        self.paths = paths
        self.store = store
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
    private func saveState(_ s: SyncState) throws { try s.save(to: paths.sync, fileName: store.stateFileName) }

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
    @discardableResult
    public func push() async throws -> Int {
        try await prepare()
        var state = try loadState()
        let withView = store.wantsMeetingView
        let payloads = ProcessingQueue(paths: paths).allRecords().filter(SyncPayload.isSyncable).map {
            SyncPayload(record: $0, coach: CoachReview.load(in: paths.callDirectory($0.id)), view: withView)
        }
        let plan = state.plan(payloads)
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }

        var changed = 0
        for chunk in stride(from: 0, to: plan.upload.count, by: Self.batch).map({ Array(plan.upload[$0..<min($0 + Self.batch, plan.upload.count)]) }) {
            let records = try chunk.map { try meetingRecord($0, in: dir) }
            let saved = try await store.save(records)
            for p in chunk where saved.contains(p.id) {
                state.uploaded[p.id] = p.hash
                changed += 1
            }
            try saveState(state)
        }
        if !plan.delete.isEmpty {
            let gone = try await store.delete(plan.delete)
            for id in gone { state.uploaded[id] = nil; changed += 1 }
            try saveState(state)
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
    /// chats deleted here.
    @discardableResult
    public func pushShared() async throws -> Int {
        try await prepare()
        var state = try loadState()
        var payloads = ChatStore(directory: paths.chats).all().map(SharedPayload.chat)
        for r in ProcessingQueue(paths: paths).allRecords() {
            if let review = CoachReview.load(in: paths.callDirectory(r.id)), let notes = SharedPayload.notes(callID: r.id, review: review) {
                payloads.append(notes)
            }
        }
        if FileManager.default.fileExists(atPath: paths.coach.appendingPathComponent(CoachProfile.fileName).path),
           let profile = try? CoachProfile.load(from: paths.coach) {
            payloads.append(.profile(profile))
        }
        if FileManager.default.fileExists(atPath: paths.commitments.appendingPathComponent(CommitmentBook.fileName).path),
           let book = try? CommitmentBook.load(from: paths.commitments) {
            payloads.append(.commitments(book))
        }
        let plan = state.planShared(payloads)
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
            for p in chunk where saved.contains(Self.recordName(p.key)) {
                state.uploaded[p.key] = p.hash
                changed += 1
            }
        }
        if !plan.delete.isEmpty {
            let gone = try await store.delete(plan.delete.map(Self.recordName))
            for key in plan.delete where gone.contains(Self.recordName(key)) { state.uploaded[key] = nil; changed += 1 }
        }
        try saveState(state)
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
    @discardableResult
    public func pull(includeMeetings: Bool = true) async throws -> Int {
        var state = try loadState()
        var changed = 0
        var imported: [String] = []
        defer {
            // An imported recording lives on the Mac now; remove the copy in the store.
            if !imported.isEmpty {
                let names = imported, store = store
                Task { await store.discard(names) }
            }
        }
        while true {
            let changes = try await store.changes(since: state.changeToken)
            for record in changes.modified {
                if record.type == Self.recordingType {
                    // Only the Mac processes recordings.
                    if !includeMeetings, await importRecording(record) { imported.append(record.name); changed += 1 }
                    continue
                }
                if try await store(record, includeMeetings: includeMeetings) { changed += 1 }
            }
            for deletion in changes.deleted {
                switch deletion.type {
                case Self.meetingType where includeMeetings:
                    try? FileManager.default.removeItem(at: paths.callDirectory(deletion.name))
                case Self.chatType:
                    if let id = UUID(uuidString: String(deletion.name.dropFirst("chat-".count))) {
                        ChatStore(directory: paths.chats).delete(id)
                        state.uploaded["chat:\(id.uuidString)"] = nil
                    }
                default: continue
                }
                changed += 1
            }
            state.changeToken = changes.token
            try saveState(state)
            if !changes.more { return changed }
        }
    }

    /// Turns a phone recording into a call. True once the call exists here, including from an earlier pull.
    private func importRecording(_ record: ChangedRecord) async -> Bool {
        let id = String(record.name.dropFirst("rec-".count))
        if FileManager.default.fileExists(atPath: paths.callDirectory(id).appendingPathComponent(CallRecord.fileName).path) { return true }
        guard let start = record.fields["start"]?.date, let end = record.fields["end"]?.date,
              let data = try? await store.data(record, "audio") else { return false }
        do {
            let dir = try scratch()
            defer { try? FileManager.default.removeItem(at: dir) }
            let audio = try file(data, "\(id).m4a", in: dir)
            try PhoneRecording.importAudio(audio, recording: PhoneRecording(id: id, start: start, end: end, title: record.fields["title"]?.string), into: paths)
            Log.info("Imported the iPhone recording \(id)")
            return true
        } catch {
            Log.error("Importing the iPhone recording \(id) failed: \(error)")
            return false
        }
    }

    /// Returns whether the record changed something here.
    private func store(_ record: ChangedRecord, includeMeetings: Bool) async throws -> Bool {
        func data(_ key: String) async -> Data? { try? await store.data(record, key) }
        switch record.type {
        case Self.meetingType where includeMeetings:
            let dir = paths.callDirectory(record.name)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            if let call = await data("record") { try call.write(to: dir.appendingPathComponent("call.json"), options: .atomic) }
            if let coach = await data("coach"), var remote = try? JSONDecoder.callRecord.decode(CoachReview.self, from: coach) {
                // Ratings or replies made here and not yet merged by the Mac stay.
                if let local = CoachReview.load(in: dir) { remote = remote.mergingNotes(from: local) }
                try remote.save(in: dir)
            }
        case Self.profileType:
            guard let raw = await data("data"), let remote = try? JSONDecoder.callRecord.decode(CoachProfile.self, from: raw) else { return false }
            let local = (try? CoachProfile.load(from: paths.coach)) ?? CoachProfile()
            // The Mac's coach writes the coaching fields; the phone takes them, the Mac keeps its own.
            let merged = local.merged(with: remote, takeCoaching: includeMeetings)
            guard merged != local else { return false }
            try merged.save(to: paths.coach)
        case Self.chatType:
            guard let raw = await data("data"), let remote = try? JSONDecoder.callRecord.decode(Chat.self, from: raw) else { return false }
            let chats = ChatStore(directory: paths.chats)
            let local = chats.all().first { $0.id == remote.id }
            let kept = local.map { Chat.newer($0, remote) } ?? remote
            guard kept != local else { return false }
            try chats.save(kept)
        case Self.commitmentsType:
            guard let raw = await data("data"), let remote = try? JSONDecoder.callRecord.decode(CommitmentBook.self, from: raw) else { return false }
            let local = (try? CommitmentBook.load(from: paths.commitments)) ?? CommitmentBook()
            let merged = local.merged(with: remote)
            guard merged != local else { return false }
            try merged.save(to: paths.commitments)
        case Self.notesType:
            guard let raw = await data("data"), let notes = try? JSONDecoder.callRecord.decode(ReviewNotes.self, from: raw) else { return false }
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
