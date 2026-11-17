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

    /// Deletes a deleted profile's zone. A zone that is not there is a success.
    public static func deleteZone(named name: String) async throws {
        guard mayDelete(zone: name) else { throw ZoneRefused() }
        do {
            _ = try await CKContainer(identifier: containerID).privateCloudDatabase.modifyRecordZones(saving: [], deleting: [zoneID(named: name)])
        } catch let error as CKError where error.code == .zoneNotFound {
            return
        }
    }
}
