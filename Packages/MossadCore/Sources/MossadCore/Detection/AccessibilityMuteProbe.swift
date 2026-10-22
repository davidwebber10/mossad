import AppKit
import ApplicationServices

/// Reads mute-button labels from the call app through Accessibility (the permission Mossad already has).
/// Chrome exposes the Meet page's buttons this way, and Zoom and Teams their own controls and menus.
public final class AccessibilityMuteProbe: MuteProbing {
    static let elementLimit = 4_000

    public init() {}

    public func labels(bundleID: String, platform: Platform) -> [String]? {
        guard AXIsProcessTrusted(),
              let pid = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first?.processIdentifier else { return nil }
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
        var visited = 0
        func walk(_ e: AXUIElement, depth: Int) {
            visited += 1
            guard visited < Self.elementLimit, depth < 40 else { return }
            let role = attribute(e, kAXRoleAttribute) as? String ?? ""
            if role == kAXButtonRole || role == kAXCheckBoxRole || role == kAXMenuItemRole {
                for name in [kAXTitleAttribute, kAXDescriptionAttribute] {
                    if let text = attribute(e, name) as? String, !text.isEmpty {
                        let lower = text.lowercased()
                        if lower.contains("mute") || lower.contains("microphone") { found.append(text) }
                    }
                }
            }
            for child in (attribute(e, kAXChildrenAttribute) as? [AXUIElement]) ?? [] { walk(child, depth: depth + 1) }
        }
        roots.forEach { walk($0, depth: 0) }
        return found
    }

    private func attribute(_ e: AXUIElement, _ name: String) -> AnyObject? {
        var value: AnyObject?
        return AXUIElementCopyAttributeValue(e, name as CFString, &value) == .success ? value : nil
    }
}
