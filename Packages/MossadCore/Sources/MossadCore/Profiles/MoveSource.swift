import Foundation

/// The first profile's half of a move: start, advance, cancel. Each advance does the one step that `MovePlan.source`
/// names, saves the ledger, and can stop at any line: the next run goes on from the ledger and the marker. Only one
/// advance of an id runs at a time in a process.
public struct MoveSource: Sendable {
    public struct Setup: Sendable {
        public var paths: Paths
        public var profileID: String
        public var pipeline: Pipeline
        public var library: VoiceLibrary
        public var ownerName: @Sendable () -> String
        /// `MoveRules.target` with the registry as it is now.
        public var target: @Sendable (String) -> MoveRules.TargetPlace
        /// `CloudArchive.fetch`; nil with no backup set up.
        public var fetch: @Sendable (CallRecord, URL) async -> URL?
        public var room: @Sendable (Int64, URL) -> Bool? = { MoveCopy.room(for: $0, at: $1) }
        public var usage: @Sendable (String) -> [UsageEvent]
        public var actions: MoveRemoval.Actions
        public var progress: @Sendable (String, Double) -> Void = { _, _ in }
        public var now: @Sendable () -> Date = Date.init
        /// For a test: the end of the process at a sub-step.
        public var stop: @Sendable (String) throws -> Void = { _ in }

        public init(paths: Paths, profileID: String, pipeline: Pipeline, library: VoiceLibrary, ownerName: @escaping @Sendable () -> String,
                    target: @escaping @Sendable (String) -> MoveRules.TargetPlace, fetch: @escaping @Sendable (CallRecord, URL) async -> URL?,
                    usage: @escaping @Sendable (String) -> [UsageEvent], actions: MoveRemoval.Actions,
                    now: @escaping @Sendable () -> Date = Date.init, stop: @escaping @Sendable (String) throws -> Void = { _ in }) {
            self.paths = paths
            self.profileID = profileID
            self.pipeline = pipeline
            self.library = library
            self.ownerName = ownerName
            self.target = target
            self.fetch = fetch
            self.usage = usage
            self.actions = actions
            self.now = now
            self.stop = stop
        }
    }

    public enum Start: Equatable, Sendable { case started, refused(String) }
    public enum Event: Equatable, Sendable { case working, waiting, moved(to: String), cancelled(MovePlan.Cancel), nothing }

    private let s: Setup
    public init(_ setup: Setup) { s = setup }

    // MARK: One advance of an id at a time

    private static let lock = NSLock()
    nonisolated(unsafe) private static var running: Set<String> = []

    private func exclusive<T>(_ callID: String, _ busy: T, _ body: () async -> T) async -> T {
        let key = s.paths.root.path + "|" + callID
        guard Self.lock.withLock({ Self.running.insert(key).inserted }) else { return busy }
        defer { _ = Self.lock.withLock { Self.running.remove(key) } }
        return await body()
    }

    /// The same, but it waits for an advance that runs (the owner's Cancel during a long copy).
    private func exclusiveWaiting<T>(_ callID: String, _ body: () async -> T) async -> T {
        let key = s.paths.root.path + "|" + callID
        while !Self.lock.withLock({ Self.running.insert(key).inserted }) { try? await Task.sleep(for: .milliseconds(50)) }
        defer { _ = Self.lock.withLock { Self.running.remove(key) } }
        return await body()
    }

    /// A ledger that changed since the step read it (another writer, or a step of a stopped run) is never written over.
    struct Overtaken: Error {}

    // MARK: Start and cancel

    /// `name`: the target's name as the owner sees it, for the sentence of a refusal.
    /// One start or advance of an id at a time: a second start (a double click) is refused while the first runs.
    public func start(_ callID: String, to target: String, name: String? = nil, afterCall: Bool = false) async -> Start {
        await exclusive(callID, .refused(MoveWords.inWork)) { await startNow(callID, to: target, name: name, afterCall: afterCall) }
    }

