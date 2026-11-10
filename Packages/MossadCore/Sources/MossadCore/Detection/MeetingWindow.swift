import CoreGraphics
import Foundation

/// A window as the window server lists it.
public struct WindowCandidate: Equatable, Sendable {
    public var id: UInt32
    public var bundleID: String
    public var title: String
    public var width: Double
    public var height: Double
    public var onScreen: Bool
    /// 0 for a normal window; a floating window (picture-in-picture) is above 0.
    public var layer: Int

    public init(id: UInt32, bundleID: String, title: String, width: Double, height: Double, onScreen: Bool, layer: Int = 0) {
        self.id = id
        self.bundleID = bundleID
        self.title = title
        self.width = width
        self.height = height
        self.onScreen = onScreen
        self.layer = layer
    }

    var area: Double { width * height }
}

/// Pure rules for the one window that shows the call, for the screen capture. A window that is not surely the
/// meeting is never chosen: no window is better than a picture of the owner's mail.
public enum MeetingWindow {
    /// What kind of meeting window a title is, best first.
    public enum Kind: Int, Comparable, Sendable {
        /// The shared content in a window of its own.
        case share = 0
        case meeting
        /// A small view of a meeting whose own window is hidden: Teams' compact view, Meet's picture-in-picture.
        case small

        public static func < (a: Kind, b: Kind) -> Bool { a.rawValue < b.rawValue }
    }

    /// Windows this small are toolbars and badges, not content.
    static let minimumSide: Double = 120

    /// Parts of the Teams app's main window that are known. They are never the call, also when something else
    /// seems to say so. This list only refuses; no window is accepted because it is missing here.
    static let teamsSections: Set<String> = [
        "activity", "chat", "teams", "calendar", "calls", "files", "onedrive", "apps", "copilot", "search", "settings",
        "people", "communities", "viva engage", "shifts", "approvals", "planner", "meet", "meetings", "notifications", "tasks",
        "microsoft teams", "meeting join",
    ]

    /// The window to capture for a call of `platform` in the app `bundleID`, or nil when none is surely the meeting.
    /// `confirmed` are the titles of windows that Accessibility showed to hold the call's own controls.
    public static func choose(_ windows: [WindowCandidate], platform: Platform, bundleID: String, meetingID: String? = nil,
                              confirmed: Set<String> = []) -> WindowCandidate? {
        let ranked = windows.compactMap { w in kind(of: w, among: windows, platform: platform, bundleID: bundleID, confirmed: confirmed).map { (w, $0) } }
        // A small view only when the meeting's own window is not on screen.
        let usable = ranked.filter { pair in
            pair.1 != .small || !ranked.contains { $0.1 != .small && $0.0.onScreen }
        }
        func own(_ w: WindowCandidate) -> Bool {
            guard let meetingID, !meetingID.isEmpty else { return false }
            return w.title.lowercased().contains(meetingID.lowercased())
        }
        return usable.min { a, b in
            // On screen first: a hidden meeting window sends no picture while a small view of it does.
            if a.0.onScreen != b.0.onScreen { return a.0.onScreen }
            if a.1 != b.1 { return a.1 < b.1 }
            if own(a.0) != own(b.0) { return own(a.0) }
            if a.0.area != b.0.area { return a.0.area > b.0.area }
            return a.0.id < b.0.id
        }?.0
    }

    /// Whether a window is the call's, and which kind. `windows` are all windows of the list, for the Teams rule
    /// that ties a second window to the meeting's own.
    public static func kind(of w: WindowCandidate, among windows: [WindowCandidate], platform: Platform, bundleID: String,
                            confirmed: Set<String> = []) -> Kind? {
        guard min(w.width, w.height) >= minimumSide, let app = MeetingMatcher.appKind(bundleID: bundleID) else { return nil }
        let owner = w.bundleID.lowercased()
        switch (app, platform) {
        case (.zoomApp, .zoom):
            guard owner == MeetingMatcher.zoomBundleID.lowercased(), w.layer == 0 else { return nil }
            return zoomTitleIsMeeting(w.title) ? .meeting : nil
        case (.teamsApp, .teams):
            guard owner == MeetingMatcher.teamsBundleID.lowercased() else { return nil }
            let titles = windows.filter { $0.bundleID.lowercased() == owner }.map(\.title)
            return teamsKind(w.title, meetingNames: teamsMeetingNames(titles, confirmed: confirmed))
        case (.browser(let browser), _):
            let base = browser.lowercased()
            // A site installed as an app has a window of its own under the browser's ID.
            guard owner == base || owner.hasPrefix(base + ".app.") else { return nil }
            guard tabTitleIsMeeting(w.title, platform: platform) else { return nil }
            if w.layer == 0 { return .meeting }
            // Only Chrome opens Meet's picture-in-picture by itself.
            return platform == .meet && base != MeetingMatcher.safariBundleID.lowercased() ? .small : nil
        default:
            return nil
        }
    }

