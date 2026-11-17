import Foundation

/// What the app shows of the owner's mute state. The recorder follows `MuteTracker`, which treats a "muted" that
/// cannot be read for `MuteTracker.unknownLimit` as unmuted, so no speech is lost. The app must not then read as
/// "not muted": the owner may still be muted in a tab that Accessibility cannot see. So that unmute shows as
/// "muted when last seen" until the next sure reading, the end of the call, or a new call.
public enum ShownMute: Equatable, Sendable {
    /// A sure "unmuted", or no reading in this call yet.
    case none
    case muted
    case mutedWhenLastSeen

    public enum Reading: Equatable, Sendable {
        case sure(muted: Bool)
        /// The tracker turned "muted" into "unmuted" only because the state could not be read.
        case unreadable
    }

    public func after(_ reading: Reading) -> ShownMute {
        switch reading {
        case .sure(let muted): muted ? .muted : .none
        case .unreadable: self == .none ? .none : .mutedWhenLastSeen
        }
    }

    public var shows: Bool { self != .none }

    public var words: String? {
        switch self {
        case .none: nil
        case .muted: "muted"
        case .mutedWhenLastSeen: "muted when last seen"
        }
    }

    public var title: String? { words.map { $0.prefix(1).uppercased() + $0.dropFirst() } }

    public func banner(platform: Platform) -> (lead: String, detail: String)? {
        switch self {
        case .none: nil
        case .muted: ("Muted in \(platform.displayName).", "Your mic is not recorded while you are muted.")
        case .mutedWhenLastSeen: ("Muted in \(platform.displayName) when last seen.",
                                  "Mossad cannot see the mute button now, so it records your mic.")
        }
    }

    /// A preview's `MOSSAD_MUTED`: "1" is muted, "last" is muted when last seen.
    public init(preview value: String?) {
        switch value {
        case "1": self = .muted
        case "last": self = .mutedWhenLastSeen
        default: self = .none
        }
    }
}
