import Foundation

/// Pure rules that recognise meeting apps, meeting tabs, and meeting windows.
public enum MeetingMatcher {
    static let zoomBundleID = "us.zoom.xos"
    static let teamsBundleID = "com.microsoft.teams2"
    static let browserBundleIDs = [
        "com.google.Chrome",
        "company.thebrowser.Browser",
        "com.apple.Safari",
        "com.microsoft.edgemac",
        "com.brave.Browser",
    ]

    public static func appKind(bundleID: String) -> AppKind? {
        if bundleID == zoomBundleID { return .zoomApp }
        if bundleID == teamsBundleID { return .teamsApp }
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
            return path.range(of: #"^/[a-z]{3}-[a-z]{4}-[a-z]{3}"#, options: .regularExpression) != nil ? .meet : nil
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

    /// Meet keeps the same URL on its post-call page; in a call the title carries the meeting code or name.
    public static func meetTabLeftMeeting(title: String) -> Bool {
        let t = title.trimmingCharacters(in: .whitespaces)
        return !(t.hasPrefix("Meet - ") || t.hasPrefix("Meet – "))
    }
}
