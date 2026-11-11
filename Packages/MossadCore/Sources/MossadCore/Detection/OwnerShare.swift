import Foundation

/// Whether the owner shares the screen now, from the bars that the call apps and the browsers show while they
/// share. The window titles need the Screen Recording permission: with no title to read, the answer is nil.
public enum OwnerShare {
    static let apps = ["zoom.us", "Microsoft Teams", "Google Chrome", "Safari", "Microsoft Edge", "Arc", "Firefox", "Brave Browser", "Webex", "Slack"]
    static let bars = ["share toolbar", "share statusbar", "sharing control bar", "is sharing your screen", "is sharing a window", "is sharing this tab",
                       "sharing this tab", "you are sharing", "you're sharing", "stop sharing", "presenting now", "you are presenting"]

    /// `windows` are the on-screen windows of other apps (not Mossad's own): the owning app and the title.
    public static func isSharing(_ windows: [(owner: String, title: String?)]) -> Bool? {
        let mine = windows.filter { w in apps.contains { w.owner.localizedCaseInsensitiveContains($0) } }
        let titles = mine.compactMap(\.title).filter { !$0.isEmpty }
        if titles.contains(where: { t in bars.contains { t.lowercased().contains($0) } }) { return true }
        // A call app or a browser with a window whose title cannot be read: its share bar could be that window.
        if mine.contains(where: { $0.title == nil }) { return nil }
        return windows.contains { $0.title?.isEmpty == false } ? false : nil
    }
}
