import CloudKit
import CryptoKit
import Foundation

/// Meetings in the private iCloud database. The Mac pushes finished meetings and the coach's memory; the
/// phone pulls them into its own copy of the folder layout, so the same readers work on both.
public actor CloudSync {
    public static let containerID = "iCloud.com.dwebber.mossad"
    static let zone = CKRecordZone.ID(zoneName: "Mossad", ownerName: CKCurrentUserDefaultName)
    static let meetingType = "Meeting"
    static let profileType = "CoachProfile"
    static let profileName = "coach-profile"
    static let chatType = "Chat"
    static let notesType = "CoachNotes"
    /// CloudKit takes up to 400 changes a request; assets make big requests, so stay well under.
    static let batch = 50

    private let database: CKDatabase
    private let paths: Paths
    private var zoneReady = false

    public init(paths: Paths) {
        self.paths = paths
        database = CKContainer(identifier: Self.containerID).privateCloudDatabase
    }

    private func ensureZone() async throws {
        guard !zoneReady else { return }
        _ = try await database.modifyRecordZones(saving: [CKRecordZone(zoneID: Self.zone)], deleting: [])
        zoneReady = true
    }

    // MARK: Mac

    /// Uploads new and changed meetings, deletes removed ones, and returns how many changed.
    @discardableResult
    public func push() async throws -> Int {
        try await ensureZone()
        var state = try SyncState.load(from: paths.sync)
        let payloads = ProcessingQueue(paths: paths).allRecords().filter(SyncPayload.isSyncable).map {
            SyncPayload(record: $0, coach: CoachReview.load(in: paths.callDirectory($0.id)))
        }
        let plan = state.plan(payloads)
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("mossad-sync-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }

        var changed = 0
        for chunk in stride(from: 0, to: plan.upload.count, by: Self.batch).map({ Array(plan.upload[$0..<min($0 + Self.batch, plan.upload.count)]) }) {
            let records = try chunk.map { try meetingRecord($0, scratch: scratch) }
            let (saved, _) = try await database.modifyRecords(saving: records, deleting: [], savePolicy: .allKeys, atomically: false)
            for (id, result) in saved {
                guard case .success = result, let payload = chunk.first(where: { $0.id == id.recordName }) else {
                    if case .failure(let error) = result { Log.error("iCloud upload of \(id.recordName) failed: \(error)") }
                    continue
                }
                state.uploaded[payload.id] = payload.hash
                changed += 1
            }
            try state.save(to: paths.sync)
        }
        if !plan.delete.isEmpty {
            let ids = plan.delete.map { CKRecord.ID(recordName: $0, zoneID: Self.zone) }
            let (_, deleted) = try await database.modifyRecords(saving: [], deleting: ids, savePolicy: .allKeys, atomically: false)
            for (id, result) in deleted {
                // Already gone counts as deleted.
                if case .failure(let error) = result, (error as? CKError)?.code != .unknownItem { continue }
                state.uploaded[id.recordName] = nil
                changed += 1
            }
            try state.save(to: paths.sync)
        }
        return changed
    }

    private func meetingRecord(_ p: SyncPayload, scratch: URL) throws -> CKRecord {
        let record = CKRecord(recordType: Self.meetingType, recordID: CKRecord.ID(recordName: p.id, zoneID: Self.zone))
        record["title"] = p.fields.title
        record["start"] = p.fields.start
        record["end"] = p.fields.end
        record["platform"] = p.fields.platform
        record["headline"] = p.fields.headline
        record["kind"] = p.fields.kind
        // CloudKit cannot learn a field's type from an empty list; the record asset has the tags anyway.
        record["tags"] = p.fields.tags.isEmpty ? nil : p.fields.tags
        record["status"] = p.fields.status
        record["record"] = try asset(p.record, "\(p.id)-record.json", scratch)
        record["coach"] = try p.coach.map { try asset($0, "\(p.id)-coach.json", scratch) }
        return record
    }

    // MARK: Both devices

    /// Uploads chats, the owner's notes on reviews, and the coach's memory when they changed here, and deletes
    /// chats deleted here.
    @discardableResult
    public func pushShared() async throws -> Int {
        try await ensureZone()
        var state = try SyncState.load(from: paths.sync)
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
        let plan = state.planShared(payloads)
        guard !plan.upload.isEmpty || !plan.delete.isEmpty else { return 0 }
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("mossad-sync-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        var changed = 0
        for chunk in stride(from: 0, to: plan.upload.count, by: Self.batch).map({ Array(plan.upload[$0..<min($0 + Self.batch, plan.upload.count)]) }) {
            let records = try chunk.map { p -> CKRecord in
                let type = switch p.kind { case .chat: Self.chatType; case .notes: Self.notesType; case .profile: Self.profileType }
                let record = CKRecord(recordType: type, recordID: Self.recordID(p.key))
                record["data"] = try asset(p.data, "\(p.key.replacingOccurrences(of: ":", with: "-")).json", scratch)
                return record
            }
            let (saved, _) = try await database.modifyRecords(saving: records, deleting: [], savePolicy: .allKeys, atomically: false)
            for (id, result) in saved {
                guard case .success = result, let p = chunk.first(where: { Self.recordID($0.key) == id }) else { continue }
                state.uploaded[p.key] = p.hash
                changed += 1
            }
        }
        if !plan.delete.isEmpty {
            let (_, deleted) = try await database.modifyRecords(saving: [], deleting: plan.delete.map(Self.recordID), savePolicy: .allKeys, atomically: false)
            for (id, result) in deleted {
                if case .failure(let error) = result, (error as? CKError)?.code != .unknownItem { continue }
                if let key = plan.delete.first(where: { Self.recordID($0) == id }) { state.uploaded[key] = nil }
                changed += 1
            }
        }
        try state.save(to: paths.sync)
        return changed
    }

    /// "chat:<uuid>" becomes "chat-<uuid>"; the profile keeps its own name.
    static func recordID(_ key: String) -> CKRecord.ID {
        CKRecord.ID(recordName: key == "profile" ? profileName : key.replacingOccurrences(of: ":", with: "-"), zoneID: zone)
    }

    private func asset(_ data: Data, _ name: String, _ scratch: URL) throws -> CKAsset {
        let url = scratch.appendingPathComponent(name)
        try data.write(to: url)
        return CKAsset(fileURL: url)
    }

    // MARK: Phone

    /// Fetches what changed since the last pull into the local folders, and returns how many records changed.
    /// The Mac leaves out meetings: it wrote them, and the copies in iCloud are trimmed.
    @discardableResult
    public func pull(includeMeetings: Bool = true) async throws -> Int {
        var state = try SyncState.load(from: paths.sync)
        var token = state.changeToken.flatMap { try? NSKeyedUnarchiver.unarchivedObject(ofClass: CKServerChangeToken.self, from: $0) }
        var changed = 0
        while true {
            let changes: (modificationResultsByID: [CKRecord.ID: Result<CKDatabase.RecordZoneChange.Modification, any Error>],
                          deletions: [CKDatabase.RecordZoneChange.Deletion], changeToken: CKServerChangeToken, moreComing: Bool)
            do {
                changes = try await database.recordZoneChanges(inZoneWith: Self.zone, since: token)
            } catch let error as CKError where error.code == .zoneNotFound {
                // The Mac has not uploaded anything yet.
                return 0
            } catch let error as CKError where error.code == .changeTokenExpired {
                token = nil
                continue
            }
            for (id, result) in changes.modificationResultsByID {
                guard case .success(let modification) = result else { continue }
                if try store(modification.record, id: id.recordName, includeMeetings: includeMeetings) { changed += 1 }
            }
            for deletion in changes.deletions {
                switch deletion.recordType {
                case Self.meetingType where includeMeetings:
                    try? FileManager.default.removeItem(at: paths.callDirectory(deletion.recordID.recordName))
                case Self.chatType:
                    if let id = UUID(uuidString: String(deletion.recordID.recordName.dropFirst("chat-".count))) {
                        ChatStore(directory: paths.chats).delete(id)
                        state.uploaded["chat:\(id.uuidString)"] = nil
                    }
                default: continue
                }
                changed += 1
            }
            token = changes.changeToken
            state.changeToken = try NSKeyedArchiver.archivedData(withRootObject: changes.changeToken, requiringSecureCoding: true)
            try state.save(to: paths.sync)
            if !changes.moreComing { return changed }
        }
    }

    /// Returns whether the record changed something here.
    @discardableResult
    private func store(_ record: CKRecord, id: String, includeMeetings: Bool) throws -> Bool {
        func data(_ key: String) -> Data? { (record[key] as? CKAsset)?.fileURL.flatMap { try? Data(contentsOf: $0) } }
        switch record.recordType {
        case Self.meetingType where includeMeetings:
            let dir = paths.callDirectory(id)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            if let call = data("record") { try call.write(to: dir.appendingPathComponent("call.json"), options: .atomic) }
            if let coach = data("coach"), var remote = try? JSONDecoder.callRecord.decode(CoachReview.self, from: coach) {
                // Ratings or replies made here and not yet merged by the Mac stay.
                if let local = CoachReview.load(in: dir) { remote = remote.mergingNotes(from: local) }
                try remote.save(in: dir)
            }
        case Self.profileType:
            guard let raw = data("data") ?? data("profile"), let remote = try? JSONDecoder.callRecord.decode(CoachProfile.self, from: raw) else { return false }
            let local = (try? CoachProfile.load(from: paths.coach)) ?? CoachProfile()
            // The Mac's coach writes the coaching fields; the phone takes them, the Mac keeps its own.
            let merged = local.merged(with: remote, takeCoaching: includeMeetings)
            guard merged != local else { return false }
            try merged.save(to: paths.coach)
        case Self.chatType:
            guard let raw = data("data"), let remote = try? JSONDecoder.callRecord.decode(Chat.self, from: raw) else { return false }
            let store = ChatStore(directory: paths.chats)
            let local = store.all().first { $0.id == remote.id }
            let kept = local.map { Chat.newer($0, remote) } ?? remote
            guard kept != local else { return false }
            try store.save(kept)
        case Self.notesType:
            guard let raw = data("data"), let notes = try? JSONDecoder.callRecord.decode(ReviewNotes.self, from: raw) else { return false }
            let dir = paths.callDirectory(String(id.dropFirst("notes-".count)))
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
