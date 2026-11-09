#if os(macOS)
// Call detection and capture use macOS-only APIs; the iPhone app reads meetings only.
import AppKit
import ApplicationServices

/// Reads mute-button labels from the call app through Accessibility (the permission Mossad already has).
/// Chrome exposes the Meet page's buttons this way, and Zoom and Teams their own controls and menus.
public final class AccessibilityMuteProbe: MuteProbing, @unchecked Sendable {
    static let elementLimit = 4_000
    /// A walk that takes longer than this is cut, and its answer is unknown.
    static let walkBudget: TimeInterval = 1

    /// The mute controls found by the last full walk, per app and call. A walk asks the app for up to thousands of
    /// elements (Chrome answers on its UI thread during the call); reading the cached ones is a few requests.
    private var cache: (key: String, elements: [AXUIElement])?
    private let lock = NSLock()

    public init() {
        AccessibilityTimeout.apply()
    }

    public func labels(bundleID: String, platform: Platform, meetingID: String?) -> [String]? {
        guard AXIsProcessTrusted() else { return nil }
        // Every copy of the app: a second, hidden copy of Chrome (a test tool's) has the same ID.
        let pids = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).map(\.processIdentifier)
        guard !pids.isEmpty else { return nil }
        let key = "\(bundleID)|\(meetingID ?? "")|\(pids.sorted())"
        if let labels = cachedLabels(key: key) { return labels }

        let isBrowser: Bool = switch MeetingMatcher.appKind(bundleID: bundleID) {
        case .browser, .unreadableBrowser: true
        default: false
        }
        var roots: [AXUIElement] = []
        var anyCopyFailed = false
        for pid in pids {
            let app = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(app, Float(Self.walkBudget))
            var value: AnyObject?
            let result = AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value)
            guard result == .success || result == .noValue else {
                anyCopyFailed = true
                continue
            }
            let windows = (value as? [AXUIElement]) ?? []
            if isBrowser {
                let titles = windows.map { (attribute($0, kAXTitleAttribute) as? String) ?? "" }
                roots += Self.callWindows(titles: titles, platform: platform, meetingID: meetingID).map { windows[$0] }
            } else {
                roots += windows
                // Zoom and Teams also name the action in their menus.
                if let menu = attribute(app, kAXMenuBarAttribute) { roots.append(menu as! AXUIElement) }
            }
        }
        // No window of the call: unknown, never "the controls are gone".
        guard !roots.isEmpty else { return nil }

        var found: [String] = []
        var elements: [AXUIElement] = []
        var visited = 0
        var cut = false
        let deadline = Date().addingTimeInterval(Self.walkBudget)
        func read(_ e: AXUIElement, _ name: String) -> AnyObject? {
            var value: AnyObject?
            switch AXUIElementCopyAttributeValue(e, name as CFString, &value) {
            case .success: return value
            case .noValue, .attributeUnsupported, .invalidUIElement, .notImplemented: return nil
            default:
                cut = true  // The app did not answer: what was not read is unknown.
                return nil
            }
        }
        func walk(_ e: AXUIElement, depth: Int) {
            guard !cut else { return }
            visited += 1
            guard visited < Self.elementLimit, Date() < deadline else {
                cut = true
                return
            }
            guard depth < 40 else { return }
            let role = read(e, kAXRoleAttribute) as? String ?? ""
            if role == kAXButtonRole || role == kAXCheckBoxRole || role == kAXMenuItemRole {
                for name in [kAXTitleAttribute, kAXDescriptionAttribute] {
                    if let text = read(e, name) as? String, !text.isEmpty {
                        let lower = text.lowercased()
                        if lower.contains("mute") || lower.contains("microphone") {
                            found.append(text)
                            if elements.last.map({ !CFEqual($0, e) }) ?? true { elements.append(e) }
                        }
                    }
                }
            }
            for child in (read(e, kAXChildrenAttribute) as? [AXUIElement]) ?? [] { walk(child, depth: depth + 1) }
        }
        roots.forEach { walk($0, depth: 0) }
        lock.withLock { cache = elements.isEmpty || cut ? nil : (key, elements) }
        // A cut walk, or a copy that did not answer, still proves the labels it found, but not their absence.
        if found.isEmpty, cut || anyCopyFailed { return nil }
        return found
    }

    /// The browser windows that can hold the current call's controls. A window whose title shows the meeting code
    /// wins, so a second meeting's waiting page in another window does not count. Without it, every window that
    /// looks like the call app counts, including Meet's picture-in-picture window.
    static func callWindows(titles: [String], platform: Platform, meetingID: String?) -> [Int] {
        let matches = titles.indices.filter { i in
            let title = titles[i]
            switch platform {
            case .meet: return MeetingMatcher.meetWindowIsMeeting(title) || title.lowercased().contains("meet.google.com")
            case .zoom: return title.contains("Zoom")
            case .teams: return title.contains("Teams")
            case .inPerson: return false
            }
        }
        if let meetingID, !meetingID.isEmpty {
            let own = matches.filter { titles[$0].lowercased().contains(meetingID.lowercased()) }
            if !own.isEmpty { return own }
        }
        return matches
    }

    /// The labels of the cached controls, or nil when any of them is gone or no longer names the microphone,
    /// so the caller walks the tree again.
    private func cachedLabels(key: String) -> [String]? {
        guard let cached = lock.withLock({ cache }), cached.key == key else { return nil }
        var labels: [String] = []
        for e in cached.elements {
            AXUIElementSetMessagingTimeout(e, Float(Self.walkBudget))
            var any = false
            for name in [kAXTitleAttribute, kAXDescriptionAttribute] {
                var value: AnyObject?
                let result = AXUIElementCopyAttributeValue(e, name as CFString, &value)
                if result == .invalidUIElement || result == .cannotComplete { return invalidate() }
                if let text = value as? String, !text.isEmpty {
                    let lower = text.lowercased()
                    if lower.contains("mute") || lower.contains("microphone") { labels.append(text); any = true }
                }
            }
            if !any { return invalidate() }
        }
        return labels
    }

    private func invalidate() -> [String]? {
        lock.withLock { cache = nil }
        return nil
    }

    private func attribute(_ e: AXUIElement, _ name: String) -> AnyObject? {
        var value: AnyObject?
        return AXUIElementCopyAttributeValue(e, name as CFString, &value) == .success ? value : nil
    }
}
#endif
