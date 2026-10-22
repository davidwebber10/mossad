#if os(macOS)
// Call detection and capture use macOS-only APIs; the iPhone app reads meetings only.
import CoreAudio
import Foundation

/// A process known to Core Audio.
public struct AudioProcess: Equatable, Sendable {
    public var objectID: AudioObjectID
    public var pid: pid_t
    public var bundleID: String
    public var isRunningInput: Bool
    public var isRunningOutput: Bool

    public init(objectID: AudioObjectID, pid: pid_t, bundleID: String, isRunningInput: Bool, isRunningOutput: Bool) {
        self.objectID = objectID
        self.pid = pid
        self.bundleID = bundleID
        self.isRunningInput = isRunningInput
        self.isRunningOutput = isRunningOutput
    }
}

public struct BrowserTab: Equatable, Sendable {
    public var url: String
    public var title: String
    /// The selected tab of its window.
    public var isActive: Bool

    public init(url: String, title: String, isActive: Bool = false) {
        self.url = url
        self.title = title
        self.isActive = isActive
    }
}

public protocol MicUsageProbing: AnyObject {
    func processes() -> [AudioProcess]
}

public protocol BrowserTabProbing: AnyObject {
    /// `nil` when the tabs cannot be read (browser not running or Automation denied).
    func tabs(browserBundleID: String) -> [BrowserTab]?
}

/// Labels of the call app's controls (buttons, menu items) that can show the mute state; nil when unreadable.
public protocol MuteProbing: AnyObject {
    func labels(bundleID: String, platform: Platform) -> [String]?
}

public protocol WindowTitleProbing: AnyObject {
    /// `nil` when window titles cannot be read (Accessibility not granted).
    func windowTitles(bundleID: String) -> [String]?
    func isRunning(bundleID: String) -> Bool
}
#endif