    private func startNow(_ callID: String, to target: String, name: String?, afterCall: Bool) async -> Start {
        guard MovePaths.isID(callID), MovePaths.isID(target), target != s.profileID else { return .refused(MoveWords.inWork) }
        switch s.target(target) {
        case .paths: break
        case .unknown: return .refused(MoveWords.unreachable)
        case .gone: return .refused(MoveWords.refusal(.targetGone, target: name ?? target) ?? MoveWords.inWork)
        }
        guard let r = try? CallRecord.load(from: s.paths.callDirectory(callID)), r.id == callID else { return .refused(MoveWords.inWork) }
        let names = (try? FileManager.default.contentsOfDirectory(atPath: s.paths.callDirectory(callID).path)) ?? []
        let move = MoveOut.load(callID, paths: s.paths)
        // A ledger of this id that does not read (damaged, or of a newer build) is never replaced.
        if move == nil, MoveOut.leftIDs(s.paths).contains(callID) { return .refused(MoveWords.inWork) }
        // A call marked during its recording that waits here (its move ended, or its profile is gone) may go to
        // another profile: the mark changes in one write, so it is never unmarked in between.
        var replacing: String?
        switch MoveRules.offer(r, busy: await s.pipeline.isBusy(callID), files: names, usage: s.usage(callID), move: move) {
        case .offer: break
        case .moving(let to) where to == target && move == nil: break
        case .moving(let to) where afterCall && move == nil: replacing = to
        case .refused(let words): return .refused(words)
        case .hidden, .moving: return .refused(MoveWords.inWork)
        }
        let out = MoveOut(callID: callID, to: target, started: s.now(), afterCall: afterCall)
        // A new move of the id: the reason of the last one is no longer news.
        MoveEnded.shown(callID, paths: s.paths)
        // The ledger first: a record marked with no ledger would never be processed nor moved.
        do {
            try s.stop("start: save the ledger")
            try out.save(s.paths)
        } catch is MoveStop {
            return .refused("")
        } catch {
            return .refused(MoveWords.refusal(.copyFailed, target: name ?? target) ?? "")
        }
        // A stop here leaves the ledger with no mark: the copy step sets the mark again first.
        do { try s.stop("start: mark the record") } catch { return .refused("") }
        let marked = if let replacing { await s.pipeline.setMoveTarget(callID: callID, target, replacing: replacing) }
            else { await s.pipeline.setMoveTarget(callID: callID, target) }
        guard marked else {
            MoveOut.delete(callID, paths: s.paths)
            return .refused(MoveWords.inWork)
        }
        return .started
    }

    /// `unreadable`: this profile's own ledger of the move does not read; nothing changed.
    public enum CancelAnswer: Equatable, Sendable { case cancelled, tooLate, unreachable, unreadable }

    /// The owner's Cancel. It waits for an advance of this id that runs, so a copy that ends meanwhile never writes
    /// over it. `tooLate`: the target has the marker (it claimed it). `unreachable`: the target's folder or the registry
    /// cannot be read now, and nothing changed: a marker that may be in the target is never left behind.
    public func cancelMove(_ callID: String) async -> CancelAnswer {
        let answer: CancelAnswer = await exclusiveWaiting(callID) {
            guard var out = MoveOut.load(callID, paths: s.paths) else {
                // No ledger is no move. A ledger that is there and does not read is not known: never "cancelled".
                return MoveOut.leftIDs(s.paths).contains(callID) ? .unreadable : .cancelled
            }
            if out.state == .cancelling { return .cancelled }
            guard [.copying, .copied, .waiting].contains(out.state) else { return .tooLate }
            do {
                switch s.target(out.to) {
                case .unknown:
                    return .unreachable
                case .paths(let b):
                    let folder = MoveMarker.folder(callID, in: b)
                    switch MoveMarker.look(folder) {
                    case .incoming(let m) where m.isMine(of: out):
                        try s.stop("cancel: take back")
                        guard MoveMarker.takeBack(folder) else { return .tooLate }
                    case .claimed(let m) where m.isMine(of: out):
                        return .tooLate
                    case .unknown:
                        return .unreachable
                    default: break
                    }
                case .gone:
                    break
                }
                try s.stop("cancel: save cancelling")
                out.state = .cancelling
                out.cancel = .byOwner
                try out.save(s.paths)
                return .cancelled
            } catch {
                // The marker may be taken back already: the next run reads it and ends the cancel.
                return .unreachable
            }
        }
        if answer == .cancelled { _ = await run(callID) }
        return answer
    }

    /// "Try again" on a removal that waits: its step runs now, not at the end of its wait.
    public func tryAgain(_ callID: String) async -> Event {
        let reset: Bool = await exclusiveWaiting(callID) {
            guard var out = MoveOut.load(callID, paths: s.paths), out.lastTry != nil else { return false }
            out.lastTry = nil
            return (try? out.save(s.paths)) != nil
        }
        guard reset else { return .nothing }
        return await run(callID)
    }

    /// The owner's Cancel: false when it did not happen (`cancelMove` says why).
    public func cancel(_ callID: String) async -> Bool {
        await cancelMove(callID) == .cancelled
    }

