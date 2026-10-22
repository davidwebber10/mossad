import AppKit
import ApplicationServices

/// Reads mute-button labels from the call app through Accessibility (the permission Mossad already has).
/// Chrome exposes the Meet page's buttons this way, and Zoom and Teams their own controls and menus.
public final class AccessibilityMuteProbe: MuteProbing, @unchecked Sendable {
    static let elementLimit = 4_000

    /// The mute controls found by the last full walk, per app. A walk asks the app for up to thousands of
    /// elements (Chrome answers on its UI thread during the call); reading the cached ones is a few requests.
    private var cache: (pid: pid_t, elements: [AXUIElement])?
    private let lock = NSLock()

    public init() {}

    public func labels(bundleID: String, platform: Platform) -> [String]? {
        guard AXIsProcessTrusted(),
              let pid = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first?.processIdentifier else { return nil }
        if let labels = cachedLabels(pid: pid) { return labels }
        let app = AXUIElementCreateApplication(pid)
        // A busy app must not hold up detection.
        AXUIElementSetMessagingTimeout(app, 1)
        let windows = (attribute(app, kAXWindowsAttribute) as? [AXUIElement]) ?? []
        let isBrowser = MeetingMatcher.browserBundleIDs.contains(bundleID)
        let marker = switch platform {
        case .meet: "Meet"
        case .zoom: "Zoom"
        case .teams: "Teams"
        case .inPerson: "\u{0}"
        }
        var roots = isBrowser ? windows.filter { (attribute($0, kAXTitleAttribute) as? String)?.contains(marker) == true } : windows
        // Zoom and Teams also name the action in their menus.
        if !isBrowser, let menu = attribute(app, kAXMenuBarAttribute) { roots.append(menu as! AXUIElement) }
        guard !roots.isEmpty else { return nil }
        var found: [String] = []
        var elements: [AXUIElement] = []
        var visited = 0
        func walk(_ e: AXUIElement, depth: Int) {
            visited += 1
            guard visited < Self.elementLimit, depth < 40 else { return }
            let role = attribute(e, kAXRoleAttribute) as? String ?? ""
            if role == kAXButtonRole || role == kAXCheckBoxRole || role == kAXMenuItemRole {
                for name in [kAXTitleAttribute, kAXDescriptionAttribute] {
                    if let text = attribute(e, name) as? String, !text.isEmpty {
                        let lower = text.lowercased()
                        if lower.contains("mute") || lower.contains("microphone") {
                            found.append(text)
                            if elements.last.map({ !CFEqual($0, e) }) ?? true { elements.append(e) }
                        }
                    }
                }
            }
            for child in (attribute(e, kAXChildrenAttribute) as? [AXUIElement]) ?? [] { walk(child, depth: depth + 1) }
        }
        roots.forEach { walk($0, depth: 0) }
        lock.withLock { cache = elements.isEmpty ? nil : (pid, elements) }
        return found
    }

    /// The labels of the cached controls, or nil when any of them is gone or no longer names the microphone,
    /// so the caller walks the tree again.
    private func cachedLabels(pid: pid_t) -> [String]? {
        guard let cached = lock.withLock({ cache }), cached.pid == pid else { return nil }
        var labels: [String] = []
        for e in cached.elements {
            AXUIElementSetMessagingTimeout(e, 1)
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
