import Foundation

/// Whether the person is muted in the call app, read from the labels of its mute button.
/// The button names the action it would take: "Turn on microphone" shows up while muted.
public enum MuteState {
    /// nil when no known label is present, or when the labels disagree (a second meeting's waiting page, a menu
    /// item): unknown never mutes the recording.
    public static func from(labels: [String], platform: Platform) -> Bool? {
        let (muted, unmuted) = controls(in: labels, platform: platform)
        guard muted != unmuted else { return nil }
        return muted
    }

    /// True when the labels hold the owner's own mute or unmute control. "Microphone settings" or a participant's
    /// mic sign does not count.
    public static func hasControl(labels: [String], platform: Platform) -> Bool {
        let (muted, unmuted) = controls(in: labels, platform: platform)
        return muted || unmuted
    }

    /// Whether the controls of a walk are worth a place in the cache. A full walk found all there is. A cut walk
    /// found only a part: without the owner's own control, cached reads would answer "unknown" for the rest of
    /// the call and no walk would look for the button again.
    public static func keepsControls(labels: [String], cut: Bool, platform: Platform) -> Bool {
        !labels.isEmpty && (!cut || hasControl(labels: labels, platform: platform))
    }

    private static func controls(in labels: [String], platform: Platform) -> (muted: Bool, unmuted: Bool) {
        let lower = labels.map { $0.lowercased() }
        func has(_ prefixes: String...) -> Bool { lower.contains { l in prefixes.contains { l.hasPrefix($0) } } }
        let muted: Bool
        let unmuted: Bool
        switch platform {
        case .meet:
            muted = has("turn on microphone")
            unmuted = has("turn off microphone")
        case .zoom:
            muted = has("unmute audio", "unmute my audio")
            unmuted = has("mute audio", "mute my audio")
        case .inPerson:
            return (false, false)
        case .teams:
            // "Unmute mic" / "Mute mic" in the new Teams app, "Unmute (⌘+Shift+M)" / "Mute (…)" in the old one.
            // Participant tiles ("Myself video, …, Unmuted") do not start with either word.
            muted = has("unmute")
            unmuted = has("mute")
        }
        return (muted, unmuted)
    }
}

/// The owner's mute state over a call, from a stream of readings. A reading can be unknown (the call's tab is not
/// selected, the app is busy). Unknown after "unmuted" changes nothing; unknown after "muted" turns into unmuted
/// once it lasts, so the mic is never treated as muted on an old reading: record too much, never too little.
public struct MuteTracker: Sendable {
    /// While unmuted (or unknown), a mute is seen within this time.
    public static let checkInterval: TimeInterval = 3
    /// While muted, an unmute is seen within this time, so little of the owner's first words is marked as muted.
    public static let mutedCheckInterval: TimeInterval = 1
    /// "Muted" that cannot be read again for longer than this becomes "unmuted".
    public static let unknownLimit: TimeInterval = 10

    public private(set) var muted: Bool?
    /// The last reading that saw "muted": a mute span ends here when the state became unknown.
    public private(set) var lastMutedSeen: Date?
    private var lastCheck = Date.distantPast

    public init() {}

    public func isDue(at time: Date) -> Bool {
        // A little slack, so a 1 s timer that fires a few milliseconds early still reads each time.
        time.timeIntervalSince(lastCheck) >= (muted == true ? Self.mutedCheckInterval : Self.checkInterval) - 0.1
    }

    /// Takes one reading; returns the new state when it changed.
    public mutating func record(_ state: Bool?, at time: Date) -> Bool? {
        lastCheck = time
        if state == true { lastMutedSeen = time }
        if let state {
            guard state != muted else { return nil }
            muted = state
            return state
        }
        if muted == true, let seen = lastMutedSeen, time.timeIntervalSince(seen) > Self.unknownLimit {
            muted = false
            return false
        }
        return nil
    }
}
