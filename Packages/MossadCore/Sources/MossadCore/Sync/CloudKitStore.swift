import CloudKit
import Foundation

/// The records in the private iCloud database, in one zone.
public actor CloudKitStore: RecordStore {
    public static let containerID = "iCloud.com.dwebber.mossad"
    static let zone = CKRecordZone.ID(zoneName: "Mossad", ownerName: CKCurrentUserDefaultName)

    private let database: CKDatabase
    private var zoneReady = false

    public init() {
        database = CKContainer(identifier: Self.containerID).privateCloudDatabase
    }

    static func id(_ name: String) -> CKRecord.ID { CKRecord.ID(recordName: name, zoneID: zone) }

    public func prepare() async throws {
        guard !zoneReady else { return }
        _ = try await database.modifyRecordZones(saving: [CKRecordZone(zoneID: Self.zone)], deleting: [])
        zoneReady = true
    }

    public func save(_ records: [StoredRecord]) async throws -> Set<String> {
        let ck = records.map { r -> CKRecord in
            let record = CKRecord(recordType: r.type, recordID: Self.id(r.name))
            for (key, value) in r.fields {
                switch value {
                case .string(let s): record[key] = s
                case .date(let d): record[key] = d
                // CloudKit cannot learn a field's type from an empty list.
                case .strings(let list): record[key] = list.isEmpty ? nil : list
                }
            }
            for (key, url) in r.files { record[key] = CKAsset(fileURL: url) }
            return record
        }
        let (saved, _) = try await database.modifyRecords(saving: ck, deleting: [], savePolicy: .allKeys, atomically: false)
        var names = Set<String>()
        for (id, result) in saved {
            switch result {
            case .success: names.insert(id.recordName)
            case .failure(let error): Log.error("iCloud upload of \(id.recordName) failed: \(error)")
            }
        }
        return names
    }

    public func delete(_ names: [String]) async throws -> Set<String> {
        guard !names.isEmpty else { return [] }
        let (_, deleted) = try await database.modifyRecords(saving: [], deleting: names.map(Self.id), savePolicy: .allKeys, atomically: false)
        var gone = Set<String>()
        for (id, result) in deleted {
            // Already gone counts as deleted.
            if case .failure(let error) = result, (error as? CKError)?.code != .unknownItem { continue }
            gone.insert(id.recordName)
        }
        return gone
    }

    public func changes(since token: Data?) async throws -> StoreChanges {
        var ck = token.flatMap { try? NSKeyedUnarchiver.unarchivedObject(ofClass: CKServerChangeToken.self, from: $0) }
        while true {
            do {
                let changes = try await database.recordZoneChanges(inZoneWith: Self.zone, since: ck)
                var failed: [(name: String, error: any Error)] = []
                let modified = changes.modificationResultsByID.compactMap { id, result -> ChangedRecord? in
                    switch result {
                    case .success(let m): return Self.changed(m.record)
                    case .failure(let error):
                        Log.error("iCloud could not send \(id.recordName): \(error)")
                        failed.append((id.recordName, error))
                        return nil
                    }
                }
                let deleted = changes.deletions.map { (name: $0.recordID.recordName, type: $0.recordType) }
                let next = try NSKeyedArchiver.archivedData(withRootObject: changes.changeToken, requiringSecureCoding: true)
                return StoreChanges(modified: modified, deleted: deleted, token: next, more: changes.moreComing, failed: failed)
            } catch let error as CKError where error.code == .zoneNotFound {
                // Nothing uploaded yet.
                return StoreChanges(modified: [], deleted: [], token: token, more: false)
            } catch let error as CKError where error.code == .changeTokenExpired {
                ck = nil
            }
        }
    }

    static func changed(_ record: CKRecord) -> ChangedRecord {
        var fields: [String: StoredValue] = [:]
        var files: [String: URL] = [:]
        for key in record.allKeys() {
            switch record[key] {
            case let s as String: fields[key] = .string(s)
            case let d as Date: fields[key] = .date(d)
            case let list as [String]: fields[key] = .strings(list)
            case let asset as CKAsset: if let url = asset.fileURL { files[key] = url }
            default: continue
            }
        }
        return ChangedRecord(name: record.recordID.recordName, type: record.recordType, fields: fields,
                             assetKeys: Array(files.keys), localFiles: files)
    }

    /// The assets that came with a change are temporary files; a later try reads the record again.
    public func refetch(_ record: ChangedRecord) async throws -> ChangedRecord? {
        do { return Self.changed(try await database.record(for: Self.id(record.name))) }
        catch let error as CKError where error.code == .unknownItem { return nil }
    }

    public func data(_ record: ChangedRecord, _ key: String) async throws -> Data? {
        // An asset that came with the change and cannot be read is a failure, not a record without data.
        try record.localFiles[key].map { try Data(contentsOf: $0) }
    }

    public func discard(_ names: [String]) async {
        _ = try? await database.modifyRecords(saving: [], deleting: names.map(Self.id), savePolicy: .allKeys, atomically: false)
    }
}
