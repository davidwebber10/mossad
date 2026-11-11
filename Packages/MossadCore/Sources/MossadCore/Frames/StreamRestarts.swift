import Foundation

/// A window whose stream the check of a frame ends soon after it began is not captured again at once: whatever
/// the cause, the search and the check disagree about it, and each new stream lights the capture indicator.
/// Each such loss refuses the window for longer, then for the rest of the call. Times come from the caller.
public struct StreamRestarts: Sendable {
    /// A loss this soon after the stream began counts.
    static let soon: TimeInterval = 10
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

    /// The check of a frame ended the window's stream.
    public mutating func lost(_ window: UInt32, at now: Date) -> Outcome {
        guard let start = began.removeValue(forKey: window), now.timeIntervalSince(start) < Self.soon else { return .none }
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
