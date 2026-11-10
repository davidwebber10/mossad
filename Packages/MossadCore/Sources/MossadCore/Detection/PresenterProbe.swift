#if os(macOS)
import AppKit
import ApplicationServices

/// Reads who shares the screen from the call app's own share indicator, through Accessibility: the titles of the
/// app's windows (Zoom names the presenter there) and the labels in the window that is captured. Text that people
/// wrote (a chat, a text field, a document) is not walked. One walk with a small budget; the screen capture asks at
/// the start of a share session and at most once a minute while frames are kept, never for each frame. Nil when
/// the app shows no name, when Accessibility is not allowed, or when the walk found none in its budget.
public struct PresenterProbe: Sendable {
    static let elementLimit = 1_500
    static let budget: TimeInterval = 0.5
    /// Places that hold what people wrote, not the app's own labels.
    static let skippedRoles: Set<String> = ["AXTextArea", "AXTextField", "AXList", "AXTable", "AXOutline", "AXBrowser", "AXMenuBar"]
    static let skippedSubroles: Set<String> = ["AXApplicationLog", "AXDocumentArticle", "AXContentList", "AXLandmarkComplementary"]

    public init() {}

    /// `windowTitle` is the title of the window that is captured; only that window's labels are read. A name, or
    /// `.none` after a walk that read the whole window, or `.unknown` when nothing can be said (no Accessibility,
    /// no such window, a walk that was cut short): unknown is not "no name".
    public func presenter(bundleID: String, windowTitle: String?) -> PresenterRead {
        guard AXIsProcessTrusted(), let windowTitle else { return .unknown }
        AccessibilityTimeout.apply()
        var complete = false
        for app in NSRunningApplication.runningApplications(withBundleIdentifier: bundleID) {
            let windows = AXWalk.windows(of: app.processIdentifier)
            guard let window = windows.first(where: { $0.1 == windowTitle })?.0 else { continue }
            // Zoom names the presenter in the title of a window of its own. A browser's other windows are the owner's.
            if case .zoomApp? = MeetingMatcher.appKind(bundleID: bundleID), let name = PresenterLabel.name(in: windows.map(\.1)) { return .name(name) }
            var labels: [String] = []
            let whole = AXWalk.walk(window, limit: Self.elementLimit, budget: Self.budget) { element, role in
                if Self.skippedRoles.contains(role) { return false }
                if let subrole = AXWalk.text(element, kAXSubroleAttribute), Self.skippedSubroles.contains(subrole) { return false }
                for name in [kAXTitleAttribute, kAXDescriptionAttribute, kAXValueAttribute] {
                    if let text = AXWalk.text(element, name), text.count <= 120, PresenterLabel.mayName(text) { labels.append(text) }
                }
                return true
            }
            if let name = PresenterLabel.name(in: labels) { return .name(name) }
            complete = complete || whole
        }
        return complete ? .none : .unknown
    }
}
#endif
