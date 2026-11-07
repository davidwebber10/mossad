import Foundation

/// Where "Update now" stands, for the sidebar's card. Every way a Sparkle session can end returns to idle, so the
/// card never stays stuck on "Installing…".
public struct UpdateProgress: Equatable, Sendable {
    public enum Phase: Equatable, Sendable {
        case idle
        /// The owner clicked; Sparkle is checking and has not asked yet.
        case opening
        /// The owner chose to install; Sparkle is downloading or installing.
        case installing
    }

    public private(set) var phase: Phase = .idle

    public init() {}

    public var canStart: Bool { phase == .idle }

    public mutating func clicked() { if canStart { phase = .opening } }
    /// Sparkle found the update and asks the owner: a new session starts clean.
    public mutating func found() { phase = .idle }
    public mutating func chose(install: Bool) { phase = install ? .installing : .idle }
    public mutating func notFound() { phase = .idle }
    public mutating func aborted() { phase = .idle }
    /// The download was canceled or failed.
    public mutating func downloadEnded() { phase = .idle }
    /// Sparkle's session is over, however it ended. An install that waits for a call or for quit shows its own text.
    public mutating func cycleFinished() { phase = .idle }
}
