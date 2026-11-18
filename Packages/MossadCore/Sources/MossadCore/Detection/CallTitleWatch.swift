import Foundation

/// Whether the browser's windows show another Meet meeting than the call's own. Accessibility answers for every copy
/// of the browser, where the tab list reaches one copy only; but a window shows only its selected tab, so a change
/// here is not sure by itself. It only observes: a change is a mark in the recording, never an end or a start.
public struct CallTitleWatch: Equatable, Sendable {
    public static let readingGap: TimeInterval = CallLinkWatch.readingGap

    /// The meeting part of the call's last Meet title.
    public private(set) var title: String?
    private var pending: String?
    private var pendingAt: Date?

    public init() {}

    /// The time of the first reading of a title change that waits for its second reading.
    public var pendingSince: Date? { pendingAt }

    /// The new meeting title when the windows showed the call's Meet title, now show exactly one other Meet title,
    /// and did so on two readings within `readingGap`. A reading with no Meet title (another tab is in front) is no
    /// information: it changes nothing and keeps the last title. Nil titles are unknown.
    public mutating func observe(_ titles: [String]?, at time: Date) -> String? {
        guard let titles else { return nil }
        let meetings = Set(titles.compactMap(Self.meeting(inWindowTitle:)))
        guard !meetings.isEmpty else { return nil }
        guard let title else {
            if meetings.count == 1 { self.title = meetings.first }
            return nil
        }
        guard !meetings.contains(title), meetings.count == 1, let next = meetings.first else { return clear() }
        guard pending == next, let since = pendingAt, time.timeIntervalSince(since) <= Self.readingGap else {
            pending = next
            pendingAt = time
            return nil
        }
        self.title = next
        _ = clear()
        return next
    }

    private mutating func clear() -> String? {
        pending = nil
        pendingAt = nil
        return nil
    }

    /// Browser names that end a window title: never a meeting's name.
    static let browserNames = ["Google Chrome", "Chromium", "Microsoft Edge", "Brave", "Arc", "Vivaldi", "Opera", "Safari", "Firefox"]

    /// The meeting's part of a Meet window title ("Meet - <meeting> - <browser> - <profile>"): the text up to the next
    /// separator, so a sound sign or the browser's profile is not a new meeting. A meeting name that holds a separator
    /// is cut short; two such names can then look alike, which can only miss a mark, never make one.
    public static func meeting(inWindowTitle title: String) -> String? {
        guard MeetingMatcher.meetWindowIsMeeting(title) else { return nil }
        let rest = title.trimmingCharacters(in: .whitespaces).dropFirst("Meet - ".count)
        let part = rest.components(separatedBy: " - ").first?.components(separatedBy: " – ").first ?? ""
        let meeting = part.trimmingCharacters(in: .whitespaces)
        guard !meeting.isEmpty, !browserNames.contains(where: { meeting.hasPrefix($0) }) else { return nil }
        return meeting
    }
}
