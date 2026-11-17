import CloudKit
import Foundation

/// The zones of the profiles. Kept apart from the store's own file, which only takes its zone as a value.
extension CloudKitStore {
    static func zoneID(named name: String) -> CKRecordZone.ID {
        CKRecordZone.ID(zoneName: name, ownerName: CKCurrentUserDefaultName)
    }

    /// Only another profile's zone may be deleted: `Mossad-` and 8 characters of 0-9a-f. Never `Mossad`.
    public static func mayDelete(zone: String) -> Bool {
        zone.hasPrefix("Mossad-") && ProfileRegistry.isID(String(zone.dropFirst("Mossad-".count)))
    }

    public struct ZoneRefused: Error {}

    public enum ZoneDeletion: Equatable, Sendable { case deleted, tryAgain }
    public struct ZoneNotDeleted: Error {}

    /// iCloud's answer for the one zone: a success, or a zone that is not there, is deleted; anything else, or no
    /// answer, is tried again at the next launch.
    public static func zoneDeletion(_ result: Result<Void, any Error>?) -> ZoneDeletion {
        switch result {
        case .success: .deleted
        case .failure(let error as CKError) where error.code == .zoneNotFound: .deleted
        default: .tryAgain
        }
    }

    /// Deletes a deleted profile's zone. A zone that is not there is a success.
    public static func deleteZone(named name: String) async throws {
        guard mayDelete(zone: name) else { throw ZoneRefused() }
        let id = zoneID(named: name)
        let result: Result<Void, any Error>?
        do {
            let (_, deleted) = try await CKContainer(identifier: containerID).privateCloudDatabase.modifyRecordZones(saving: [], deleting: [id])
            result = deleted[id]
        } catch {
            result = .failure(error)
        }
        guard zoneDeletion(result) == .deleted else { throw ZoneNotDeleted() }
    }
}
