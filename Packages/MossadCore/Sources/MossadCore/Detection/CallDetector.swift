import Foundation

/// One meeting-capable app as seen in a detection tick.
public struct MeetingCandidate: Equatable, Sendable {
    public var platform: Platform
    public var bundleID: String
    public var micActive: Bool
    /// `true` when a meeting window/tab is open, `false` when it is gone, `nil` when unknown.
    public var meetingPresent: Bool?

    public init(platform: Platform, bundleID: String, micActive: Bool, meetingPresent: Bool?) {
        self.platform = platform
        self.bundleID = bundleID
        self.micActive = micActive
        self.meetingPresent = meetingPresent
    }
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
        /// so a stopped mic is the sign that you left.
        public var meetMicIdle: TimeInterval = 20
        public init() {}
    }

    private let config: Config
    public private(set) var currentBundleID: String?
    private var currentPlatform: Platform?
    private var lastMicActive: Date?
    private var goneCount = 0

    public init(config: Config = .init()) {
        self.config = config
    }

    public var isInCall: Bool { currentBundleID != nil }

    public mutating func process(_ snapshot: DetectionSnapshot) -> DetectorEvent? {
        guard let bundleID = currentBundleID else {
            guard let c = snapshot.candidates.first(where: { $0.micActive && $0.meetingPresent != false }) else { return nil }
            currentBundleID = c.bundleID
            currentPlatform = c.platform
            lastMicActive = snapshot.time
            goneCount = 0
            return .started(platform: c.platform, bundleID: c.bundleID, at: snapshot.time)
        }

        let candidate = snapshot.candidates.first { $0.bundleID == bundleID }
        if candidate == nil || candidate?.meetingPresent == false {
            goneCount += 1
            if goneCount >= config.goneConfirmTicks { return end(at: snapshot.time, trimTo: nil) }
        } else if candidate?.meetingPresent == true {
            goneCount = 0
        }  // Unknown (nil) leaves the count as it was.

        if candidate?.micActive == true {
            lastMicActive = snapshot.time
        } else if let last = lastMicActive,
                  snapshot.time.timeIntervalSince(last) >= (currentPlatform == .meet ? config.meetMicIdle : config.micIdleFallback) {
            return end(at: snapshot.time, trimTo: last)
        }
        return nil
    }

    private mutating func end(at time: Date, trimTo: Date?) -> DetectorEvent {
        currentBundleID = nil
        currentPlatform = nil
        lastMicActive = nil
        goneCount = 0
        return .ended(at: time, trimTo: trimTo)
    }
}
