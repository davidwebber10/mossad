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

    // MARK: Start and cancel

    public func start(_ callID: String, to target: String, afterCall: Bool = false) async -> Start {
        guard case .paths = s.target(target) else { return .refused(MoveWords.refusal(.targetGone, target: target) ?? MoveWords.inWork) }
        guard let r = try? CallRecord.load(from: s.paths.callDirectory(callID)) else { return .refused(MoveWords.inWork) }
        let names = (try? FileManager.default.contentsOfDirectory(atPath: s.paths.callDirectory(callID).path)) ?? []
        let move = MoveOut.load(callID, paths: s.paths)
        switch MoveRules.offer(r, busy: await s.pipeline.isBusy(callID), files: names, usage: s.usage(callID), move: move) {
        case .offer: break
        case .moving(let to) where to == target && move == nil: break
        case .refused(let words): return .refused(words)
        case .hidden, .moving: return .refused(MoveWords.inWork)
        }
        let out = MoveOut(callID: callID, to: target, started: s.now(), afterCall: afterCall)
        // The ledger first: a record marked with no ledger would never be processed nor moved.
        do { try out.save(s.paths) } catch { return .refused(MoveWords.refusal(.copyFailed, target: target) ?? "") }
        guard await s.pipeline.setMoveTarget(callID: callID, target) else {
            MoveOut.delete(callID, paths: s.paths)
            return .refused(MoveWords.inWork)
        }
        return .started
    }

    /// The owner's Cancel: false when the target has the marker (it claimed it).
    public func cancel(_ callID: String) async -> Bool {
        guard var out = MoveOut.load(callID, paths: s.paths), [.copying, .copied, .waiting].contains(out.state) else { return false }
        if case .paths(let b) = s.target(out.to) {
            let folder = MoveMarker.folder(callID, in: b)
            switch MoveMarker.look(folder) {
            case .incoming(let m) where m.isMine(of: out):
                guard MoveMarker.takeBack(folder) else { return false }
            case .claimed(let m) where m.isMine(of: out):
                return false
            default: break
            }
        }
        out.state = .cancelling
        out.cancel = .byOwner
        do { try out.save(s.paths) } catch { return false }
        _ = await run(callID)
        return true
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

    public func runAll() async -> [String: Event] {
        var out: [String: Event] = [:]
        for m in MoveOut.all(s.paths).moves where m.state != .done { out[m.callID] = await run(m.callID) }
        return out
    }

    public func advance(_ callID: String) async -> Event {
        await exclusive(callID, .waiting) { (try? await step(callID)) ?? .waiting }
    }

    private func step(_ callID: String) async throws -> Event {
        guard var out = MoveOut.load(callID, paths: s.paths) else { return .nothing }
        let place = s.target(out.to)
        var targetPaths: Paths?
        if case .paths(let p) = place { targetPaths = p }
        let look: MoveMarker.Look = targetPaths.map { MoveMarker.look(MoveMarker.folder(callID, in: $0)) } ?? (place == .gone ? .missing : .unknown)
        let part = targetPaths.map { MoveCopy.hasPart(callID, token: out.token, incoming: $0.incoming) } ?? false
        let step = MovePlan.source(out, marker: look, part: part, target: place.plan)
        func save(_ state: MoveOut.State, cancel: MovePlan.Cancel? = nil) throws {
            try s.stop("save \(state.rawValue)")
            out.state = state
            if let cancel { out.cancel = cancel }
            try out.save(s.paths)
        }
        switch step {
        case .copy:
            guard let b = targetPaths else { return .waiting }
            // The mark goes with the ledger; set again here, as a stop can come between the two at the start.
            _ = await s.pipeline.setMoveTarget(callID: callID, out.to)
            do {
                var fetched: URL?
                let dir = s.paths.callDirectory(callID)
                let record = try CallRecord.load(from: dir)
                if MoveCopy.needsFetch(record, in: dir) {
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
            } catch {
                Log.error("Move: the copy failed; the meeting stays here: \(error)")
                try save(.cancelling, cancel: .copyFailed)
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
            let ownerName = s.ownerName()
            try await MoveRemoval.advance(&out, paths: s.paths, library: s.library, ownerName: ownerName, actions: s.actions, now: s.now(), stop: s.stop)
            return out.nextStep == nil ? .working : .waiting
        case .cleanUp(let removeIncoming):
            if removeIncoming, let b = targetPaths {
                try s.stop("remove the target's Incoming folder")
                try? FileManager.default.removeItem(at: MoveMarker.folder(callID, in: b))
                return .working
            }
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
            if let b = targetPaths {
                if removeIncoming {
                    try s.stop("remove the cancelled folder")
                    try? FileManager.default.removeItem(at: MoveMarker.folder(callID, in: b))
                }
                try s.stop("remove the part")
                try? FileManager.default.removeItem(at: MoveCopy.part(callID, token: out.token, incoming: b.incoming))
            }
            try s.stop("take the mark off")
            _ = await s.pipeline.setMoveTarget(callID: callID, nil)
            try s.stop("delete the ledger")
            MoveOut.delete(callID, paths: s.paths)
            return .cancelled(out.cancel ?? .byOwner)
        case .nothing:
            return out.state == .done ? .moved(to: out.to) : .nothing
        }
    }
}
