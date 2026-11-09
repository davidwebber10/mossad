#if os(macOS)
import AppKit
import ApplicationServices

/// Reads who shares the screen from the call app's own labels, through Accessibility. One walk with a time budget;
/// the screen capture asks at most once for each new share session, never for each frame. Nil when the app shows
/// no name, when Accessibility is not allowed, or when the walk was cut short before it found one.
public struct PresenterProbe: Sendable {
    static let elementLimit = 4_000
    static let budget: TimeInterval = 1

    public init() {
        AccessibilityTimeout.apply()
    }

    public func presenter(bundleID: String, platform: Platform, meetingID: String?) -> String? {
        guard AXIsProcessTrusted() else { return nil }
        let isBrowser: Bool = switch MeetingMatcher.appKind(bundleID: bundleID) {
        case .browser, .unreadableBrowser: true
        default: false
        }
        var labels: [String] = []
        var roots: [AXUIElement] = []
        for app in NSRunningApplication.runningApplications(withBundleIdentifier: bundleID) {
            let element = AXUIElementCreateApplication(app.processIdentifier)
            AXUIElementSetMessagingTimeout(element, Float(Self.budget))
            var value: AnyObject?
            guard AXUIElementCopyAttributeValue(element, kAXWindowsAttribute as CFString, &value) == .success,
                  let windows = value as? [AXUIElement] else { continue }
            let titles = windows.map { Self.text($0, kAXTitleAttribute) ?? "" }
            if isBrowser {
                roots += AccessibilityMuteProbe.callWindows(titles: titles, platform: platform, meetingID: meetingID).map { windows[$0] }
            } else {
                // Zoom names the presenter in the title of the share window.
                labels += titles
                roots += windows
            }
        }
        if let name = PresenterLabel.name(in: labels) { return name }

        var visited = 0
        var stopped = false
        let deadline = Date().addingTimeInterval(Self.budget)
        func walk(_ e: AXUIElement, depth: Int) {
            guard !stopped, depth < 40 else { return }
            visited += 1
            guard visited < Self.elementLimit, Date() < deadline else {
                stopped = true
                return
            }
            for name in [kAXTitleAttribute, kAXDescriptionAttribute, kAXValueAttribute] {
                if let text = Self.text(e, name), text.count <= 120, PresenterLabel.mayName(text) { labels.append(text) }
            }
            var children: AnyObject?
            switch AXUIElementCopyAttributeValue(e, kAXChildrenAttribute as CFString, &children) {
            case .success: for child in (children as? [AXUIElement]) ?? [] { walk(child, depth: depth + 1) }
            case .noValue, .attributeUnsupported, .invalidUIElement, .notImplemented: break
            default: stopped = true  // The app does not answer: do not hold it up.
            }
        }
        roots.forEach { walk($0, depth: 0) }
        return PresenterLabel.name(in: labels)
    }

    private static func text(_ e: AXUIElement, _ name: String) -> String? {
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(e, name as CFString, &value) == .success, let text = value as? String, !text.isEmpty else { return nil }
        return text
    }
}
#endif
