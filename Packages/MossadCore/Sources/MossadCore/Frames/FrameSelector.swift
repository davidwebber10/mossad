import Foundation

/// Which frames of a shared screen are worth keeping.
public struct FrameRules: Equatable, Sendable {
    /// A frame is new when it differs from the last kept frame by more than this.
    public var changed = 0.015
    /// A frame is stable when the next frame differs from it by this or less.
    public var stable = 0.01
    /// Seconds between two kept frames, at least.
    public var minimumGap: TimeInterval = 10
    /// The stream sends nothing while the picture stays the same, so a pause this long also means stable.
    public var quietGap: TimeInterval = 5
    public var maxPerHour = 240

    public init() {}
}

/// Decides, frame by frame, what to keep: a picture that changed since the last kept one, that stayed (the next
/// frame is nearly the same, or nothing new came), not too soon after the last one, and not too many in an hour.
/// The caller holds one picture at most: the candidate. Times are seconds of the recording.
public struct FrameSelector: Sendable {
    public struct Step: Equatable, Sendable {
        /// Save the held picture as the frame at this time.
        public var keepHeldAt: TimeInterval?
        /// Hold this frame's picture in place of the one held before.
        public var hold = false
    }

    public let rules: FrameRules
    private var lastKept: (thumb: FrameThumb, time: TimeInterval)?
    private var candidate: (thumb: FrameThumb, time: TimeInterval, stable: Bool)?
    private var keptTimes: [TimeInterval] = []

    public init(rules: FrameRules = FrameRules()) {
        self.rules = rules
    }

    public var holdsCandidate: Bool { candidate != nil }

    /// A new picture arrived.
    public mutating func frame(_ thumb: FrameThumb, at time: TimeInterval) -> Step {
        var step = Step()
        if let c = candidate {
            if c.thumb.difference(from: thumb) <= rules.stable {
                candidate?.stable = true
                step.keepHeldAt = keepIfDue(at: time)
                return step
            }
            // The candidate was a picture in motion (a slide transition, a scroll).
            candidate = nil
        }
        if let last = lastKept, last.thumb.difference(from: thumb) <= rules.changed { return step }
        candidate = (thumb, time, false)
        step.hold = true
        return step
    }

    /// No new picture: the window did not change. Call it for each idle frame and on a timer.
    public mutating func quiet(at time: TimeInterval) -> Step {
        guard let c = candidate else { return Step() }
        if time - c.time >= rules.quietGap { candidate?.stable = true }
        return Step(keepHeldAt: keepIfDue(at: time))
    }

    /// The capture stops (a pause, the end of the call): nothing came after the candidate, so it counts as stable.
    public mutating func finish(at time: TimeInterval) -> Step {
        guard candidate != nil else { return Step() }
        candidate?.stable = true
        let step = Step(keepHeldAt: keepIfDue(at: time))
        candidate = nil
        return step
    }

    /// The time the candidate is kept at, when it is stable, far enough from the last kept frame, and the hour has room.
    private mutating func keepIfDue(at now: TimeInterval) -> TimeInterval? {
        guard let c = candidate, c.stable else { return nil }
        // A picture that came too soon after the last kept one waits; it is kept when the gap has passed.
        let time = max(c.time, lastKept.map { $0.time + rules.minimumGap } ?? c.time)
        guard now >= time else { return nil }
        keptTimes.removeAll { time - $0 >= 3600 }
        guard keptTimes.count < rules.maxPerHour else { return nil }
        keptTimes.append(time)
        lastKept = (c.thumb, time)
        candidate = nil
        return time
    }
}
