import Foundation

/// Tells when the shared screen stopped coming and when it came back, each one time. A window that stays the same
/// sends nothing new but is still there; only a window that is not on screen (minimized, closed, not found) with no
/// frames counts as paused. Times are seconds of the recording.
public struct ScreenLiveness: Equatable, Sendable {
    public enum Change: Equatable, Sendable {
        case paused(at: TimeInterval)
        case resumed(at: TimeInterval)
    }

    /// No frame for this long, with no window on screen, is a pause.
    public static let limit: TimeInterval = 12

    private var lastLive: TimeInterval
    public private(set) var isPaused = false

    public init(at time: TimeInterval) {
        lastLive = time
    }

    /// The capture starts again after the owner's own pause: the time in between is not a gap.
    public mutating func restart(at time: TimeInterval) {
        if !isPaused { lastLive = time }
    }

    /// A frame came (new or idle).
    public mutating func frame(at time: TimeInterval) -> Change? {
        lastLive = time
        guard isPaused else { return nil }
        isPaused = false
        return .resumed(at: time)
    }

    /// `windowOnScreen` is nil when no meeting window is found.
    public mutating func check(at time: TimeInterval, windowOnScreen: Bool?) -> Change? {
        if windowOnScreen == true {
            // A window that shows the same picture is live, and a window that is back is live again.
            lastLive = time
            guard isPaused else { return nil }
            isPaused = false
            return .resumed(at: time)
        }
        guard !isPaused, time - lastLive >= Self.limit else { return nil }
        isPaused = true
        return .paused(at: lastLive)
    }
}