    /// Whether the window that was chosen is still the call's. Checked for each frame with the window's title of
    /// that moment: in a browser the same window shows another tab one click later.
    public static func stillMeeting(_ w: WindowCandidate, platform: Platform, bundleID: String, meetingNames: Set<String> = []) -> Bool {
        guard let app = MeetingMatcher.appKind(bundleID: bundleID) else { return false }
        switch (app, platform) {
        case (.zoomApp, .zoom): return zoomTitleIsMeeting(w.title)
        // `meetingNames` are the names proven when the window was chosen; a new title must fit one of them.
        case (.teamsApp, .teams): return teamsKind(w.title, meetingNames: meetingNames) != nil
        case (.browser, _): return tabTitleIsMeeting(w.title, platform: platform)
        default: return false
        }
    }

    /// "Zoom Meeting", "Zoom Webinar", and their forms with more words ("Zoom Meeting 40-Minutes"). Zoom's small
    /// tool windows have lower-case names ("zoom share toolbar window").
    static func zoomTitleIsMeeting(_ title: String) -> Bool {
        title.hasPrefix("Zoom Meeting") || title.hasPrefix("Zoom Webinar")
    }

    private static func teamsParts(_ title: String) -> [String]? {
        let parts = title.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count >= 2, parts.last == "Microsoft Teams" else { return nil }
        return Array(parts.dropLast())
    }

    /// The name in a title of the form "<name> | Microsoft Teams", unless it is a known part of the main window.
    /// This form alone proves nothing: the main window shows each of its pages and apps with the same form.
    static func teamsSingleName(_ title: String) -> String? {
        guard let parts = teamsParts(title), parts.count == 1, !parts[0].isEmpty,
              !teamsSections.contains(parts[0].lowercased()) else { return nil }
        return parts[0]
    }

    /// Titles that can be the meeting's own window but need proof from Accessibility (the call's controls).
    public static func teamsTitlesToProve(_ titles: [String]) -> [String] {
        let proven = teamsMeetingNames(titles, confirmed: [])
        return titles.filter { title in teamsSingleName(title).map { !proven.contains($0) } ?? false }
    }

    /// The names of the meetings that surely have a window. A name counts when the title says so ("Meeting with …",
    /// "Call with …"), when a compact view names it, or when Accessibility found the call's controls in its window.
    /// Never because of the window's size, and never because the name is merely unknown.
    static func teamsMeetingNames(_ titles: [String], confirmed: Set<String>) -> Set<String> {
        var names: Set<String> = []
        for title in titles {
            guard let parts = teamsParts(title) else { continue }
            if parts.count == 2, parts[0].lowercased() == "meeting compact view", !teamsSections.contains(parts[1].lowercased()) {
                names.insert(parts[1])
            }
            guard let name = teamsSingleName(title) else { continue }
            if confirmed.contains(title) || name.hasPrefix("Meeting with ") || name.hasPrefix("Call with ") { names.insert(name) }
        }
        return names
    }

    /// "<name> | Microsoft Teams" for a proven name is the meeting, "Meeting compact view | <name> | …" its small
    /// view, and "<words for a share> | <name> | …" for a proven name its popped-out share. Anything else is not chosen.
    static func teamsKind(_ title: String, meetingNames: Set<String>) -> Kind? {
        guard let parts = teamsParts(title) else { return nil }
        if parts.count == 1 { return teamsSingleName(title).map(meetingNames.contains) == true ? .meeting : nil }
        guard parts.count == 2, !teamsSections.contains(parts[1].lowercased()) else { return nil }
        let head = parts[0].lowercased()
        if head == "meeting compact view" { return .small }
        guard !teamsSections.contains(head), meetingNames.contains(parts[1]) else { return nil }
        return ["shared", "sharing", "presenting", "presentation"].contains(where: head.contains) ? .share : nil
    }

