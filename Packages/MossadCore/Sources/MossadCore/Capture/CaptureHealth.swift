import Foundation

/// What the recorder knows about one track, read on each detection tick.
public struct TrackHealth: Equatable, Sendable {
    /// A source is running for the track.
    public var running = false
    /// A sample that is not exactly zero arrived. A mic without permission sends only zeros.
    public var heardSignal = false
    /// The track had sound above the silence level.
    public var hasSound = false
    public var writeErrors = 0
    public var firstError: String?
    /// Times in a row the source was restarted because it sent nothing.
    public var stallRestarts = 0

    public init(running: Bool = false, heardSignal: Bool = false, hasSound: Bool = false, writeErrors: Int = 0,
                firstError: String? = nil, stallRestarts: Int = 0) {
        self.running = running
        self.heardSignal = heardSignal
        self.hasSound = hasSound
        self.writeErrors = writeErrors
        self.firstError = firstError
        self.stallRestarts = stallRestarts
    }
}

/// A recording that runs but loses one side of the call. Each one is told to the owner once per call.
public enum CaptureProblem: Hashable, Sendable {
    case micDenied
    case systemAudioDenied
    case cannotWrite(String)
    case diskLow
    case micNotRecording
    case callAudioNotRecording
    case micSilent

    public var title: String {
        switch self {
        case .micDenied: "Mossad can't use the microphone"
        case .systemAudioDenied: "The other side of the call is not recorded"
        case .cannotWrite: "Mossad can't save the recording"
        case .diskLow: "Your disk is almost full"
        case .micNotRecording: "Your microphone is not recorded"
        case .callAudioNotRecording: "The call audio is not recorded"
        case .micSilent: "Your microphone sends only silence"
        }
    }

    public var message: String {
        switch self {
        case .micDenied:
            "Your side of the call is not recorded. Allow Mossad in System Settings > Privacy & Security > Microphone."
        case .systemAudioDenied:
            "Allow Mossad in System Settings > Privacy & Security > Screen & System Audio Recording."
        case .cannotWrite(let error):
            "The audio could not be written (\(error)). Free some disk space."
        case .diskLow:
            "Less than 1 GB is free. The recording stops when the disk is full."
        case .micNotRecording:
            "Mossad tries again on its own. Check the microphone in System Settings > Sound."
        case .callAudioNotRecording:
            "Mossad tries again on its own. Only your side of the call is recorded until then."
        case .micSilent:
            "Check that Mossad may use the microphone and that the right microphone is chosen in System Settings > Sound."
        }
    }

    /// One key per kind, so a second write error with other text is not told again.
    var kind: String {
        switch self {
        case .cannotWrite: "cannotWrite"
        default: "\(self)"
        }
    }
}

public enum CaptureHealth {
    /// A source gets this long to start and to send sound before its absence counts.
    public static let grace: TimeInterval = 10
    /// Less free space than this at the start of a call is a warning. An hour of both tracks is about 230 MB.
    public static let lowDiskBytes: Int64 = 1_000_000_000
    /// A source restarted this many times in a row for sending nothing is told to the owner, and then restarted less often.
    public static let stallRestartLimit = 3

    /// `them` is nil for a room recording, which has no call audio.
    public static func problems(elapsed: TimeInterval, micAllowed: Bool, systemAudioAllowed: Bool, freeBytes: Int64?,
                                me: TrackHealth, them: TrackHealth?) -> [CaptureProblem] {
        var found: [CaptureProblem] = []
        if !micAllowed { found.append(.micDenied) }
        if them != nil, !systemAudioAllowed { found.append(.systemAudioDenied) }
        if let error = [me, them].compactMap({ $0 }).first(where: { $0.writeErrors > 0 }) {
            found.append(.cannotWrite(error.firstError ?? "unknown error"))
        }
        if let freeBytes, freeBytes < lowDiskBytes { found.append(.diskLow) }
        guard elapsed >= grace else { return found }
        if micAllowed {
            if !me.running || me.stallRestarts >= stallRestartLimit {
                found.append(.micNotRecording)
            } else if !me.heardSignal, them?.hasSound == true {
                found.append(.micSilent)
            }
        }
        if let them, systemAudioAllowed, !them.running || them.stallRestarts >= stallRestartLimit {
            found.append(.callAudioNotRecording)
        }
        return found
    }
}
