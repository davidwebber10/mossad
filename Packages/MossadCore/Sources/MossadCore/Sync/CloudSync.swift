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
        changed += try await pushProfile(state: &state, scratch: scratch)
        try state.save(to: paths.sync)
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

    private func pushProfile(state: inout SyncState, scratch: URL) async throws -> Int {
        let url = paths.coach.appendingPathComponent(CoachProfile.fileName)
        guard let data = try? Data(contentsOf: url) else { return 0 }
        let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard state.uploaded[Self.profileName] != hash else { return 0 }
        let record = CKRecord(recordType: Self.profileType, recordID: CKRecord.ID(recordName: Self.profileName, zoneID: Self.zone))
        record["profile"] = try asset(data, "profile.json", scratch)
        _ = try await database.modifyRecords(saving: [record], deleting: [], savePolicy: .allKeys, atomically: false)
        state.uploaded[Self.profileName] = hash
        return 1
    }

    private func asset(_ data: Data, _ name: String, _ scratch: URL) throws -> CKAsset {
        let url = scratch.appendingPathComponent(name)
        try data.write(to: url)
        return CKAsset(fileURL: url)
    }

    // MARK: Phone

    /// Fetches what changed since the last pull into the local folders, and returns how many meetings changed.
    @discardableResult
    public func pull() async throws -> Int {
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
                try store(modification.record, id: id.recordName)
                changed += 1
            }
            for deletion in changes.deletions where deletion.recordType == Self.meetingType {
                try? FileManager.default.removeItem(at: paths.callDirectory(deletion.recordID.recordName))
                changed += 1
            }
            token = changes.changeToken
            state.changeToken = try NSKeyedArchiver.archivedData(withRootObject: changes.changeToken, requiringSecureCoding: true)
            try state.save(to: paths.sync)
            if !changes.moreComing { return changed }
        }
    }

    private func store(_ record: CKRecord, id: String) throws {
        func copy(_ key: String, to url: URL) throws {
            guard let source = (record[key] as? CKAsset)?.fileURL else {
                try? FileManager.default.removeItem(at: url)
                return
            }
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? FileManager.default.removeItem(at: url)
            try FileManager.default.copyItem(at: source, to: url)
        }
        switch record.recordType {
        case Self.meetingType:
            let dir = paths.callDirectory(id)
            try copy("record", to: dir.appendingPathComponent("call.json"))
            try copy("coach", to: dir.appendingPathComponent(CoachReview.fileName))
        case Self.profileType:
            try copy("profile", to: paths.coach.appendingPathComponent(CoachProfile.fileName))
        default:
            break
        }
    }
}
