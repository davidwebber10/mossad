import AppKit
import Foundation
import MossadCore
import UserNotifications

/// New voices to name after a call, and the warnings that a call is not recording: Mossad never fails without a word.
final class Notifier: NSObject, UNUserNotificationCenterDelegate, @unchecked Sendable {
    var onOpen: @MainActor (String) -> Void = { _ in }
    /// The owner pressed Record on an unconfirmed call: the app's bundle ID and the platform to record it as.
    var onRecord: @MainActor (String, Platform) -> Void = { _, _ in }
    /// The owner answered "Not a call": no more warnings for this app and reason today.
    var onNotACall: @MainActor (UnconfirmedCall) -> Void = { _ in }

    private static let unconfirmedCategory = "unconfirmed-call"
    private static let recordAction = "record"
    private static let notACallAction = "not-a-call"
    /// One warning per app, so a second app's warning does not replace the first.
    static func unconfirmedID(_ bundleID: String) -> String { "unconfirmed-call-\(bundleID)" }
    private static let cannotRecordID = "cannot-record"

    override init() {
        super.init()
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        let record = UNNotificationAction(identifier: Self.recordAction, title: "Record", options: [])
        let notACall = UNNotificationAction(identifier: Self.notACallAction, title: "Not a call", options: [])
        center.setNotificationCategories([UNNotificationCategory(identifier: Self.unconfirmedCategory, actions: [record, notACall],
                                                                 intentIdentifiers: [])])
    }

    func requestAuthorization() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, error in
            if let error { Log.error("Notification permission request failed: \(error)") }
            else if !granted { Log.error("Notifications not allowed") }
        }
    }

    func postNewVoices(_ record: CallRecord) {
        let count = record.unknownSpeakers.count
        let content = UNMutableNotificationContent()
        content.title = "\(count) new \(count == 1 ? "voice" : "voices") in \(record.title)"
        content.body = count == 1 ? "Click to name it" : "Click to name them"
        content.userInfo = ["callID": record.id]
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: record.id, content: content, trigger: nil))
    }

    /// An app uses the mic like a call, but Mossad cannot confirm a meeting, so nothing records yet.
    func postUnconfirmed(_ call: UnconfirmedCall) {
        let app = Self.appName(call.bundleID)
        let content = UNMutableNotificationContent()
        content.title = "Mossad is not recording"
        content.body = switch call.reason {
        case .cannotSeeMeeting: "\(app) is using your mic, but Mossad cannot see a meeting. Is this a call?"
        case .noAutomation: "\(app) is using your mic, but Mossad is not allowed to read its tabs. Click to allow Automation in System Settings, or press Record."
        case .meetingTabNotSelected: "\(app) is using your mic with a \(call.platform?.displayName ?? "meeting") tab in the background. Is this a call?"
        case .noMeetingWindow: "Zoom is using your mic, but Mossad cannot see a meeting window. Is this a call?"
        }
        content.sound = .default
        content.categoryIdentifier = Self.unconfirmedCategory
        content.userInfo = ["bundleID": call.bundleID, "platform": (call.platform ?? Self.guess(call.bundleID)).rawValue,
                            "reason": call.reason.rawValue]
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: Self.unconfirmedID(call.bundleID), content: content, trigger: nil))
    }

    /// The call started after all, so the warnings are out of date.
    func clearUnconfirmed() {
        let center = UNUserNotificationCenter.current()
        center.getDeliveredNotifications { delivered in
            let ids = delivered.map(\.request).filter { $0.content.categoryIdentifier == Self.unconfirmedCategory }.map(\.identifier)
            if !ids.isEmpty { center.removeDeliveredNotifications(withIdentifiers: ids) }
        }
    }

    /// A call was found, but the recording did not start.
    func postCannotRecord(_ error: FriendlyError, platform: Platform) {
        let content = UNMutableNotificationContent()
        content.title = "Mossad could not record this \(platform.displayName) call"
        content.body = error.message.isEmpty ? error.title : error.message
        content.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: Self.cannotRecordID, content: content, trigger: nil))
    }

    private static func appName(_ bundleID: String) -> String {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
        }
        return "An app"
    }

    /// A browser with no meeting tab in sight is most likely Meet; the calendar invite gives the call its title.
    private static func guess(_ bundleID: String) -> Platform {
        switch MeetingMatcher.appKind(bundleID: bundleID) {
        case .zoomApp: .zoom
        case .teamsApp: .teams
        default: .meet
        }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let info = response.notification.request.content.userInfo
        if response.notification.request.content.categoryIdentifier == Self.unconfirmedCategory {
            guard let bundleID = info["bundleID"] as? String,
                  let platform = (info["platform"] as? String).flatMap(Platform.init(rawValue:)) else { return }
            let reason = (info["reason"] as? String).flatMap(UnconfirmedCall.Reason.init(rawValue:)) ?? .cannotSeeMeeting
            // Only the Record button records: a click on the banner to read or close it must not start a recording.
            switch response.actionIdentifier {
            case Self.recordAction:
                await onRecord(bundleID, platform)
            case Self.notACallAction:
                await onNotACall(UnconfirmedCall(bundleID: bundleID, platform: nil, reason: reason))
            case UNNotificationDefaultActionIdentifier where reason == .noAutomation:
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation") {
                    _ = await MainActor.run { NSWorkspace.shared.open(url) }
                }
            default:
                break
            }
            return
        }
        guard let callID = response.notification.request.content.userInfo["callID"] as? String else { return }
        await onOpen(callID)
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .list]
    }
}
