#if os(macOS)
// Call detection and capture use macOS-only APIs; the iPhone app reads meetings only.
import AppKit
import ApplicationServices

/// Reads window titles of a running app through the Accessibility API.
public final class WindowTitleProbe: WindowTitleProbing {
    public init() {
        AccessibilityTimeout.apply()
    }

    public func windowTitles(bundleID: String) -> [String]? {
        guard AXIsProcessTrusted() else { return nil }
        return Self.combine(perProcess(bundleID))
    }

    public func answeredWindowTitles(bundleID: String) -> [String]? {
        guard AXIsProcessTrusted() else { return nil }
        return Self.answered(perProcess(bundleID))
    }

    private func perProcess(_ bundleID: String) -> [[String]?] {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).map { app -> [String]? in
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
                AXUIElementSetMessagingTimeout(window, 0.5)
                var title: CFTypeRef?
                switch AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &title) {
                case .success: if let t = title as? String { titles.append(t) }
                case .noValue, .attributeUnsupported, .invalidUIElement: continue  // The window closed meanwhile.
                default: return nil
                }
            }
            return titles
        }
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

    /// The titles of the processes that answered, or nil when none did.
    static func answered(_ perProcess: [[String]?]) -> [String]? {
        let read = perProcess.compactMap { $0 }
        return read.isEmpty ? nil : read.flatMap { $0 }
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

/// A timeout set on one element covers that element object only; the elements reached from it (windows, their
/// children) use the process-wide default of about 6 s. Setting it on the system-wide element changes that default,
/// so a busy app cannot hold the detection queue for 6 s on each request.
enum AccessibilityTimeout {
    static let seconds: Float = 1
    private static let once: Void = {
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), seconds)
    }()

    static func apply() { _ = once }
}
#endif
