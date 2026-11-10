#if os(macOS)
// Call detection and capture use macOS-only APIs; the iPhone app reads meetings only.
import CoreAudio
import Foundation

/// A process known to Core Audio.
public struct AudioProcess: Equatable, Sendable {
    public var objectID: AudioObjectID
    public var pid: pid_t
    public var bundleID: String
    /// Nil when the state could not be read, or was not read: unknown is never "not running".
    public var isRunningInput: Bool?
    public var isRunningOutput: Bool?

    public init(objectID: AudioObjectID, pid: pid_t, bundleID: String, isRunningInput: Bool?, isRunningOutput: Bool?) {
        self.objectID = objectID
        self.pid = pid
        self.bundleID = bundleID
        self.isRunningInput = isRunningInput
        self.isRunningOutput = isRunningOutput
    }
}

public protocol MicUsageProbing: AnyObject {
    func processes() -> [AudioProcess]
    /// The same list for one detection tick; nil when the list itself could not be read. Outside a call the probe
    /// may skip states that cannot matter (see `MicUsageProbe`).
    func scan(callActive: Bool) -> [AudioProcess]?
    func forget()
}

public extension MicUsageProbing {
    func scan(callActive: Bool) -> [AudioProcess]? { processes() }
    /// Drops what the probe remembers about the process objects, for a new start of detection.
    func forget() {}
}

public protocol BrowserTabProbing: AnyObject {
    /// `nil` when the tabs cannot be read (browser not running or Automation denied).
    func tabs(browserBundleID: String) -> [BrowserTab]?
    /// True when the owner has not allowed Automation for this browser, so its tabs stay unknown.
    func automationDenied(browserBundleID: String) -> Bool
}

public extension BrowserTabProbing {
    func automationDenied(browserBundleID: String) -> Bool { false }
}

/// Labels of the call app's controls (buttons, menu items) that can show the mute state. Nil when unreadable or
/// when the read was cut short; an empty list only after a full, clean read that found the call's window.
public protocol MuteProbing: AnyObject {
    /// `meetingID` narrows a browser to the window of the current call when its title shows the meeting code.
    func labels(bundleID: String, platform: Platform, meetingID: String?) -> [String]?
    /// The same, with how often a full look at the app is worth its cost now.
    func labels(bundleID: String, platform: Platform, meetingID: String?, pace: MuteReadPace) -> [String]?
}

/// How a probe spaces its costly full reads of the call app.
public enum MuteReadPace: Sendable {
    /// Full reads that do not pay off are spaced further and further apart.
    case backoff
    /// The last known state is "muted": a full read at least each 5 s, so the button is found again inside the
    /// time after which "muted" turns into "unmuted".
    case whileMuted
    /// The caller asks seldom (the idle Teams check, each 10 s): each ask may read, and none counts.
    case callerPaced
}

public extension MuteProbing {
    func labels(bundleID: String, platform: Platform, meetingID: String?, pace: MuteReadPace) -> [String]? {
        labels(bundleID: bundleID, platform: platform, meetingID: meetingID)
    }
}

public protocol WindowTitleProbing: AnyObject {
    /// `nil` when window titles cannot be read (Accessibility not granted, or any copy of the app did not answer).
    func windowTitles(bundleID: String) -> [String]?
    /// The titles of the copies of the app that answered; nil only when none did. For "does any copy show a
    /// meeting?", where one good answer is enough.
    func answeredWindowTitles(bundleID: String) -> [String]?
    func isRunning(bundleID: String) -> Bool
}

public extension WindowTitleProbing {
    func answeredWindowTitles(bundleID: String) -> [String]? { windowTitles(bundleID: bundleID) }
}
#endif
