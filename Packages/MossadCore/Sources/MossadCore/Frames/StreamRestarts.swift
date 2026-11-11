import Foundation

/// A window whose stream ends soon after it began is not captured again at once: whatever the cause (the check of
/// a frame, a stream the system stopped, a stream that could not start), each new stream lights the capture
/// indicator. Each such loss refuses the window for longer, then for the rest of the call. A stream that ran well
/// forgives the earlier quick losses: an edge drag or a quick tab change now and then is normal use, not a loop.
/// Times come from the caller.
public struct StreamRestarts: Sendable {
    /// A loss this soon after the stream began counts.
    static let soon: TimeInterval = 10
    /// A stream that ran this long forgives the window's quick losses.
    static let forgive: TimeInterval = 60
    /// The waits after the first, second, and third such loss; after the fourth the window waits for the call's end.
    static let waits: [TimeInterval] = [30, 120, 600]

    public enum Outcome: Equatable, Sendable {
        case none
        case refused(TimeInterval)
        case refusedForTheCall
    }

    private var began: [UInt32: Date] = [:]
    private var losses: [UInt32: Int] = [:]
    private var until: [UInt32: Date] = [:]

    public init() {}

    public func allows(_ window: UInt32, at now: Date) -> Bool {
        until[window].map { now >= $0 } ?? true
    }

    public mutating func began(_ window: UInt32, at now: Date) {
        began[window] = now
    }

    /// The window's stream ended, for any reason.
    public mutating func lost(_ window: UInt32, at now: Date) -> Outcome {
        guard let start = began.removeValue(forKey: window) else { return .none }
        let ran = now.timeIntervalSince(start)
        if ran >= Self.forgive { losses[window] = nil }
        guard ran < Self.soon else { return .none }
        let count = (losses[window] ?? 0) + 1
        losses[window] = count
        guard count <= Self.waits.count else {
            until[window] = .distantFuture
            return .refusedForTheCall
        }
        let wait = Self.waits[count - 1]
        until[window] = now.addingTimeInterval(wait)
        return .refused(wait)
    }
}
