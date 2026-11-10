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

/// What a read of a browser window's pages gave.
enum PageRead {
    /// The whole window was walked: its Accessibility element and frame, and every web area with its frame, all in
    /// screen points from the top left. No web area is a sure answer too.
    case pages(window: AXUIElement, frame: CGRect, areas: [(element: AXUIElement, frame: CGRect)])
    /// Nothing can be said: no Accessibility, the window not found for sure, a walk that was cut short, or an
    /// element that could not be read. This is not "one page" and not "no page".
    case unknown
}

/// The pages inside a browser window, so a frame keeps the page and not the tabs and panels around it.
enum WebAreaProbe {
    static let elementLimit = 3_000
    static let budget: TimeInterval = 0.5

    /// `windowTitle` and `windowFrame` are the window server's; the Accessibility window is matched to them.
    static func read(bundleID: String, windowTitle: String, windowFrame: CGRect?) -> PageRead {
        guard AXIsProcessTrusted() else { return .unknown }
        AccessibilityTimeout.apply()
        for app in NSRunningApplication.runningApplications(withBundleIdentifier: bundleID) {
            guard let window = AXWalk.window(of: app.processIdentifier, title: windowTitle, frame: windowFrame),
                  let frame = AXWalk.frame(window) else { continue }
            var found: [(element: AXUIElement, frame: CGRect)] = []
            var unreadable = false
            let complete = AXWalk.walk(window, limit: elementLimit, budget: budget, strict: true) { element, role in
                guard role == "AXWebArea" else { return true }
                // A page whose place cannot be read may be a second page: then nothing is sure.
                if let f = AXWalk.frame(element) { found.append((element, f)) } else { unreadable = true }
                // The page's own content is not walked.
                return false
            }
            return complete && !unreadable ? .pages(window: window, frame: frame, areas: found) : .unknown
        }
        return .unknown
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

    /// The app's window that the window server calls `title` (and has at `frame`), or nil when that is not sure.
    static func window(of pid: pid_t, title: String, frame: CGRect?) -> AXUIElement? {
        let all = windows(of: pid)
        return WindowTitle.pick(title: title, frame: frame, among: all.map(\.1), frameOf: { AXWalk.frame(all[$0].0) }).map { all[$0].0 }
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
    /// and its role and returns whether to go into its children. Returns false when the walk was cut short. With
    /// `strict`, a role that cannot be read and a tree deeper than the limit also count as cut short: for a caller
    /// that must know it saw everything.
    @discardableResult
    static func walk(_ root: AXUIElement, limit: Int, budget: TimeInterval, strict: Bool = false, visit: (AXUIElement, String) -> Bool) -> Bool {
        var visited = 0
        var cut = false
        let deadline = Date().addingTimeInterval(budget)
        func go(_ e: AXUIElement, depth: Int) {
            guard !cut else { return }
            guard depth < 40 else {
                if strict { cut = true }
                return
            }
            visited += 1
            guard visited < limit, Date() < deadline else {
                cut = true
                return
            }
            var value: AnyObject?
            var role = ""
            switch AXUIElementCopyAttributeValue(e, kAXRoleAttribute as CFString, &value) {
            case .success: role = value as? String ?? ""
            case .noValue, .attributeUnsupported, .notImplemented: break
            default:
                if strict {
                    cut = true
                    return
                }
            }
            guard visit(e, role) else { return }
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
