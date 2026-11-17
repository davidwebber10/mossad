import Foundation

/// A worker's watch of the app in front: the foreground file every 2 s (read again only when it changed), the
/// app's pid at each tick, an exit source on that pid, and SIGTERM and SIGINT as a stop. It tells `onStop` once.
public final class ForegroundWatcher: @unchecked Sendable {
    public static let every: TimeInterval = 2

    private let file: URL
    private let every: TimeInterval
    private let alive: @Sendable (ForegroundState) -> Bool
    private let signals: Bool
    private let onStop: @Sendable (ForegroundWatch.Stop) -> Void
    private let queue = DispatchQueue(label: "mossad.worker.watch")
    private let lock = NSLock()
    private var watch = ForegroundWatch()
    private var calling = true
    private var stopped = false
    private var lastStamp: (Date?, Int)?
    private var lastRead: ForegroundState.Read = .missing
    private var timer: DispatchSourceTimer?
    private var exitSource: DispatchSourceProcess?
    private var exitPid: Int32?
    private var signalSources: [DispatchSourceSignal] = []

    public init(file: URL, every: TimeInterval = ForegroundWatcher.every,
                alive: @escaping @Sendable (ForegroundState) -> Bool = { ProcessFacts.isAlive(pid: $0.pid, started: $0.started) },
                signals: Bool = true, onStop: @escaping @Sendable (ForegroundWatch.Stop) -> Void) {
        self.file = file
        self.every = every
        self.alive = alive
        self.signals = signals
        self.onStop = onStop
    }

    /// True until a read says no call records: a worker that cannot tell assumes a call.
    public var callRecords: Bool { lock.withLock { calling } }

    /// The read at start, before the worker touches its folder. It does not call `onStop`.
    public func first() -> ForegroundWatch.Order {
        queue.sync { check(force: true, tell: false) }
    }

    public func start() {
        queue.async { [self] in
            if signals {
                for sig in [SIGTERM, SIGINT] {
                    signal(sig, SIG_IGN)
                    let source = DispatchSource.makeSignalSource(signal: sig, queue: queue)
                    source.setEventHandler { [weak self] in self?.finish(.told) }
                    source.resume()
                    signalSources.append(source)
                }
            }
            let t = DispatchSource.makeTimerSource(queue: queue)
            t.schedule(deadline: .now() + every, repeating: every)
            t.setEventHandler { [weak self] in _ = self?.check(force: false, tell: true) }
            t.resume()
            timer = t
            watchExit()
        }
    }

    /// Runs on the queue.
    @discardableResult
    private func check(force: Bool, tell: Bool) -> ForegroundWatch.Order {
        let attributes = try? FileManager.default.attributesOfItem(atPath: file.path)
        let stamp = (attributes?[.modificationDate] as? Date, (attributes?[.size] as? Int) ?? -1)
        let read: ForegroundState.Read
        if !force, let last = lastStamp, last.0 == stamp.0, last.1 == stamp.1 {
            read = lastRead
        } else {
            read = ForegroundState.read(file)
            lastRead = read
            lastStamp = stamp
        }
        let order = lock.withLock { watch.next(read, alive: alive) }
        switch order {
        case .work(let callRecords):
            lock.withLock { calling = callRecords }
            watchExit()
        case .stop(let why):
            if tell { finish(why) }
        }
        return order
    }

    /// An exit source on the known pid, made again when the pid changes. Runs on the queue.
    private func watchExit() {
        guard let pid = lock.withLock({ watch.known?.pid }), pid != exitPid else { return }
        exitSource?.cancel()
        exitPid = pid
        let source = DispatchSource.makeProcessSource(identifier: pid_t(pid), eventMask: .exit, queue: queue)
        source.setEventHandler { [weak self] in self?.finish(.foregroundGone) }
        source.resume()
        exitSource = source
    }

    /// Runs on the queue; tells once.
    private func finish(_ why: ForegroundWatch.Stop) {
        let first = lock.withLock { () -> Bool in
            if stopped { return false }
            stopped = true
            return true
        }
        guard first else { return }
        timer?.cancel()
        exitSource?.cancel()
        onStop(why)
    }
}
