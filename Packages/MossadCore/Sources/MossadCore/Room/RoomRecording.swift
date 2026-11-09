import Foundation

/// The room recorder's rules, apart from AVFoundation: what "recording" means, when to resume, when to start a new
/// file, when to tell the owner, and whether a stopped recording is kept. The app feeds it events and does the
/// actions it returns. A screen that says "Recording" while nothing is recorded loses the rest of the meeting, so
/// the recorder's own state is checked on each tick, not trusted.
public struct RoomRecording: Equatable, Sendable {
    public enum Phase: Equatable, Sendable { case idle, recording, paused(PauseReason), stopped }

    public enum PauseReason: Equatable, Sendable {
        /// The owner tapped Pause.
        case owner
        /// A phone call or another app took the microphone.
        case interruption
        /// The recorder stopped by itself and could not start again.
        case failed
    }

    /// What a local notification tells the owner, whose phone may be locked on the table.
    public enum Alert: Equatable, Sendable { case paused, stopped }

    public enum Action: Equatable, Sendable {
        case pauseRecorder
        /// Record again into the current file; the app reports the result with `resumed(ok:)`.
        case resumeRecorder
        /// Set up the session again and record into a new file; the app reports the result with `resumed(ok:)`.
        case newSegment
        /// Notify now, with sound.
        case notify(Alert)
        /// Notify later unless cancelled: the app may be suspended while the pause lasts.
        case schedule(Alert, after: TimeInterval)
        case cancelAlerts
        /// Say on screen, and to VoiceOver, why nothing is recorded.
        case tellOwner(Alert)
    }

    /// How long the recorder may say "not recording" while the app thinks it records, before the app acts. The
    /// interruption notification can arrive a moment after the recorder stops.
    public static let stallGrace: TimeInterval = 2
    /// A pause from an interruption that lasts this long is worth a notification.
    public static let pauseAlertDelay: TimeInterval = 60
    /// "Discard" is honored only under this length: the dialog shows under a minute, so a long recording means the
    /// owner waited at the dialog or the timer read wrong. Keeping too much costs less than losing a meeting.
    public static let discardLimit: TimeInterval = 300

    public private(set) var phase = Phase.idle
    /// The seconds the app saw the recorder record: its own count, not the recorder's `currentTime`.
    public private(set) var elapsed: TimeInterval = 0
    /// Files written so far; a new one starts when the recorder dies.
    public private(set) var segments = 0
    private var lastTick: Date?
    private var stalledSince: Date?
    /// The recorder is gone (a media services reset or a finish of its own): the next resume needs a new file.
    private var needsNewSegment = false
    /// The resume in progress came from the owner's tap, so its failure needs no notification.
    private var ownerAsked = false

    public init() {}

    public var isRecording: Bool { phase == .recording }
    public var isPaused: Bool { if case .paused = phase { true } else { false } }

    public mutating func start(at now: Date) {
        phase = .recording
        segments = 1
        lastTick = now
        stalledSince = nil
        needsNewSegment = false
    }

    /// Called often (the app ticks 10 times a second) with what the recorder says about itself.
    public mutating func tick(isRecording recorderRecords: Bool, at now: Date) -> [Action] {
        defer { lastTick = now }
        guard phase == .recording else { return [] }
        if recorderRecords {
            // A long gap means the app did not run; count only what a tick can vouch for.
            if let lastTick { elapsed += min(max(0, now.timeIntervalSince(lastTick)), 5) }
            stalledSince = nil
            return []
        }
        guard let since = stalledSince else {
            stalledSince = now
            return []
        }
        guard now.timeIntervalSince(since) >= Self.stallGrace else { return [] }
        stalledSince = nil
        // The recorder object may still work (a short stop); if not, `resumed(ok: false)` moves to a new file.
        return [needsNewSegment ? .newSegment : .resumeRecorder]
    }

    /// The system's interruption, such as a phone call.
    public mutating func interruption(began: Bool, shouldResume: Bool) -> [Action] {
        if began {
            guard phase == .recording else { return [] }
            phase = .paused(.interruption)
            return [.pauseRecorder, .schedule(.paused, after: Self.pauseAlertDelay)]
        }
        guard phase == .paused(.interruption) else { return [] }
        if shouldResume { return [resumeAction] }
        return [.cancelAlerts, .notify(.paused), .tellOwner(.paused)]
    }

    public mutating func ownerPause() -> [Action] {
        guard phase == .recording else { return [] }
        phase = .paused(.owner)
        return [.pauseRecorder]
    }

    public mutating func ownerResume() -> [Action] {
        guard isPaused else { return [] }
        ownerAsked = true
        return [resumeAction]
    }

    /// The result of `.resumeRecorder` or `.newSegment`.
    public mutating func resumed(ok: Bool, newSegment: Bool) -> [Action] {
        let asked = ownerAsked
        if ok {
            ownerAsked = false
            if newSegment {
                segments += 1
                needsNewSegment = false
            }
            phase = .recording
            stalledSince = nil
            return [.cancelAlerts]
        }
        // The recorder did not record again: try a new file, with the session set up again, before giving up.
        if !newSegment {
            needsNewSegment = true
            return [.newSegment]
        }
        ownerAsked = false
        let wasRecording = phase == .recording
        if wasRecording { phase = .paused(.failed) }
        let alert: Alert = wasRecording ? .stopped : .paused
        // The owner who tapped Resume reads the reason on screen; a pause nobody asked for must reach a locked phone.
        if asked { return [.tellOwner(alert)] }
        return [.cancelAlerts, .notify(alert), .tellOwner(alert)]
    }

    /// The audio server restarted, or the recorder finished on its own (a full disk, an encoder error). The
    /// recorder object is dead; what it wrote stays.
    public mutating func recorderDied() -> [Action] {
        needsNewSegment = true
        guard phase == .recording else { return [] }
        return [.newSegment]
    }

    public mutating func stop() {
        phase = .stopped
    }

    private var resumeAction: Action { needsNewSegment ? .newSegment : .resumeRecorder }

    /// Whether a stopped recording is kept. `measured` is the audio on disk (nil when it cannot be read), `counted`
    /// the app's own count. The longer one wins, so a recorder that reads 0 never deletes a meeting.
    public static func keep(measured: TimeInterval?, counted: TimeInterval, discard: Bool) -> Bool {
        let length = max(measured ?? 0, counted)
        guard length >= ProcessingQueue.minimumCallDuration else { return false }
        return !(discard && length < discardLimit)
    }
}
