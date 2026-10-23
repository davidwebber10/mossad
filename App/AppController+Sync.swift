import Foundation
import MossadCore
import Security

extension AppController {
    /// Whether this build may use iCloud: CloudKit stops the app when the entitlement is missing.
    static let hasICloud: Bool = {
        guard let task = SecTaskCreateFromSelf(nil),
              let value = SecTaskCopyValueForEntitlement(task, "com.apple.developer.icloud-services" as CFString, nil) else { return false }
        return (value as? [String])?.contains("CloudKit") == true
    }()

    /// Uploads new and changed meetings for the iPhone app. One push at a time; a push asked for during one
    /// runs again after it.
    func syncToICloud() {
        guard Self.hasICloud, iCloudSyncEnabled else { return }
        if iCloudSyncing { iCloudSyncAgain = true; return }
        iCloudSyncing = true
        let cloud = cloudSync
        Task.detached(priority: .utility) {
            var received = 0
            do {
                let changed = try await cloud.push()
                received = try await cloud.pull(includeMeetings: false)
                let shared = try await cloud.pushShared()
                if changed + shared > 0 { Log.info("iCloud: \(changed + shared) changes uploaded") }
                if received > 0 { Log.info("iCloud: \(received) changes from your other devices") }
            } catch {
                Log.error("iCloud sync failed: \(error)")
            }
            await MainActor.run {
                // Chats, ratings, and memories from the phone show here at once.
                if received > 0 { self.coachVersion += 1; self.chatsVersion += 1 }
                self.iCloudSyncing = false
                if self.iCloudSyncAgain {
                    self.iCloudSyncAgain = false
                    self.syncToICloud()
                }
            }
        }
    }
}
