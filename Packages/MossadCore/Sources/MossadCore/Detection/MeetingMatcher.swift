import Foundation

/// Pure rules that recognise meeting apps, meeting tabs, and meeting windows.
public enum MeetingMatcher {
    static let zoomBundleID = "us.zoom.xos"
    static let teamsBundleID = "com.microsoft.teams2"
    static let safariBundleID = "com.apple.Safari"
    /// The browsers whose tabs Mossad reads. Beta, Canary, and Dev are apps of their own: their IDs start with
    /// stable Chrome's ID, and their helpers must not count as stable Chrome's.
    public static let browserBundleIDs = [
        "com.google.Chrome.beta",
        "com.google.Chrome.canary",
        "com.google.Chrome.dev",
        "com.google.Chrome",
        "company.thebrowser.Browser",
        "com.apple.Safari",
        "com.microsoft.edgemac",
        "com.brave.Browser",
    ]

    /// Browsers that can hold a call but whose tabs Mossad cannot read: their mic use is a call Mossad cannot see.
    public static let unreadableBrowserBundleIDs = [
        "org.mozilla.firefox",
        "org.mozilla.firefoxdeveloperedition",
        "org.mozilla.nightly",
        "com.vivaldi.Vivaldi",
        "com.operasoftware.Opera",
        "com.google.chrome.for.testing",
        "org.chromium.Chromium",
        "app.zen-browser.zen",
        "com.kagi.kagimacOS",
    ]

    /// Bundle IDs compare without case: Arc's helpers report a lower-case ID (`company.thebrowser.browser.helper`).
    public static func appKind(bundleID: String) -> AppKind? {
        let id = bundleID.lowercased()
        func owns(_ base: String) -> Bool {
            let b = base.lowercased()
            return id == b || id.hasPrefix(b + ".")
        }
        if owns(zoomBundleID) { return .zoomApp }
        if owns(teamsBundleID) { return .teamsApp }
        // Safari plays audio through the shared WebKit GPU process.
        if id.hasPrefix("com.apple.webkit") { return .browser(safariBundleID) }
        // The longest ID that fits wins: "com.google.chrome.for.testing" is not a helper of "com.google.Chrome".
        let readable = browserBundleIDs.filter(owns).max { $0.count < $1.count }
        let unreadable = unreadableBrowserBundleIDs.filter(owns).max { $0.count < $1.count }
        if let unreadable, unreadable.count > (readable?.count ?? 0) { return .unreadableBrowser(unreadable) }
        return readable.map { .browser($0) }
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

    /// A Teams web tab that shows a call: the same title rule as the app's meeting window.
    public static func teamsTabIsMeeting(_ tab: BrowserTab) -> Bool {
        platform(forTabURL: tab.url) == .teams && teamsWindowIsMeeting(tab.title)
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
    /// With more than one copy of a browser running (a test tool's hidden Chrome has the same app ID), the question
    /// can reach the wrong copy, so a list with no meeting in it says nothing about the owner's call.
    public static func trustedTabs(_ tabs: [BrowserTab], browserCopies: Int) -> [BrowserTab]? {
        guard browserCopies > 1, !tabs.contains(where: { platform(forTabURL: $0.url) != nil }) else { return tabs }
        return nil
    }

    /// A browser window's title starts with its selected tab's title, and every copy of the browser shows its
    /// windows to Accessibility, so a Meet call is visible here when the tab list came from the wrong copy.
    public static func meetWindowIsMeeting(_ title: String) -> Bool {
        !meetTabLeftMeeting(title: title)
    }

    public static func meetTabLeftMeeting(title: String) -> Bool {
        let t = title.trimmingCharacters(in: .whitespaces)
        return !(t.hasPrefix("Meet - ") || t.hasPrefix("Meet – "))
    }
}
