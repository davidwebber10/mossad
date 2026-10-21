import AppKit
import Foundation

/// Reads every tab's URL and title from a running browser via AppleScript.
public final class BrowserTabProbe: BrowserTabProbing {
    public init() {}

    public func tabs(browserBundleID: String) -> [BrowserTab]? {
        guard !NSRunningApplication.runningApplications(withBundleIdentifier: browserBundleID).isEmpty,
              Self.canAutomate(browserBundleID) else { return nil }
        let safari = browserBundleID == "com.apple.Safari"
        let titleProperty = safari ? "name" : "title"
        let activeIndex = safari ? "index of current tab of w" : "active tab index of w"
        // Only the selected tab of the front window counts as active. A short timeout keeps a busy
        // browser from holding the main thread (the default Apple event timeout is two minutes).
        let source = """
        with timeout of 3 seconds
            tell application id "\(browserBundleID)"
                set out to ""
                set wi to 0
                repeat with w in windows
                    set wi to wi + 1
                    set ai to \(activeIndex)
                    set urls to URL of every tab of w
                    set titles to \(titleProperty) of every tab of w
                    repeat with i from 1 to count of urls
                        set flag to "0"
                        if wi = 1 and i = ai then set flag to "1"
                        set out to out & (item i of urls) & tab & (item i of titles) & tab & flag & linefeed
                    end repeat
                end repeat
                return out
            end tell
        end timeout
        """
        let output: String? = onMain {
            var error: NSDictionary?
            let result = NSAppleScript(source: source)?.executeAndReturnError(&error)
            if let error { Log.debug("Tab probe \(browserBundleID) failed: \(error)") }
            return result?.stringValue
        }
        guard let output else { return nil }
        return output.split(separator: "\n").map { line in
            let parts = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            // Titles may contain tabs: the URL is first and the active flag is last.
            let title = parts.count > 2 ? parts[1..<(parts.count - 1)].joined(separator: "\t") : (parts.count > 1 ? parts[1] : "")
            return BrowserTab(url: parts.first ?? "", title: title, isActive: parts.count > 2 && parts.last == "1")
        }
    }
}

extension BrowserTabProbe {
    /// True when Automation for this browser is already allowed. Never shows a prompt, so the probe
    /// cannot wait on a consent dialog nobody answers. Settings asks for the permission.
    static func canAutomate(_ bundleID: String) -> Bool {
        guard let target = NSAppleEventDescriptor(bundleIdentifier: bundleID).aeDesc else { return false }
        return AEDeterminePermissionToAutomateTarget(target, typeWildCard, typeWildCard, false) == noErr
    }
}

/// NSAppleScript must run on the main thread.
func onMain<T>(_ body: () -> T) -> T {
    Thread.isMainThread ? body() : DispatchQueue.main.sync(execute: body)
}
