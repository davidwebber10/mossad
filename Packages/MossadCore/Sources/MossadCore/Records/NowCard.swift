import Foundation

/// The card at the top of the Mac's sidebar while a call records: its title, when it reads as selected, and what
/// VoiceOver says. A click opens the live call's page from any page of the app.
public enum NowCard {
    public static func title(_ record: CallRecord?) -> String {
        guard let record, record.titleSource != .platform else { return "Current call" }
        return record.title
    }

    /// Whether the live call's page shows: in List mode it is the selection, in Calendar mode the meeting open
    /// full-pane. The last meeting opened stays the selection after Back in Calendar mode, so it is no proof there.
    public static func isShown(liveID: String, onMeetings: Bool, calendarMode: Bool, selected: String?, openedFullPane: String?) -> Bool {
        guard onMeetings else { return false }
        return (calendarMode ? openedFullPane : selected) == liveID
    }

    public static func accessibilityLabel(title: String, seconds: TimeInterval, paused: Bool, mute: ShownMute) -> String {
        let minutes = Int(max(0, seconds)) / 60
        let length = minutes == 0 ? "less than a minute" : minutes == 1 ? "1 minute" : "\(minutes) minutes"
        let note = paused ? "paused" : mute.words
        return "Recording now: \(title), \(length)" + (note.map { ", \($0)" } ?? "")
    }

    /// The card's one state line. The state takes the place of "Recording", so the card keeps one height: "Paused ·
    /// 12:08" (nothing records, so it wins), "Muted · 12:08", "Muted when last seen" (no time, so it fits), or
    /// "Recording 12:08".
    public static func stateLine(elapsed: String, paused: Bool, mute: ShownMute) -> String {
        if paused { return "Paused · \(elapsed)" }
        switch mute {
        case .none: return "Recording \(elapsed)"
        case .muted: return "Muted · \(elapsed)"
        case .mutedWhenLastSeen: return "Muted when last seen"
        }
    }
}
