import Foundation
import MossadCore

/// The workers of the other profiles: one child process each (`Mossad --profile <id> --worker`), started when the
/// launch is done, told through `foreground.json` whether a call records, and stopped at a quit, a switch, or a
/// delete. With one profile it writes no file, starts no process, and starts no timer.
@MainActor
final class WorkerManager {
    private struct Child {
        let process: Process
        let started: Date
        let failures: Int
    }

    private let identity: AppIdentity
    private var profiles: [Profile]
    private let file: URL
    private let home = FileManager.default.homeDirectoryForCurrentUser
    private let onLines: @MainActor ([String: String]) -> Void
    /// The file is written in order, off the main actor.
    private let fileQueue = DispatchQueue(label: "mossad.workers.file")
    private var children: [String: Child] = [:]
    private var restarts: [String: Task<Void, Never>] = [:]
    private var gaveUp: Set<String> = []
    /// The workers that a stop ended: none of them starts again until `resume`.
    private var stopped: Set<String> = []
    private var stopping = false
    private var recording = false
    private var started = false
    private var timer: Timer?
    private var lines: [String: String] = [:]

    init(identity: AppIdentity, mode: RunMode, proof: Bool = false, onLines: @escaping @MainActor ([String: String]) -> Void) {
        self.identity = identity
        profiles = WorkerLaunch.profiles(identity, mode: mode, proof: proof)
        file = ForegroundState.url(home: FileManager.default.homeDirectoryForCurrentUser, environment: ProcessInfo.processInfo.environment)
        self.onLines = onLines
    }

