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

    /// Puts the chosen AI provider, model, and key in iCloud Keychain for the iPhone, or removes them.
    func updateSharedAIKey() {
        guard Self.hasICloud else { return }
        guard shareAIKey, let key = keychain.get(aiProvider.key) else {
            SharedAIKey.delete()
            return
        }
        let shared = SharedAIKey(provider: aiProvider.rawValue, model: aiModel.isEmpty ? aiProvider.defaultModel : aiModel, key: key)
        guard SharedAIKey.load() != shared else { return }
        do { try shared.save() } catch { Log.error("Sharing the AI key with the iPhone failed: \(error)") }
    }

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
                if received > 0 {
                    self.coachVersion += 1; self.chatsVersion += 1; self.commitmentsVersion += 1
                    // A room recording from the iPhone is a new call to process.
                    if self.processing == 0 { self.processPending() }
                }
                self.iCloudSyncing = false
                if self.iCloudSyncAgain {
                    self.iCloudSyncAgain = false
                    self.syncToICloud()
                }
            }
        }
    }
}
