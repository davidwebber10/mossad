import Foundation
import Synchronization

/// The steps that load the processor of this Mac. Uploads and requests to a service are not here: they never wait.
public enum HeavyStep: String, CaseIterable, Sendable {
    /// The full read of the call track for the sound timeline, and the merge of the two transcripts.
    case trackJoin
    case voiceIdentification
    /// The compressed copy of a track that goes up for transcription.
    case uploadEncode
    /// A transcription model on this Mac: all of the processor for minutes.
    case onDeviceTranscription
    /// The mix and AAC encode of the whole call for the player.
    case recordingEncode

    /// The join and the voices are short and read only parts of the call, so they run behind a call. A full-call
    /// encode and a model on this Mac wait for the call to end, unless the owner said "Process now".
    var runsDuringCall: Bool {
        switch self {
        case .trackJoin, .voiceIdentification: true
        case .uploadEncode, .onDeviceTranscription, .recordingEncode: false
        }
    }

    var name: String {
        switch self {
        case .trackJoin: "joining the two tracks"
        case .voiceIdentification: "voice identification"
        case .uploadEncode: "the upload encode"
        case .onDeviceTranscription: "the transcription on this Mac"
        case .recordingEncode: "the recording encode"
        }
    }

    /// The owner reads these lines to see what a call cost the call after it.
    func logLine(callID: String, seconds: Double) -> String {
        "During a call: \(name) of \(callID) took \(String(format: "%.1f", seconds)) s"
    }
}

/// When and how a heavy step runs.
public enum HeavyWorkPlan: Equatable, Sendable {
    /// No call records: at a low priority, so the note does not wait long.
    case run
    /// A call records: at the lowest priority, so the work stays on the efficiency cores and off the call's way.
    case behindCall
    /// Until the call ends, or until the owner releases this call.
    case wait

    public static func plan(for step: HeavyStep, callRecording: Bool, released: Bool) -> HeavyWorkPlan {
        guard callRecording else { return .run }
        return step.runsDuringCall || released ? .behindCall : .wait
    }

    public var priority: TaskPriority { self == .run ? .utility : .background }
    public var duringCall: Bool { self != .run }
}

/// Holds back work that loads the processor while a call records: the call app needs the processor for video and
/// sound. `HeavyWorkPlan` says which steps wait; "Process now" releases one call.
public final class HeavyWorkGate: Sendable {
    public static let shared = HeavyWorkGate()

    private struct State {
        var check: (@Sendable () async -> Bool)?
        var released: Set<String> = []
        var waiting: [String: Int] = [:]
        var onWaitingChange: (@Sendable (Set<String>) -> Void)?
    }

    private let state: Mutex<State>
    private let pollInterval: Duration
    /// How often a wait looks for "Process now": a click must not wait for the next check of the call.
    private static let releaseInterval: Duration = .milliseconds(250)
    let log: @Sendable (String) -> Void

    public init(pollInterval: Duration = .seconds(5), isCallRecording: (@Sendable () async -> Bool)? = nil,
                log: @escaping @Sendable (String) -> Void = { Log.info($0) }) {
        self.pollInterval = pollInterval
        self.state = Mutex(State(check: isCallRecording))
        self.log = log
    }

    /// The app says how to learn whether a call records now. Asked again each time, so no state can go stale.
    public func setCheck(_ isCallRecording: (@Sendable () async -> Bool)?) {
        state.withLock { $0.check = isCallRecording }
    }

    /// Told each time the set of calls that wait changes, from any thread.
    public func onWaitingChange(_ body: (@Sendable (Set<String>) -> Void)?) {
        state.withLock { $0.onWaitingChange = body }
    }

    public var isHeld: Bool {
        get async {
            guard let check = state.withLock({ $0.check }) else { return false }
            return await check()
        }
    }

    /// "Process now": every remaining step of this call runs, behind a call if one records. Only this call.
    public func release(_ callID: String) {
        state.withLock { _ = $0.released.insert(callID) }
    }

    public func isReleased(_ callID: String) -> Bool { state.withLock { $0.released.contains(callID) } }

    /// The call is written or gone; a new call never has its id.
    public func forget(_ callID: String) {
        state.withLock { _ = $0.released.remove(callID) }
    }

    /// The calls that wait for the call that records now.
    public var waiting: Set<String> { state.withLock { Set($0.waiting.keys) } }

    public func plan(_ step: HeavyStep, callID: String) async -> HeavyWorkPlan {
        let released = isReleased(callID)
        if released { return await isHeld ? .behindCall : .run }
        return HeavyWorkPlan.plan(for: step, callRecording: await isHeld, released: false)
    }

    /// Returns the plan once the step may run: at once in most cases. A cancelled task does not wait; it runs
    /// behind the call.
    public func waitForClearance(_ step: HeavyStep, callID: String) async -> HeavyWorkPlan {
        var plan = await self.plan(step, callID: callID)
        guard plan == .wait else { return plan }
        log("A call records; \(step.name) of \(callID) waits until it ends")
        changeWaiting(callID, by: 1)
        defer { changeWaiting(callID, by: -1) }
        let clock = ContinuousClock()
        while plan == .wait {
            let next = clock.now + pollInterval
            while clock.now < next, !isReleased(callID) {
                do { try await Task.sleep(for: min(Self.releaseInterval, next - clock.now)) } catch { return .behindCall }
            }
            plan = await self.plan(step, callID: callID)
        }
        return plan
    }

    private func changeWaiting(_ callID: String, by delta: Int) {
        let (calls, tell): (Set<String>, (@Sendable (Set<String>) -> Void)?) = state.withLock { s in
            let n = (s.waiting[callID] ?? 0) + delta
            s.waiting[callID] = n > 0 ? n : nil
            return (Set(s.waiting.keys), s.onWaitingChange)
        }
        tell?(calls)
    }
}

public enum HeavyWork {
    /// Runs work (a file encode, a full read of a track, the voice models) at its own priority, off the caller's
    /// actor, so the actor stays free for the owner's edits. The caller waits on a continuation, not on the task:
    /// a wait on the task would raise the work to the caller's priority. The work keeps the caller's task-local
    /// values (the call a request is billed to).
    public static func run<T: Sendable>(priority: TaskPriority = .utility, _ body: @escaping @Sendable () async throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { done in
            Task(priority: priority) {
                do { done.resume(returning: try await body()) } catch { done.resume(throwing: error) }
            }
        }
    }
}
