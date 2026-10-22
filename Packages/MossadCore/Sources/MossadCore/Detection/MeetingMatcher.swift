import Foundation

/// Pure rules that recognise meeting apps, meeting tabs, and meeting windows.
public enum MeetingMatcher {
    static let zoomBundleID = "us.zoom.xos"
    static let teamsBundleID = "com.microsoft.teams2"
    public static let browserBundleIDs = [
        "com.google.Chrome",
        "company.thebrowser.Browser",
        "com.apple.Safari",
        "com.microsoft.edgemac",
        "com.brave.Browser",
    ]

    public static func appKind(bundleID: String) -> AppKind? {
        if bundleID == zoomBundleID || bundleID.hasPrefix(zoomBundleID + ".") { return .zoomApp }
        if bundleID == teamsBundleID || bundleID.hasPrefix(teamsBundleID + ".") { return .teamsApp }
        // Safari plays audio through the shared WebKit GPU process.
        if bundleID.hasPrefix("com.apple.WebKit") { return .browser("com.apple.Safari") }
        for browser in browserBundleIDs where bundleID == browser || bundleID.hasPrefix(browser + ".") {
            return .browser(browser)
        }
        return nil
    }

    public static func platform(forTabURL string: String) -> Platform? {
        guard let url = URL(string: string), let host = url.host?.lowercased() else { return nil }
        let path = url.path
        if host == "meet.google.com" {
            return path.range(of: #"^/(meet/)?[a-z]{3}-[a-z]{4}-[a-z]{3}"#, options: .regularExpression) != nil ? .meet : nil
        }
        if host == "teams.microsoft.com" || host == "teams.cloud.microsoft" || host == "teams.live.com" {
            return .teams
        }
        if host == "zoom.us" || host.hasSuffix(".zoom.us") {
            return path.hasPrefix("/wc/") ? .zoom : nil
        }
        return nil
    }

    public static func zoomWindowIsMeeting(_ title: String) -> Bool {
        title == "Zoom Meeting" || title == "Zoom Webinar"
    }

    public static func teamsWindowIsMeeting(_ title: String) -> Bool {
        guard title.hasSuffix("| Microsoft Teams") else { return false }
        let head = title.components(separatedBy: "|").first ?? ""
        return head.contains("Meeting") || head.hasPrefix("Call")
    }

    /// The meeting's own ID from a tab URL, as it also appears in the calendar invite's link.
    /// Nil when the URL does not carry one (the Teams app shell, for example).
    public static func meetingID(forTabURL string: String) -> String? {
        guard let platform = platform(forTabURL: string) else { return nil }
        let pattern = switch platform {
        case .meet: #"(?<=meet\.google\.com/)(meet/)?[a-z]{3}-[a-z]{4}-[a-z]{3}"#
        case .zoom: #"(?<=/wc/)(join/)?\d{9,12}"#
        case .teams: #"meeting_[A-Za-z0-9_-]+"#
        case .inPerson: #"(?!)"#
        }
        let text = string.removingPercentEncoding ?? string
        guard let range = text.range(of: pattern, options: .regularExpression) else { return nil }
        return String(text[range]).replacingOccurrences(of: "meet/", with: "").replacingOccurrences(of: "join/", with: "")
    }

    /// Meet keeps the same URL on its post-call page; in a call the title carries the meeting code or name.
    public static func meetTabLeftMeeting(title: String) -> Bool {
        let t = title.trimmingCharacters(in: .whitespaces)
        return !(t.hasPrefix("Meet - ") || t.hasPrefix("Meet – "))
    }
}
