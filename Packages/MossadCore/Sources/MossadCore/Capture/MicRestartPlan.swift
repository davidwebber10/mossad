import Foundation
import MossadObjC

/// An Objective-C exception as a Swift error. AVFAudio raises one (rather than returning an error) for a tap on a
/// format the hardware does not have at that moment; Swift cannot catch it, and the app would abort.
public enum ObjCException {
    public struct Raised: Error, CustomStringConvertible {
        public let description: String
    }

    public static func catching(_ body: () -> Void) throws {
        var error: NSError?
        if !MossadTry(body, &error) {
            throw Raised(description: "Objective-C exception: \(error?.localizedDescription ?? "unknown")")
        }
    }
}

/// One side of the microphone's input node: its sample rate and channels.
public struct MicFormat: Equatable, Sendable, CustomStringConvertible {
    public var sampleRate: Double
    public var channels: UInt32

    public init(sampleRate: Double, channels: UInt32) {
        self.sampleRate = sampleRate
        self.channels = channels
    }

    var isValid: Bool { sampleRate > 0 && channels > 0 }
    public var description: String { "\(Int(sampleRate)) Hz, \(channels) ch" }
}

/// Whether a tap may go on the input node now: the hardware side and the side the tap reads must agree. While a
/// headset changes mode (24 kHz in a call, 48 kHz after it) the two can differ for a moment, and a tap then raises.
public enum MicStartCheck {
    public enum Result: Equatable, Sendable {
        case ok
        /// No input device at all (a closed MacBook whose headset left).
        case noInput
        /// The route is still changing: try again shortly on a fresh engine.
        case settling
    }

    public static func check(hardware: MicFormat, output: MicFormat) -> Result {
        if !hardware.isValid, !output.isValid { return .noInput }
        guard hardware.isValid, output.isValid, hardware == output else { return .settling }
        return .ok
    }
}

/// The restarts of the mic after a change of the audio route. One restart at a time: a change that comes while one
/// is pending joins it. A failed attempt is tried again on a fresh engine after a growing wait, about 10 s in all;
/// only then does the source report a failure (the recorder's own retry and the silence in the track go on as
/// before). Each attempt has a token, so a wait that fires after `stop` or after a newer start does nothing.
public struct MicRestartPlan: Sendable {
    public enum Step: Equatable, Sendable {
        case restart(token: Int, after: Double)
        case giveUp
    }

    public static let delays: [Double] = [0.3, 0.6, 1.2, 2.4, 4.8]

    private var token = 0
    private var attempt = 0
    private var stopped = false
    public private(set) var pending = false

    public init() {}

    /// A configuration change: a restart now, or nil when one is pending (or the mic stopped).
    public mutating func configurationChanged() -> Step? {
        guard !stopped, !pending else { return nil }
        pending = true
        attempt = 0
        token += 1
        return .restart(token: token, after: 0)
    }

    /// The attempt with `token` failed: the next one after its wait, or give up. Nil for an old token.
    public mutating func failed(token: Int) -> Step? {
        guard !stopped, pending, token == self.token else { return nil }
        guard attempt < Self.delays.count else {
            pending = false
            return .giveUp
        }
        let wait = Self.delays[attempt]
        attempt += 1
        self.token += 1
        return .restart(token: self.token, after: wait)
    }

    public mutating func succeeded(token: Int) {
        guard token == self.token else { return }
        pending = false
        attempt = 0
    }

    /// Whether a scheduled attempt with `token` should still run.
    public func isCurrent(_ token: Int) -> Bool { !stopped && pending && token == self.token }

    public mutating func stop() {
        stopped = true
        pending = false
        token += 1
    }
}
