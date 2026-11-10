import Foundation

/// How the meeting window can be seen now.
public enum WindowSight: Equatable, Sendable {
    case visible
    /// Other windows cover it. Some apps stop drawing then (a browser); some go on (Zoom).
    case covered
    /// Minimized, or on another desktop.
    case hidden
}

/// Tells when the shared screen stopped coming and when it came back, each one time. A window that stays the same
/// sends nothing new but is still there; only a window that cannot be seen (minimized, closed, not found, on another
/// desktop, or covered) with no new picture counts as paused. A covered window that sends a new picture proves that
/// its app draws while covered: from then on, cover is not a pause for it. Times are seconds of the recording.
public struct ScreenLiveness: Equatable, Sendable {
    public enum Change: Equatable, Sendable {
        /// `covered` is true when the only reason is that other windows cover the window.
        case paused(at: TimeInterval, covered: Bool)
        case resumed(at: TimeInterval)
    }

    /// No new picture for this long, with no window to see, is a pause.
    public static let limit: TimeInterval = 12

    private var lastLive: TimeInterval
    private var lastSight: WindowSight?
    public private(set) var isPaused = false
    /// The app was seen to draw its window while it was covered.
    public private(set) var drawsWhileCovered = false
    /// A picture came after a check that said "covered". It is proof only when the next check says so too: a
    /// browser draws at once when it is uncovered, before a check can see that.
    private var pictureWhileCovered = false

    public init(at time: TimeInterval) {
        lastLive = time
    }

    /// The capture starts again after the owner's own pause: the time in between is not a gap.
    public mutating func restart(at time: TimeInterval) {
        if !isPaused { lastLive = time }
        lastSight = nil
        pictureWhileCovered = false
    }

    /// Another window is captured now: what the last one proved does not hold for it.
    public mutating func newWindow() {
        drawsWhileCovered = false
        pictureWhileCovered = false
        lastSight = nil
    }

    /// A new picture came. An idle frame is not one: a covered window sends those too.
    public mutating func frame(at time: TimeInterval) -> Change? {
        lastLive = time
        if lastSight == .covered { pictureWhileCovered = true }
        guard isPaused else { return nil }
        isPaused = false
        return .resumed(at: time)
    }

    /// `sight` is nil when no meeting window is found.
    public mutating func check(at time: TimeInterval, sight: WindowSight?) -> Change? {
        lastSight = sight
        if pictureWhileCovered, sight == .covered { drawsWhileCovered = true }
        pictureWhileCovered = false
        if sight == .visible || (sight == .covered && drawsWhileCovered) {
            // A window that shows the same picture is live, and a window that is back is live again.
            lastLive = time
            guard isPaused else { return nil }
            isPaused = false
            return .resumed(at: time)
        }
        guard !isPaused, time - lastLive >= Self.limit else { return nil }
        isPaused = true
        return .paused(at: lastLive, covered: sight == .covered)
    }
}
