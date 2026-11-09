import Foundation

/// An app that uses the mic like a call while Mossad cannot confirm a meeting, so nothing records.
public struct UnconfirmedCall: Equatable, Sendable {
    public enum Reason: String, Sendable {
        /// The browser's tabs or the app's windows could not be read (two copies of the browser, a browser Mossad
        /// cannot read, or Accessibility is off).
        case cannotSeeMeeting
        /// Automation for this browser is not allowed, so Mossad cannot read its tabs.
        case noAutomation
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
    /// A mic gap shorter than this is the same session, so one call warns once.
    public var sameSessionGap: TimeInterval = 60

    private struct Session { var first: Date; var last: Date; var warned: Bool }
    private var sessions: [String: Session] = [:]
    /// "Not a call" (or a warning that must come only once) for an app and a reason, until a time.
    private var dismissed: [String: Date] = [:]

    public init() {}

    public mutating func update(at time: Date, suspects: [UnconfirmedCall], inCall: Bool) -> UnconfirmedCall? {
        guard !inCall else {
            sessions = [:]
            return nil
        }
        var warning: UnconfirmedCall?
        for suspect in suspects {
            if let until = dismissed[Self.key(suspect)], until > time { continue }
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

    /// No more warnings for this app and reason until a time.
    public mutating func dismiss(_ call: UnconfirmedCall, until: Date) {
        dismissed[Self.key(call)] = until
    }

    /// Forgets the mic sessions (Mossad was off), but keeps the owner's "Not a call".
    public mutating func reset() {
        sessions = [:]
    }

    private static func key(_ call: UnconfirmedCall) -> String { "\(call.bundleID)|\(call.reason.rawValue)" }
}

/// The owner's "Not a call" answers, kept across restarts: no warning for the same app and reason until a time.
public struct UnconfirmedDismissals: Codable, Equatable, Sendable {
    struct Entry: Codable, Equatable, Sendable {
        var bundleID: String
        var reason: String
        var until: Date
    }

    var entries: [Entry] = []

    public init() {}

    public init(data: Data?) {
        self = data.flatMap { try? JSONDecoder().decode(UnconfirmedDismissals.self, from: $0) } ?? UnconfirmedDismissals()
    }

    public var data: Data? { try? JSONEncoder().encode(self) }

    public mutating func add(_ call: UnconfirmedCall, until: Date, now: Date) {
        entries.removeAll { $0.until <= now || ($0.bundleID == call.bundleID && $0.reason == call.reason.rawValue) }
        entries.append(Entry(bundleID: call.bundleID, reason: call.reason.rawValue, until: until))
    }

    /// The answers that still hold.
    public func active(at now: Date) -> [(call: UnconfirmedCall, until: Date)] {
        entries.compactMap { e in
            guard e.until > now, let reason = UnconfirmedCall.Reason(rawValue: e.reason) else { return nil }
            return (UnconfirmedCall(bundleID: e.bundleID, platform: nil, reason: reason), e.until)
        }
    }

    /// "Not a call" holds for the rest of the day.
    public static func endOfDay(after now: Date, calendar: Calendar = .current) -> Date {
        calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now)) ?? now.addingTimeInterval(86_400)
    }
}
