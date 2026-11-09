import Foundation

/// An app that uses the mic like a call while Mossad cannot confirm a meeting, so nothing records.
public struct UnconfirmedCall: Equatable, Sendable {
    public enum Reason: String, Sendable {
        /// The browser's tabs or the app's windows could not be read (no permission, or two copies of the browser).
        case cannotSeeMeeting
        /// A meeting tab is open but another tab is selected, and a background tab never starts a call.
        case meetingTabNotSelected
        /// The Zoom app uses the mic but shows no window Mossad knows as a meeting.
        case noMeetingWindow
    }

    public var bundleID: String
    /// The meeting app when Mossad can tell, such as a Meet tab in the background.
    public var platform: Platform?
    public var reason: Reason

    public init(bundleID: String, platform: Platform?, reason: Reason) {
        self.bundleID = bundleID
        self.platform = platform
        self.reason = reason
    }
}

/// Decides when to warn the owner that a call may be going unrecorded: once per mic session, after the mic stayed
/// on for a while, so a short dictation stays quiet. Detection must never fail without a word.
public struct UnconfirmedCallWatch: Sendable {
    public var warnAfter: TimeInterval = 10
    /// A mic gap shorter than this is the same session, so one call warns once (also after "Not a call").
    public var sameSessionGap: TimeInterval = 60

    private struct Session { var first: Date; var last: Date; var warned: Bool }
    private var sessions: [String: Session] = [:]

    public init() {}

    public mutating func update(at time: Date, suspects: [UnconfirmedCall], inCall: Bool) -> UnconfirmedCall? {
        guard !inCall else {
            sessions = [:]
            return nil
        }
        var warning: UnconfirmedCall?
        for suspect in suspects {
            var s = sessions[suspect.bundleID] ?? Session(first: time, last: time, warned: false)
            if time.timeIntervalSince(s.last) > sameSessionGap { s = Session(first: time, last: time, warned: false) }
            s.last = time
            if !s.warned, time.timeIntervalSince(s.first) >= warnAfter, warning == nil {
                s.warned = true
                warning = suspect
            }
            sessions[suspect.bundleID] = s
        }
        return warning
    }
}
