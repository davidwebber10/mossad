import Foundation
import Synchronization

/// Lets go of a model that is held in memory (hundreds of megabytes to more than a gigabyte for speech models)
/// when nothing used it for a while, and at once when the system runs short of memory. The model loads again at
/// its next use.
public final class ModelLease: Sendable {
    public static let idleTime: Duration = .seconds(180)

    private struct State {
        var users = 0
        /// Changes with each use, so a timer from before a newer use does nothing.
        var generation = 0
        var releaseWhenFree = false
        var release: (@Sendable () async -> Void)?
    }

    private let state = Mutex(State())
    private let idle: Duration
    private let name: String

    public init(_ name: String, idle: Duration = ModelLease.idleTime, watchesMemory: Bool = true) {
        self.name = name
        self.idle = idle
        if watchesMemory { MemoryPressure.shared.add(self) }
    }

    /// What frees the model. It must check `isFree` where the model lives, so a use that just began keeps it.
    public func onRelease(_ release: @escaping @Sendable () async -> Void) {
        state.withLock { $0.release = release }
    }

    public var isFree: Bool { state.withLock { $0.users == 0 } }

    /// Call before the model is used, and `end` after (also after an error).
    public func begin() {
        state.withLock {
            $0.users += 1
            $0.generation += 1
        }
    }

    public func end() {
        let (generation, now, release) = state.withLock { s -> (Int, Bool, (@Sendable () async -> Void)?) in
            s.users = max(0, s.users - 1)
            s.generation += 1
            let now = s.users == 0 && s.releaseWhenFree
            if now { s.releaseWhenFree = false }
            return (s.generation, now, s.release)
        }
        guard let release else { return }
        if now {
            Task(priority: .utility) { await release() }
            return
        }
        let idle = idle, name = name
        Task(priority: .utility) { [weak self] in
            try? await Task.sleep(for: idle)
            guard let self, self.state.withLock({ $0.users == 0 && $0.generation == generation }) else { return }
            Log.info("Releasing the \(name): not used for \(idle.components.seconds) s")
            await release()
        }
    }

    /// The system is short of memory: free the model now, or as soon as its current use ends.
    public func memoryPressure() {
        let release = state.withLock { s -> (@Sendable () async -> Void)? in
            guard s.users == 0 else {
                s.releaseWhenFree = true
                return nil
            }
            s.generation += 1
            return s.release
        }
        guard let release else { return }
        Log.info("Releasing the \(name): the system is short of memory")
        Task(priority: .utility) { await release() }
    }
}

/// One watcher of the system's memory pressure for all leases.
final class MemoryPressure: @unchecked Sendable {
    static let shared = MemoryPressure()

    private final class Weak { weak var lease: ModelLease?; init(_ lease: ModelLease) { self.lease = lease } }
    private let lock = NSLock()
    private var leases: [Weak] = []
    private let source: DispatchSourceMemoryPressure

    private init() {
        source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .global(qos: .utility))
        source.setEventHandler { [weak self] in self?.fire() }
        source.resume()
    }

    func add(_ lease: ModelLease) {
        lock.withLock {
            leases.removeAll { $0.lease == nil }
            leases.append(Weak(lease))
        }
    }

    func fire() {
        let all = lock.withLock { leases.compactMap(\.lease) }
        all.forEach { $0.memoryPressure() }
    }
}
