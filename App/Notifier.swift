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
    /// The owner pressed Record on a call that was kept off the record because the do-not-record list is damaged.
    var onRecordBlocked: @MainActor (String, Platform) -> Void = { _, _ in }

    private static let unconfirmedCategory = "unconfirmed-call"
    private static let recordAction = "record"
    private static let notACallAction = "not-a-call"
    /// One warning per app, so a second app's warning does not replace the first.
    static func unconfirmedID(_ bundleID: String) -> String { "unconfirmed-call-\(bundleID)" }
    private static let cannotRecordID = "cannot-record"
    private static let notRecordedCategory = "not-recorded"

    override init() {
        super.init()
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        let record = UNNotificationAction(identifier: Self.recordAction, title: "Record", options: [])
        let notACall = UNNotificationAction(identifier: Self.notACallAction, title: "Not a call", options: [])
        center.setNotificationCategories([
            UNNotificationCategory(identifier: Self.unconfirmedCategory, actions: [record, notACall], intentIdentifiers: []),
            UNNotificationCategory(identifier: Self.notRecordedCategory, actions: [record], intentIdentifiers: []),
        ])
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

    /// A call with an invite was kept off the record, and not by the owner's choice: the do-not-record list is
    /// damaged, so Mossad cannot know the choice. Said at each such call; Record starts the recording.
    func postNotRecorded(title: String, bundleID: String, platform: Platform) {
        let content = UNMutableNotificationContent()
        content.title = "Mossad did not record \(title.isEmpty ? "this call" : title)"
        content.body = "The do-not-record list could not be read. Press Record to record this call. To end this, set a choice for any upcoming meeting, or reset the list in Settings, Recording."
        content.sound = .default
        content.categoryIdentifier = Self.notRecordedCategory
        content.userInfo = ["bundleID": bundleID, "platform": platform.rawValue]
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "not-recorded-\(bundleID)", content: content, trigger: nil))
    }

    /// A damaged file was set aside; said one time for each file.
    func postSetAside(_ r: StoredFile.Recovery) {
        let what: String = switch r.file {
        case "voices.json": "Mossad starts with no saved voices and asks for names again."
        case CoachProfile.fileName: "The coach's memory starts empty here. Mossad takes the copy from your other device at the next sync, before it sends anything."
        case CommitmentBook.fileName: "Your commitments start empty here. Mossad takes the copy from your other device at the next sync, before it sends anything."
        case ShareBook.fileName: "The list of share links starts empty. Links you made before still work."
        default: "That item is left out."
        }
        let content = UNMutableNotificationContent()
        content.title = "Mossad set aside a damaged file"
        content.body = "\(r.file) could not be read. It is kept as \(r.kept). \(what)"
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "set-aside-\(r.kept)", content: content, trigger: nil))
    }

    static func recordingText(_ p: PendingRecording) -> (title: String, body: String) {
        let name = p.title?.nonEmpty.map { "\"\($0)\"" } ?? "A recording"
        let day = p.start.map { " from \($0.formatted(date: .abbreviated, time: .shortened))" } ?? ""
        if p.gaveUp == true {
            return ("Mossad stopped trying an iPhone recording",
                    "\(name)\(day) could not be imported for 7 days. It is still on your iPhone; send it again from there.")
        }
        return ("An iPhone recording has not arrived on this Mac",
                "\(name)\(day) could not be imported for a day. Mossad keeps trying. It is still on your iPhone.")
    }

    /// A room recording from the iPhone has failed to import for a day, or Mossad stopped trying it. One time each.
    func postRecordingWaiting(_ p: PendingRecording) {
        let text = Self.recordingText(p)
        let content = UNMutableNotificationContent()
        content.title = text.title
        content.body = text.body
        content.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "recording-waiting-\(p.name)", content: content, trigger: nil))
    }

    /// A call was found, but the recording did not start.
    func postCannotRecord(_ error: FriendlyError, platform: Platform) {
        let content = UNMutableNotificationContent()
        content.title = "Mossad could not record this \(platform.displayName) call"
        content.body = error.message.isEmpty ? error.title : error.message
        content.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: Self.cannotRecordID, content: content, trigger: nil))
    }

    /// A recording runs, but it loses one side of the call or cannot be saved. One notification per kind of problem.
    func postCaptureProblem(_ problem: CaptureProblem) {
        let content = UNMutableNotificationContent()
        content.title = problem.title
        content.body = problem.message
        content.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "capture-problem-\(problem.title)", content: content, trigger: nil))
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
        if response.notification.request.content.categoryIdentifier == Self.notRecordedCategory {
            // Only the Record button records, as for the other warnings.
            guard response.actionIdentifier == Self.recordAction, let bundleID = info["bundleID"] as? String,
                  let platform = (info["platform"] as? String).flatMap(Platform.init(rawValue:)) else { return }
            await onRecordBlocked(bundleID, platform)
            return
        }
        guard let callID = response.notification.request.content.userInfo["callID"] as? String else { return }
        await onOpen(callID)
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .list]
    }
}
