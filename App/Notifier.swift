import Foundation
import MossadCore
import UserNotifications

/// The one post-call notification: new voices to name.
final class Notifier: NSObject, UNUserNotificationCenterDelegate, @unchecked Sendable {
    var onOpen: @MainActor (String) -> Void = { _ in }

    override init() {
        super.init()
        UNUserNotificationCenter.current().delegate = self
    }

    func requestAuthorization() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert]) { granted, error in
            if let error { Log.error("Notification permission request failed: \(error)") }
            else if !granted { Log.error("Notifications not allowed") }
        }
    }

    func postNewVoices(_ record: CallRecord) {
        let count = record.unknownSpeakers.count
        let content = UNMutableNotificationContent()
        content.title = "Mossad"
        content.body = "\(count) new \(count == 1 ? "voice" : "voices") in \(record.title)"
        content.userInfo = ["callID": record.id]
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: record.id, content: content, trigger: nil))
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        guard let callID = response.notification.request.content.userInfo["callID"] as? String else { return }
        await onOpen(callID)
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .list]
    }
}