    /// The file first (this app's pid, `stopping` false), then one child for each profile. A file left by an app
    /// that ended is replaced before any worker starts, so it never stops or starts anything.
    func start(recording: Bool) {
        guard WorkerLaunch.writesForegroundFile(profiles: profiles), !started else { return }
        started = true
        self.recording = recording
        Log.info("Workers: starting \(profiles.count) for the other profiles")
        write(takeOver: true) { [weak self] in self?.profiles.forEach { self?.launch($0, failures: 0) } }
        let t = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.readLines() }
        }
        t.tolerance = 2
        timer = t
    }

    func setRecording(_ recording: Bool) {
        guard started, self.recording != recording else { return }
        self.recording = recording
        write()
    }

    /// `stopping` in the file and SIGTERM to each child, then waits until that profile's folder lock is free.
    func stopAll(waitingFor id: String, seconds: TimeInterval) async -> Bool {
        guard started else { return true }
        stopping = true
        write()
        for (id, _) in children { terminate(id) }
        return await waitForFolder(of: id, seconds: seconds)
    }

    /// SIGTERM to one profile's worker, then waits until its folder lock is free.
    func stop(_ id: String, seconds: TimeInterval) async -> Bool {
        guard started else { return true }
        stopped.insert(id)
        terminate(id)
        return await waitForFolder(of: id, seconds: seconds)
    }

    /// A deleted profile: its worker never starts again, also not by `resume`.
    func forget(_ id: String) {
        terminate(id)
        profiles.removeAll { $0.id == id }
        readLines()
    }

    /// After a refused switch or delete: `stopping` false in the file, and the workers start again.
    func resume(recording: Bool) {
        guard started else { return }
        stopping = false
        stopped = []
        self.recording = recording
        write { [weak self] in
            guard let self else { return }
            for profile in profiles where children[profile.id] == nil && restarts[profile.id] == nil { launch(profile, failures: 0) }
        }
    }

    /// At a quit: `stopping` in the file (written before the app ends) and SIGTERM to each child; no wait. A
    /// worker that misses both ends when this app's pid is gone.
    func quit() {
        guard started else { return }
        stopping = true
        timer?.invalidate()
        restarts.values.forEach { $0.cancel() }
        let state = foreground()
        fileQueue.sync { [file] in Self.save(state, to: file) }
        for (id, _) in children { terminate(id) }
        Log.info("Workers: told to stop at quit")
    }

    // MARK: - Children

    private func launch(_ profile: Profile, failures: Int) {
        restarts[profile.id] = nil
        guard !stopping, !stopped.contains(profile.id), children[profile.id] == nil, let executable = Bundle.main.executableURL else { return }
        let process = WorkerLaunch.process(executable: executable, profile: profile, environment: ProcessInfo.processInfo.environment)
        let id = profile.id
        process.terminationHandler = { [weak self] p in
            let code = p.terminationStatus
            Task { @MainActor in self?.ended(id, process: p, exit: code) }
        }
        do {
            try process.run()
            children[id] = Child(process: process, started: Date(), failures: failures)
            gaveUp.remove(id)
            Log.info("Workers: \(id) started (pid \(process.processIdentifier))")
        } catch {
            Log.error("Workers: \(id) did not start: \(error)")
            decide(id, exit: -1, failures: failures)
        }
        readLines()
    }

    private func ended(_ id: String, process: Process, exit code: Int32) {
        guard let child = children[id], child.process === process else { return }
        children[id] = nil
        let failures = WorkerLaunch.failures(after: child.failures, ranSeconds: Date().timeIntervalSince(child.started))
        Log.info("Workers: \(id) ended (exit \(code))")
        decide(id, exit: code, failures: failures)
        readLines()
    }

    private func decide(_ id: String, exit code: Int32, failures: Int) {
        switch WorkerLaunch.restart(exit: code, failures: failures, stopping: stopping || stopped.contains(id)) {
        case .never: break
        case .gaveUp:
            gaveUp.insert(id)
            Log.error("Workers: \(id) keeps failing; it is not started again")
        case .after(let wait):
            restarts[id] = Task { [weak self] in
                try? await Task.sleep(for: .seconds(wait))
                guard !Task.isCancelled, let self, let profile = profiles.first(where: { $0.id == id }) else { return }
                launch(profile, failures: failures + 1)
            }
        }
    }

    private func terminate(_ id: String) {
        restarts[id]?.cancel()
        restarts[id] = nil
        if let child = children[id], child.process.isRunning { child.process.terminate() }
    }

    private func waitForFolder(of id: String, seconds: TimeInterval) async -> Bool {
        guard let profile = profiles.first(where: { $0.id == id }) else { return true }
        let root = profile.rootURL(home: home)
        return await Task.detached(priority: .userInitiated) { InstanceLock.waitUntilFree(root: root, timeout: seconds) }.value
    }

    // MARK: - The file

    private func foreground() -> ForegroundState {
        let pid = ProcessInfo.processInfo.processIdentifier
        return ForegroundState(pid: pid, started: ProcessFacts.startTime(of: pid), recording: recording, stopping: stopping)
    }

    /// Writes the state as it is now, in order; `then` runs on the main actor once it is on disk.
    private func write(takeOver: Bool = false, then: (@MainActor () -> Void)? = nil) {
        let state = foreground()
        fileQueue.async { [file] in
            Self.save(state, to: file, takeOver: takeOver)
            if let then { Task { @MainActor in then() } }
        }
    }

    nonisolated private static func save(_ state: ForegroundState, to file: URL, takeOver: Bool = false) {
        guard ForegroundState.mayWrite(over: ForegroundState.read(file), pid: state.pid,
                                       alive: { ProcessFacts.isAlive(pid: $0.pid, started: $0.started) }, takeOver: takeOver) else {
            Log.info("Workers: another app is in front now; the foreground file stays as it wrote it")
            return
        }
        do { try state.write(to: file) } catch { Log.error("Workers: the foreground file was not written: \(error)") }
    }

    // MARK: - The switcher's lines

    /// Each other profile's status file, and nothing else of its folder, off the main actor.
    private func readLines() {
        let roots = profiles.map { ($0.id, $0.rootURL(home: home)) }
        let running = Set(children.keys), gaveUp = gaveUp
        Task.detached(priority: .utility) {
            var next: [String: String] = [:]
            for (id, root) in roots {
                if let line = WorkerStatusLine.text(WorkerStatus.peek(root: root), running: running.contains(id), gaveUp: gaveUp.contains(id)) {
                    next[id] = line
                }
            }
            await MainActor.run { [weak self] in
                guard let self, next != lines else { return }
                lines = next
                onLines(next)
            }
        }
    }
}
