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

    public init(url: String, title: String) {
        self.url = url
        self.title = title
    }
}

public protocol MicUsageProbing: AnyObject {
    func processes() -> [AudioProcess]
}

public protocol BrowserTabProbing: AnyObject {
    /// `nil` when the tabs cannot be read (browser not running or Automation denied).
    func tabs(browserBundleID: String) -> [BrowserTab]?
}

public protocol WindowTitleProbing: AnyObject {
    /// `nil` when window titles cannot be read (Accessibility not granted).
    func windowTitles(bundleID: String) -> [String]?
}
