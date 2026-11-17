import Foundation
import Synchronization

/// The parts of a move that load the disk and the processor (the copy, its hashes, the take-in's hashes) and the rest.
public enum MoveWork: String, CaseIterable, Sendable {
    /// The start of a copy into the other profile's `Incoming`.
    case startCopy
    /// The next file of a copy that runs: the file that is in progress finishes first.
    case nextFile
    /// A take-in: the claim, the first half, the rename, and the hash of every file.
    case takeIn
    /// Every other step: a publish, a mark, a step of the removal, a cancel. Small, and never held.
    case smallStep

    var heavy: Bool { self != .smallStep }
}

/// When a part of a move runs, in the style of `HeavyWorkPlan`: while a call records (or a worker cannot tell), the
/// copy and the take-in wait, and the rest runs at the lowest priority; with no call, the app in front runs them at a
/// low priority and a worker at the lowest.
public enum MoveWorkPlan: Equatable, Sendable {
    case run
    case behind
    case hold

    /// `callRecording` nil: it cannot be told, so a call records.
    public static func plan(_ work: MoveWork, callRecording: Bool?, worker: Bool) -> MoveWorkPlan {
        let call = callRecording ?? true
        if call { return work.heavy ? .hold : .behind }
        return worker ? .behind : .run
    }

    public var priority: TaskPriority { self == .run ? .utility : .background }
}

/// Whether a call records now, readable from any thread: the window app sets it at each change of its status.
public final class RecordingFlag: Sendable {
    private let value: Mutex<Bool>
    public init(_ recording: Bool = false) { value = Mutex(recording) }
    public var recording: Bool { value.withLock { $0 } }
    public func set(_ recording: Bool) { value.withLock { $0 = recording } }
}