    // MARK: Advance

    public func run(_ callID: String) async -> Event {
        var last = Event.nothing
        for _ in 0..<40 {
            last = await advance(callID)
            if last != .working { return last }
        }
        return last
    }

    /// Every move that is not done; and a done one whose folder in the target is still there, so it goes.
    public func runAll() async -> [String: Event] {
        var out: [String: Event] = [:]
        for m in MoveOut.all(s.paths).moves {
            if m.state == .done {
                guard case .paths(let b) = s.target(m.to), FileManager.default.fileExists(atPath: MoveMarker.folder(m.callID, in: b).path) else { continue }
                _ = await advance(m.callID)
                continue
            }
            out[m.callID] = await run(m.callID)
        }
        return out
    }

    public func advance(_ callID: String) async -> Event {
        await exclusive(callID, .waiting) { (try? await step(callID)) ?? .waiting }
    }

    /// A move "after the call" whose end was not the owner's own Cancel keeps the call's mark: it is not processed here.
    public static func keepsMark(afterCall: Bool, why: MovePlan.Cancel) -> Bool { afterCall && why != .byOwner }

    private func step(_ callID: String) async throws -> Event {
        guard MovePaths.isID(callID), var out = MoveOut.load(callID, paths: s.paths), MovePaths.isID(out.to), MovePaths.isToken(out.token) else { return .nothing }
        let begun = out.state
        let place = s.target(out.to)
        var targetPaths: Paths?
        if case .paths(let p) = place { targetPaths = p }
        let look: MoveMarker.Look = targetPaths.map { MoveMarker.look(MoveMarker.folder(callID, in: $0)) } ?? (place == .gone ? .missing : .unknown)
        let part = targetPaths.map { MoveCopy.hasPart(callID, token: out.token, incoming: $0.incoming) } ?? false
        let step = MovePlan.source(out, marker: look, part: part, target: place.plan)
        func save(_ state: MoveOut.State, cancel: MovePlan.Cancel? = nil) throws {
            try s.stop("save \(state.rawValue)")
            // Read again: a ledger that changed since this step read it is never written over.
            guard let now = MoveOut.load(callID, paths: s.paths), now.state == begun, now.token == out.token else { throw Overtaken() }
            out.state = state
            if let cancel { out.cancel = cancel }
            try out.save(s.paths)
        }
        switch step {
        case .copy:
            guard let b = targetPaths else { return .waiting }
            // The mark goes with the ledger; set again here, as a stop can come between the two at the start.
            if !(await s.pipeline.setMoveTarget(callID: callID, out.to)), out.afterCall,
               let old = (try? CallRecord.load(from: s.paths.callDirectory(callID)))?.moveTo, old != out.to {
                // A new mark of a held call that a stop cut short at its start.
                _ = await s.pipeline.setMoveTarget(callID: callID, out.to, replacing: old)
            }
            do {
                var fetched: URL?
                let dir = s.paths.callDirectory(callID)
                let record = try CallRecord.load(from: dir)
                if MoveCopy.needsFetch(record, in: dir) {
                    // A backup copy with no hash cannot be checked whole: the move does not stand on it.
                    guard record.cloudHash != nil else { try save(.cancelling, cancel: .backupFailed); return .working }
                    try s.stop("download")
                    fetched = await s.fetch(record, s.paths.moves.appendingPathComponent("\(callID).download"))
                    guard fetched != nil else { try save(.cancelling, cancel: .backupFailed); return .working }
                }
                let plan = try MoveCopy.plan(callID, in: s.paths, to: out.to, owner: OwnerIdentity.read(name: s.ownerName(), paths: s.paths), fetched: fetched)
                if s.room(plan.bytes, b.incoming) == false { try save(.cancelling, cancel: .noRoom); return .working }
                let progress = s.progress
                let token = out.token, from = s.profileID, now = s.now(), stop = s.stop
                _ = try await Task.detached(priority: .utility) {
                    try MoveCopy.write(plan, from: from, token: token, incoming: b.incoming, now: now, progress: { progress(callID, $0) }, stop: stop)
                }.value
                if let fetched { try? FileManager.default.removeItem(at: fetched.deletingLastPathComponent()) }
                try save(.copied)
            } catch is MoveStop {
                throw MoveStop()
            } catch is Overtaken {
                throw Overtaken()
            } catch {
                Log.error("Move: the copy failed; the meeting stays here: \(error)")
                try save(.cancelling, cancel: MoveCopy.isOutOfSpace(error) ? .noRoom : .copyFailed)
            }
            return .working
        case .publish:
            guard let b = targetPaths else { return .waiting }
            do {
                try MoveCopy.publish(callID, token: out.token, incoming: b.incoming, stop: s.stop)
            } catch is MoveStop {
                throw MoveStop()
            } catch is MoveFiles.OtherVolume {
                try save(.cancelling, cancel: .copyFailed)
            } catch {
                // Another move holds `Incoming/<id>`: wait.
                return .waiting
            }
            return .working
        case .markWaiting:
            try save(.waiting)
            return .working
        case .wait:
            return .waiting
        case .remove:
            if out.state == .waiting { try save(.removing) }
            // A step that failed waits longer after each try (`MoveRetry`); "Try again" clears the time of the last.
            guard MoveRetry.due(tries: out.tries ?? 0, last: out.lastTry, now: s.now()) else { return .waiting }
            let before = out.nextStep
            let ownerName = s.ownerName()
            try await MoveRemoval.advance(&out, paths: s.paths, library: s.library, ownerName: ownerName, actions: s.actions, now: s.now(), stop: s.stop)
            let progressed = out.nextStep != before
            if progressed { out.tries = nil; out.lastTry = nil; out.waitsAt = nil; out.because = nil; out.waitsSince = nil }
            guard let waits = out.nextStep else {
                if progressed { try out.save(s.paths) }
                return .working
            }
            let kind = MoveRemoval.waitKind(waits, library: s.library)
            if out.waitsAt != waits.rawValue || out.because != kind {
                // Logged once for each change of where and why, never at each look.
                Log.info("Move: the removal of \(callID) waits at its \(waits.rawValue) step (\(kind.rawValue))")
                out.tries = 0
                out.waitsSince = s.now()
            }
            out.tries = (out.tries ?? 0) + 1
            out.lastTry = s.now()
            out.waitsAt = waits.rawValue
            out.because = kind
            try out.save(s.paths)
            return .waiting
        case .cleanUp(let removeIncoming):
            if let b = targetPaths, MoveCopy.hasPart(callID, token: out.token, incoming: b.incoming) {
                try s.stop("remove the part")
                try? FileManager.default.removeItem(at: MoveCopy.part(callID, token: out.token, incoming: b.incoming))
            }
            if removeIncoming, let b = targetPaths {
                try s.stop("remove the target's Incoming folder")
                try? FileManager.default.removeItem(at: MoveMarker.folder(callID, in: b))
                return .working
            }
            if out.state == .done { return .nothing }
            try save(.done)
            return .moved(to: out.to)
        case .cancel(let why):
            try save(.cancelling, cancel: why)
            return .working
        case .takeBack:
            if let b = targetPaths {
                try s.stop("take back")
                _ = MoveMarker.takeBack(MoveMarker.folder(callID, in: b))
            }
            return targetPaths == nil ? .waiting : .working
        case .finishCancel(let removeIncoming):
            try s.stop("remove the download")
            try? FileManager.default.removeItem(at: s.paths.moves.appendingPathComponent("\(callID).download"))
            if let b = targetPaths {
                if removeIncoming {
                    try s.stop("remove the cancelled folder")
                    try? FileManager.default.removeItem(at: MoveMarker.folder(callID, in: b))
                }
                try s.stop("remove the part")
                try? FileManager.default.removeItem(at: MoveCopy.part(callID, token: out.token, incoming: b.incoming))
            }
            let why = out.cancel ?? .byOwner
            // A call the owner marked for the other profile during its recording keeps its mark when the move failed:
            // nothing of it is sent from here until the owner chooses ("Process here", or "Move to" again).
            if !MoveSource.keepsMark(afterCall: out.afterCall, why: why) {
                try s.stop("take the mark off")
                guard await s.pipeline.setMoveTarget(callID: callID, nil) else {
                    Log.error("Move: the mark of a cancelled move could not be taken off; the next look tries again")
                    return .waiting
                }
            }
            // A reason the owner did not give is kept until the window app has shown it (a worker may end this).
            if why != .byOwner {
                try s.stop("keep the reason")
                try MoveEnded(callID: callID, to: out.to, why: why, afterCall: out.afterCall, at: s.now()).save(s.paths)
            }
            try s.stop("delete the ledger")
            MoveOut.delete(callID, paths: s.paths)
            return .cancelled(why)
        case .nothing:
            return out.state == .done ? .moved(to: out.to) : .nothing
        }
    }
}
