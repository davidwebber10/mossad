#if os(macOS)
import AppKit
import ApplicationServices

/// Proof from Accessibility that a window is a call's own window: it holds the call's controls. For the screen
/// capture's choice of a Teams window, where the title alone proves nothing. Each walk has a small budget, and
/// the capture asks only for titles that are not proven yet.
enum CallWindowProbe {
    static let elementLimit = 1_500
    static let budget: TimeInterval = 0.4

    /// The titles among `titles` whose window has a control to leave the call and one to mute.
    static func callTitles(bundleID: String, among titles: Set<String>) -> Set<String> {
        guard AXIsProcessTrusted(), !titles.isEmpty else { return [] }
        AccessibilityTimeout.apply()
        var found: Set<String> = []
        for app in NSRunningApplication.runningApplications(withBundleIdentifier: bundleID) {
            for (window, title) in AXWalk.windows(of: app.processIdentifier) where titles.contains(title) && !found.contains(title) {
                var labels: [String] = []
                AXWalk.walk(window, limit: elementLimit, budget: budget) { element, role in
                    if role == kAXButtonRole || role == kAXCheckBoxRole {
                        labels += [kAXTitleAttribute, kAXDescriptionAttribute].compactMap { AXWalk.text(element, $0) }
                    }
                    return true
                }
                if hasCallControls(labels) { found.insert(title) }
            }
        }
        return found
    }

    static func hasCallControls(_ labels: [String]) -> Bool {
        let lower = labels.map { $0.lowercased() }
        return lower.contains { $0.hasPrefix("leave") || $0.hasPrefix("hang up") } && lower.contains { $0.hasPrefix("mute") || $0.hasPrefix("unmute") }
    }
}

/// The pages inside a browser window, so a frame keeps the page and not the tabs and panels around it.
enum WebAreaProbe {
    static let elementLimit = 3_000
    static let budget: TimeInterval = 0.5

    /// Every web area of the window with this title, with its frame in screen points from the top left. Empty
    /// when Accessibility is not allowed, the window is not found, or the walk was cut short: a walk that did not
    /// finish cannot say that there is only one page.
    static func areas(bundleID: String, windowTitle: String) -> [(element: AXUIElement, frame: CGRect)] {
        guard AXIsProcessTrusted() else { return [] }
        AccessibilityTimeout.apply()
        for app in NSRunningApplication.runningApplications(withBundleIdentifier: bundleID) {
            for (window, title) in AXWalk.windows(of: app.processIdentifier) where title == windowTitle {
                var found: [(element: AXUIElement, frame: CGRect)] = []
                let complete = AXWalk.walk(window, limit: elementLimit, budget: budget) { element, role in
                    guard role == "AXWebArea" else { return true }
                    if let f = AXWalk.frame(element) { found.append((element, f)) }
                    // The page's own content is not walked.
                    return false
                }
                if complete, !found.isEmpty { return found }
            }
        }
        return []
    }
}

/// A bounded walk of an app's Accessibility tree.
enum AXWalk {
    static func windows(of pid: pid_t) -> [(AXUIElement, String)] {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.5)
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value) == .success, let windows = value as? [AXUIElement] else { return [] }
        return windows.map { ($0, text($0, kAXTitleAttribute) ?? "") }
    }

    static func text(_ e: AXUIElement, _ name: String) -> String? {
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(e, name as CFString, &value) == .success, let text = value as? String, !text.isEmpty else { return nil }
        return text
    }

    /// Screen coordinates, from the top left.
    static func frame(_ e: AXUIElement) -> CGRect? {
        var p: AnyObject?, s: AnyObject?
        guard AXUIElementCopyAttributeValue(e, kAXPositionAttribute as CFString, &p) == .success,
              AXUIElementCopyAttributeValue(e, kAXSizeAttribute as CFString, &s) == .success,
              let p, let s, CFGetTypeID(p) == AXValueGetTypeID(), CFGetTypeID(s) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero, size = CGSize.zero
        guard AXValueGetValue(p as! AXValue, .cgPoint, &point), AXValueGetValue(s as! AXValue, .cgSize, &size) else { return nil }
        return CGRect(origin: point, size: size)
    }

    /// Visits elements until the limit, the time budget, or an app that does not answer. `visit` gets the element
    /// and its role and returns whether to go into its children. Returns false when the walk was cut short.
    @discardableResult
    static func walk(_ root: AXUIElement, limit: Int, budget: TimeInterval, visit: (AXUIElement, String) -> Bool) -> Bool {
        var visited = 0
        var cut = false
        let deadline = Date().addingTimeInterval(budget)
        func go(_ e: AXUIElement, depth: Int) {
            guard !cut, depth < 40 else { return }
            visited += 1
            guard visited < limit, Date() < deadline else {
                cut = true
                return
            }
            guard visit(e, text(e, kAXRoleAttribute) ?? "") else { return }
            var children: AnyObject?
            switch AXUIElementCopyAttributeValue(e, kAXChildrenAttribute as CFString, &children) {
            case .success: for child in (children as? [AXUIElement]) ?? [] { go(child, depth: depth + 1) }
            case .noValue, .attributeUnsupported, .invalidUIElement, .notImplemented: break
            default: cut = true  // The app does not answer: do not hold it up.
            }
        }
        go(root, depth: 0)
        return !cut
    }
}
#endif
