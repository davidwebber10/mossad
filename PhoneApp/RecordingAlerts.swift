import MossadCore
import UserNotifications

/// The room recorder's local notifications. A phone that lies locked on the table cannot show the error card, and a
/// recording that stays paused loses the rest of the meeting: this is the one case where Mossad notifies.
enum RecordingAlerts {
    private static let id = "room-recording"
    private static var center: UNUserNotificationCenter { .current() }

    /// Asked when the first recording starts, not at launch: only the recorder notifies.
    static func requestPermission() {
        Task { _ = try? await center.requestAuthorization(options: [.alert, .sound]) }
    }

    static func notify(_ alert: RoomRecording.Alert) { add(alert, trigger: nil) }

    /// Fires unless cancelled first: the app may be suspended while an interruption lasts.
    static func schedule(_ alert: RoomRecording.Alert, after seconds: TimeInterval) {
        add(alert, trigger: UNTimeIntervalNotificationTrigger(timeInterval: max(1, seconds), repeats: false))
    }

    static func cancel() {
        center.removePendingNotificationRequests(withIdentifiers: [id])
        center.removeDeliveredNotifications(withIdentifiers: [id])
    }

    private static func add(_ alert: RoomRecording.Alert, trigger: UNNotificationTrigger?) {
        let content = UNMutableNotificationContent()
        switch alert {
        case .paused:
            content.title = "Recording is paused"
            content.body = "Nothing is recorded until you resume. Open Mossad to keep recording."
        case .stopped:
            content.title = "Recording stopped"
            content.body = "The iPhone stopped recording the room. What it recorded is saved. Open Mossad to record again."
        }
        content.sound = .default
        center.add(UNNotificationRequest(identifier: id, content: content, trigger: trigger))
    }
}

/// Shows the recorder's notification while the app is open too: the screen may be on, with nobody looking at it.
final class NotificationPresenter: NSObject, UNUserNotificationCenterDelegate, Sendable {
    static let shared = NotificationPresenter()

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async
        -> UNNotificationPresentationOptions { [.banner, .list, .sound] }
}
