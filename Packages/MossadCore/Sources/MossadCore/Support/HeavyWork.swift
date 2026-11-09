import Foundation
import Synchronization

/// Holds back work that loads the processor (audio encodes, voice fingerprints, on-device transcription) while a
/// call records: the call app needs the processor for video and sound, and the work loses nothing by a wait.
/// Uploads and requests to a service do not wait here.
public final class HeavyWorkGate: Sendable {
    public static let shared = HeavyWorkGate()

    private let check: Mutex<(@Sendable () async -> Bool)?>
    private let pollInterval: Duration

    public init(pollInterval: Duration = .seconds(5), isCallRecording: (@Sendable () async -> Bool)? = nil) {
        self.pollInterval = pollInterval
        self.check = Mutex(isCallRecording)
    }

    /// The app says how to learn whether a call records now. Asked again each time, so no state can go stale.
    public func setCheck(_ isCallRecording: (@Sendable () async -> Bool)?) {
        check.withLock { $0 = isCallRecording }
    }

    public var isHeld: Bool {
        get async {
            guard let check = check.withLock({ $0 }) else { return false }
            return await check()
        }
    }

    /// Returns when no call records; at once in most cases. A cancelled task does not wait.
    public func waitForQuiet(_ work: String) async {
        var waited = false
        while await isHeld {
            if !waited {
                waited = true
                Log.info("A call records; \(work) waits until it ends")
            }
            do { try await Task.sleep(for: pollInterval) } catch { return }
        }
    }
}

public enum HeavyWork {
    /// Runs blocking work (a file encode, a full read of a track) on a thread of its own priority, off the caller's
    /// actor, so the actor stays free for the owner's edits.
    public static func run<T: Sendable>(priority: TaskPriority = .utility, _ body: @escaping @Sendable () throws -> T) async throws -> T {
        try await Task.detached(priority: priority) { try body() }.value
    }
}