    /// A browser window's title starts with its selected tab's title, so this is true only while the meeting is
    /// the tab in front.
    static func tabTitleIsMeeting(_ title: String, platform: Platform) -> Bool {
        switch platform {
        case .meet:
            return MeetingMatcher.meetWindowIsMeeting(title)
        case .teams:
            // Only a page that names a meeting or a call with someone. "Calls", "Chat", and the other pages of
            // Teams in a browser are the owner's own data.
            guard let end = title.range(of: "| Microsoft Teams") else { return false }
            let parts = title[..<end.lowerBound].components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
            guard let head = parts.first, !parts.contains(where: { teamsSections.contains($0.lowercased()) }) else { return false }
            return head.hasPrefix("Meeting with ") || head.hasPrefix("Call with ") || head.hasPrefix("Meeting in ")
                || head.hasSuffix(" Meeting") || head.hasSuffix(" meeting")
        case .zoom:
            return zoomTitleIsMeeting(title)
        case .inPerson:
            return false
        }
    }

    // MARK: What part of the window is kept

    /// A browser's own bars above the page: tabs, the address, bookmarks. Cut when the page's place is not known.
    static let browserTopBand: Double = 125

    /// The part of the window that a frame keeps, in parts of the window (0 to 1, from the top left), or nil when
    /// the window must not be captured. A browser window shows the owner's other tabs, the address, and bookmarks
    /// around the page, so only the page is kept: `webArea` is the page's frame inside the window, in points, as
    /// Accessibility gives it. Without it the top band is cut. A browser with its tabs at the side needs the page's frame.
    public static func keptPart(of w: WindowCandidate, bundleID: String, webArea: CGRect?) -> CGRect? {
        let whole = CGRect(x: 0, y: 0, width: 1, height: 1)
        guard case .browser(let browser)? = MeetingMatcher.appKind(bundleID: bundleID) else { return whole }
        // A site installed as an app and a picture-in-picture window have no tabs of other pages.
        if w.layer != 0 || w.bundleID.lowercased() != browser.lowercased() { return whole }
        guard w.width > 0, w.height > 0 else { return nil }
        if let webArea, webArea.minX >= -2, webArea.minY >= -2, webArea.maxX <= w.width + 2, webArea.maxY <= w.height + 2,
           webArea.width >= w.width * 0.4, webArea.height >= w.height * 0.4 {
            return CGRect(x: max(0, webArea.minX) / w.width, y: max(0, webArea.minY) / w.height,
                          width: min(webArea.width, w.width) / w.width, height: min(webArea.height, w.height) / w.height)
                .intersection(whole)
        }
        guard browser != "company.thebrowser.Browser", w.height >= browserTopBand * 2.5 else { return nil }
        let top = browserTopBand / w.height
        return CGRect(x: 0, y: top, width: 1, height: 1 - top)
    }
}

/// Whether other windows hide a window, from their frames alone.
public enum WindowCover {
    /// The part of `window` (0 to 1) that the windows above it cover.
    public static func coveredPart(of window: CGRect, by above: [CGRect]) -> Double {
        let area = window.width * window.height
        guard area > 0 else { return 1 }
        let parts = above.map { $0.intersection(window) }.filter { !$0.isNull && $0.width > 0 && $0.height > 0 }
        guard !parts.isEmpty else { return 0 }
        // The union's area on the grid of all edges: the frames are few.
        let xs = Array(Set(parts.flatMap { [$0.minX, $0.maxX] })).sorted(), ys = Array(Set(parts.flatMap { [$0.minY, $0.maxY] })).sorted()
        var covered = 0.0
        for i in 0..<(xs.count - 1) {
            for j in 0..<(ys.count - 1) {
                let cell = CGRect(x: xs[i], y: ys[j], width: xs[i + 1] - xs[i], height: ys[j + 1] - ys[j])
                if parts.contains(where: { $0.contains(CGPoint(x: cell.midX, y: cell.midY)) }) { covered += cell.width * cell.height }
            }
        }
        return covered / area
    }

    /// Covered enough that the app can stop drawing it: 95 percent or more.
    public static func isCovered(_ window: CGRect, by above: [CGRect]) -> Bool {
        coveredPart(of: window, by: above) >= 0.95
    }
}
