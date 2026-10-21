import AppKit
import Foundation

/// Reads every tab's URL and title from a running browser via AppleScript.
public final class BrowserTabProbe: BrowserTabProbing {
    public init() {}

    public func tabs(browserBundleID: String) -> [BrowserTab]? {
        guard !NSRunningApplication.runningApplications(withBundleIdentifier: browserBundleID).isEmpty else { return nil }
        let titleProperty = browserBundleID == "com.apple.Safari" ? "name" : "title"
        let source = """
        tell application id "\(browserBundleID)"
            set out to ""
            repeat with w in windows
                repeat with t in tabs of w
                    set out to out & (URL of t) & tab & (\(titleProperty) of t) & linefeed
                end repeat
            end repeat
            return out
        end tell
        """
        let output: String? = onMain {
            var error: NSDictionary?
            let result = NSAppleScript(source: source)?.executeAndReturnError(&error)
            if let error { Log.debug("Tab probe \(browserBundleID) failed: \(error)") }
            return result?.stringValue
        }
        guard let output else { return nil }
        return output.split(separator: "\n").map { line in
            let parts = line.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false)
            return BrowserTab(url: String(parts.first ?? ""), title: parts.count > 1 ? String(parts[1]) : "")
        }
    }
}

/// NSAppleScript must run on the main thread.
func onMain<T>(_ body: () -> T) -> T {
    Thread.isMainThread ? body() : DispatchQueue.main.sync(execute: body)
}
