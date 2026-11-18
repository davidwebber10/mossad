import CryptoKit
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

    /// The key of a meeting's part of a title: the first 8 bytes of its SHA-256, in hex. A record keeps this, never
    /// the text.
    public static func key(_ meeting: String) -> String {
        SHA256.hash(data: Data(meeting.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
    }

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

    /// Browser names that end a window title, alone or with the browser's profile after them.
    static let browserNames: Set<String> = ["Google Chrome", "Google Chrome Beta", "Google Chrome Canary", "Google Chrome Dev",
                                            "Chromium", "Microsoft Edge", "Microsoft Edge Beta", "Microsoft Edge Dev",
                                            "Microsoft Edge Canary", "Brave", "Brave Browser", "Arc", "Vivaldi", "Opera",
                                            "Safari", "Firefox"]
    static let separators = [" - ", " – ", " — "]

    /// The meeting's part of a Meet window title ("Meet - <meeting> - <browser> - <profile>"). The browser's name is
    /// taken off only as the title's last part, or the one before a last part (the profile), by the title's own
    /// separators: never from the start of a meeting's name. The meeting is the next part after "Meet - ", so a sound
    /// sign is not a new meeting. A meeting name that holds a separator is cut short; two such names can then look
    /// alike, which can only miss a mark, never make one.
    public static func meeting(inWindowTitle title: String) -> String? {
        var parts = [title.replacingOccurrences(of: "\u{200B}", with: "").trimmingCharacters(in: .whitespaces)]
        for separator in separators { parts = parts.flatMap { $0.components(separatedBy: separator) } }
        parts = parts.map { $0.trimmingCharacters(in: .whitespaces) }
        if parts.count >= 2, browserNames.contains(parts[parts.count - 1]) {
            parts.removeLast()
        } else if parts.count >= 3, browserNames.contains(parts[parts.count - 2]) {
            parts.removeLast(2)
        }
        guard parts.count >= 2, parts[0] == "Meet", !parts[1].isEmpty else { return nil }
        return parts[1]
    }
}
