import Foundation
import MossadCore

/// Whether this build may use iCloud: CloudKit stops the app when the entitlement is missing. For the app and for a
/// worker, which is the same signed app.
enum CloudEntitlement {
    static let hasCloudKit: Bool = {
        guard !Rehearsal.isOn, let task = SecTaskCreateFromSelf(nil),
              let value = SecTaskCopyValueForEntitlement(task, "com.apple.developer.icloud-services" as CFString, nil) else { return false }
        return (value as? [String])?.contains("CloudKit") == true
    }()
}
