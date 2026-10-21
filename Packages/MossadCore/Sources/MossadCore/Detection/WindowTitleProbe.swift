import AppKit
import ApplicationServices

/// Reads window titles of a running app through the Accessibility API.
public final class WindowTitleProbe: WindowTitleProbing {
    public init() {}

    public func windowTitles(bundleID: String) -> [String]? {
        guard AXIsProcessTrusted() else { return nil }
        return Self.combine(NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).map { app -> [String]? in
            let element = AXUIElementCreateApplication(app.processIdentifier)
            AXUIElementSetMessagingTimeout(element, 0.5)
            var windows: CFTypeRef?
            switch AXUIElementCopyAttributeValue(element, kAXWindowsAttribute as CFString, &windows) {
            case .success: break
            case .noValue: return []
            default: return nil  // The app did not answer: unknown, not "no windows".
            }
            guard let list = windows as? [AXUIElement] else { return [] }
            var titles: [String] = []
            for window in list {
                var title: CFTypeRef?
                switch AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &title) {
                case .success: if let t = title as? String { titles.append(t) }
                case .noValue, .attributeUnsupported, .invalidUIElement: continue  // The window closed meanwhile.
                default: return nil
                }
            }
            return titles
        })
    }

    /// The titles of all of an app's processes, or nil when any of them could not be read.
    static func combine(_ perProcess: [[String]?]) -> [String]? {
        var all: [String] = []
        for titles in perProcess {
            guard let titles else { return nil }
            all += titles
        }
        return all
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
