import Foundation

/// One meeting-capable app as seen in a detection tick.
public struct MeetingCandidate: Equatable, Sendable {
    public var platform: Platform
    public var bundleID: String
    public var micActive: Bool
    /// `true` when a meeting window/tab is open, `false` when it is gone, `nil` when unknown.
    public var meetingPresent: Bool?
    /// The presence sign alone proves a call (the Zoom app's meeting window, the Teams app's call controls), so the
    /// call starts and goes on without the mic: these apps release the mic while the owner is muted.
    public var presenceIsSure: Bool

    public init(platform: Platform, bundleID: String, micActive: Bool, meetingPresent: Bool?, presenceIsSure: Bool = false) {
        self.platform = platform
        self.bundleID = bundleID
        self.micActive = micActive
        self.meetingPresent = meetingPresent
        self.presenceIsSure = presenceIsSure
    }

    var surelyPresent: Bool { presenceIsSure && meetingPresent == true }
}

public struct DetectionSnapshot: Sendable {
    public var time: Date
    public var candidates: [MeetingCandidate]

    public init(time: Date, candidates: [MeetingCandidate]) {
        self.time = time
        self.candidates = candidates
    }
}

public enum DetectorEvent: Equatable, Sendable {
    case started(platform: Platform, bundleID: String, at: Date)
    /// `trimTo` is the last mic activity when the call ended by the mic-idle fallback.
    case ended(at: Date, trimTo: Date?)
}

/// Decides when a call starts and ends from a stream of snapshots.
public struct CallDetector: Sendable {
    public struct Config: Sendable {
        public var goneConfirmTicks = 2
        public var micIdleFallback: TimeInterval = 180
        /// Meet keeps the mic open while muted, and its page after you leave keeps the meeting title,
        /// so a stopped mic is the sign that you left. Short: a call ended too early by a brief mic gap is
        /// joined again by the automatic continuation when it restarts.
        public var meetMicIdle: TimeInterval = 6
        /// A call started by the owner's Record has a guessed platform (a Zoom or Teams web call can look like
        /// Meet), so the short Meet rule is not used for it.
        public var forcedMicIdle: TimeInterval = 30
        /// While the call app still uses the mic, a missing meeting (a browser that answered with no Meet tab) must
        /// last this long before it ends the call: brief empty answers once cut a meeting into discarded pieces.
        /// Leaving releases the mic, which ends the call within seconds anyway.
        public var goneWithMicGrace: TimeInterval = 30
        /// "Gone" readings further apart than this (unknown in between) do not add up: the grace is for a
        /// meeting that stays missing, not for two stray answers minutes apart.
        public var goneReadingGap: TimeInterval = 10
        public init() {}
    }

    private let config: Config
    public private(set) var currentBundleID: String?
    private var currentPlatform: Platform?
    /// The last time the mic was in use, or a sure presence sign showed the call.
    private var lastAlive: Date?
    private var goneCount = 0
    private var goneSince: Date?
    private var lastGone: Date?
    /// Started by the owner's Record on a warning: the meeting was never seen, so only the mic can end the call.
    private var forced = false

    public init(config: Config = .init()) {
        self.config = config
    }

    public var isInCall: Bool { currentBundleID != nil }

    /// Starts a call now, for the owner's Record on a warning. Nil during a call.
    public mutating func force(platform: Platform, bundleID: String, at time: Date) -> DetectorEvent? {
        guard currentBundleID == nil else { return nil }
        begin(platform: platform, bundleID: bundleID, at: time)
        forced = true
        return .started(platform: platform, bundleID: bundleID, at: time)
    }

    public mutating func process(_ snapshot: DetectionSnapshot) -> DetectorEvent? {
        guard let bundleID = currentBundleID else {
            guard let c = snapshot.candidates.first(where: { ($0.micActive && $0.meetingPresent != false) || $0.surelyPresent })
            else { return nil }
            begin(platform: c.platform, bundleID: c.bundleID, at: snapshot.time)
            return .started(platform: c.platform, bundleID: c.bundleID, at: snapshot.time)
        }

        let candidate = snapshot.candidates.first { $0.bundleID == bundleID }
        if forced {
            // The meeting was never seen, so its absence says nothing.
        } else if candidate == nil || candidate?.meetingPresent == false {
            if let last = lastGone, snapshot.time.timeIntervalSince(last) > config.goneReadingGap {
                goneCount = 0
                goneSince = nil
            }
            lastGone = snapshot.time
            goneCount += 1
            if goneSince == nil { goneSince = snapshot.time }
            let micInUse = candidate?.micActive == true
            let lasted = snapshot.time.timeIntervalSince(goneSince ?? snapshot.time) >= config.goneWithMicGrace
            if goneCount >= config.goneConfirmTicks, !micInUse || lasted { return end(at: snapshot.time, trimTo: nil) }
        } else if candidate?.meetingPresent == true {
            goneCount = 0
            goneSince = nil
            lastGone = nil
        }  // Unknown (nil) leaves the count as it was.

        // A sure sign keeps the call while the app has released the mic (the owner is muted). Only an unknown or
        // weak sign lets the mic-idle fallback end it.
        if candidate?.micActive == true || (!forced && candidate?.surelyPresent == true) {
            lastAlive = snapshot.time
        } else if let last = lastAlive, snapshot.time.timeIntervalSince(last) >= micIdleLimit {
            return end(at: snapshot.time, trimTo: last)
        }
        return nil
    }

    private var micIdleLimit: TimeInterval {
        let limit = currentPlatform == .meet ? config.meetMicIdle : config.micIdleFallback
        return forced ? max(limit, config.forcedMicIdle) : limit
    }

    private mutating func begin(platform: Platform, bundleID: String, at time: Date) {
        currentBundleID = bundleID
        currentPlatform = platform
        lastAlive = time
        goneCount = 0
        goneSince = nil
        lastGone = nil
        forced = false
    }

    private mutating func end(at time: Date, trimTo: Date?) -> DetectorEvent {
        currentBundleID = nil
        currentPlatform = nil
        lastAlive = nil
        goneCount = 0
        goneSince = nil
        lastGone = nil
        forced = false
        return .ended(at: time, trimTo: trimTo)
    }
}
