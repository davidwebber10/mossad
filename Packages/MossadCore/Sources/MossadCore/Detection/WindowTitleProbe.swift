import AppKit
import ApplicationServices

/// Reads window titles of a running app through the Accessibility API.
public final class WindowTitleProbe: WindowTitleProbing {
    public init() {}

    public func windowTitles(bundleID: String) -> [String]? {
        guard AXIsProcessTrusted() else { return nil }
        return NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).flatMap { app -> [String] in
            let element = AXUIElementCreateApplication(app.processIdentifier)
            AXUIElementSetMessagingTimeout(element, 0.5)
            var windows: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, kAXWindowsAttribute as CFString, &windows) == .success,
                  let list = windows as? [AXUIElement] else { return [] }
            return list.compactMap { window in
                var title: CFTypeRef?
                guard AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &title) == .success else { return nil }
                return title as? String
            }
        }
    }

    public func isRunning(bundleID: String) -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty
    }

    /// Shows the system Accessibility prompt once if the app is not trusted.
    public static func requestAccess() {
        let key = "AXTrustedCheckOptionPrompt"
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }
}
