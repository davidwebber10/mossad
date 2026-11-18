import Darwin
import Foundation
import Synchronization

/// The cut of one recording into parts, when it held two calls, and the Delete of a meeting with everything Mossad
/// made of it. Both remove through `CallForget`, and both are resumable from their ledger.
extension Pipeline {
    /// `cut.json` in the original's folder (and, at its last phase, in the first part's): what a cut in progress did.
    /// Each phase is saved before its work starts. Before `published` a stop rolls the cut back; from it, the cut
    /// goes forward.
    public struct CutLedger: Codable, Equatable, Sendable {
        public static let fileName = "cut.json"
        public enum Phase: String, Codable, Sendable, CaseIterable { case copying, checked, published, forgetting, removed }

        public var original: String
        /// The parts' ids, in time order.
        public var ids: [String]
        public var cuts: [Cut]
        public var phase: Phase
        /// What goes to each part by time (the owner's ticks, the live chat).
        public var parts: [CallForget.CutPart]
        /// The removal steps of the original that ended.
        public var forgotten: [String] = []

        func save(in dir: URL) throws {
            let e = JSONEncoder()
            e.dateEncodingStrategy = .iso8601
            e.outputFormatting = [.sortedKeys]
            try e.encode(self).write(to: dir.appendingPathComponent(Self.fileName), options: .atomic)
            try Pipeline.sync(dir.appendingPathComponent(Self.fileName))
        }

        static func load(in dir: URL) -> CutLedger? {
            guard let data = try? Data(contentsOf: dir.appendingPathComponent(fileName)) else { return nil }
            let d = JSONDecoder()
            d.dateDecodingStrategy = .iso8601
            return try? d.decode(CutLedger.self, from: data)
        }
    }

    public enum CutError: LocalizedError, Equatable {
        case refused(String)
        case failed(String)

        public var errorDescription: String? {
            switch self {
            case let .refused(why): why
            case let .failed(why): "The cut failed and the recording is as it was: \(why)"
            }
        }
    }

    /// The suffix of a part's folder while it is made. No list, no queue, and no scan ever reads such a folder.
    public static let cuttingSuffix = ".cutting"

    static func sync(_ url: URL) throws {
        let handle = try FileHandle(forUpdating: url)
        defer { try? handle.close() }
        try handle.synchronize()
    }

    /// What the cut of `callID` would be: the reason it is refused, or the parts it makes. Reads only.
    public func cutPlan(callID: String, at cuts: [Cut]) -> (refusal: String?, record: CallRecord?, length: TimeInterval, parts: [CallRecord]) {
        cutPlan(callID: callID, at: cuts, ownRun: false)
    }

    /// `ownRun`: asked by the cut itself, which holds the call as in flight.
    private func cutPlan(callID: String, at cuts: [Cut], ownRun: Bool) -> (refusal: String?, record: CallRecord?, length: TimeInterval, parts: [CallRecord]) {
        let dir = paths.callDirectory(callID)
        guard MovePaths.isID(callID), let r = try? CallRecord.load(from: dir) else {
            return ("There is no meeting \(callID) in this profile.", nil, 0, [])
        }
        let lengths = Self.trackLengths(dir)
        let length = lengths.values.max() ?? 0
        if let why = diskRefusal(r, dir: dir, ownRun: ownRun) { return (why, r, length, []) }
        if let why = CutRecord.refusal(r, cuts: cuts, length: length, hasTracks: !lengths.isEmpty) { return (why, r, length, []) }
        let sorted = cuts.sorted { $0.at < $1.at }
        let parts = CutRecord.parts(of: r, at: sorted, ids: Array(repeating: "", count: sorted.count + 1), length: length)
        let ids = freeIDs(parts.map(\.start))
        return (nil, r, length, CutRecord.parts(of: r, at: sorted, ids: ids, length: length))
    }

    /// The refusals that need the disk or this actor: a call in work, a move that started, a merge or a cut in
    /// progress, a Delete in progress.
    private func diskRefusal(_ r: CallRecord, dir: URL, ownRun: Bool) -> String? {
        let fm = FileManager.default
        if !ownRun, inFlight.contains(r.id) { return "The meeting is being processed now. Try again when it is done." }
        if fm.fileExists(atPath: dir.appendingPathComponent(MergePlan.fileName).path) { return "A merge of this meeting is in progress." }
        if fm.fileExists(atPath: dir.appendingPathComponent(CutLedger.fileName).path) { return "A cut of this meeting is in progress." }
        if r.moveTo != nil, fm.fileExists(atPath: MoveOut.url(r.id, paths: paths).path) { return "A move of this meeting to another profile has started." }
        if DeleteLedger.load(paths)?.contains(r.id) != false { return "The meeting is being deleted." }
        return nil
    }

    /// The length in seconds of each raw track that is there.
    static func trackLengths(_ dir: URL) -> [Track: TimeInterval] {
        var out: [Track: TimeInterval] = [:]
        for track in [Track.me, .them] {
            let url = dir.appendingPathComponent(track.fileName)
            guard FileManager.default.fileExists(atPath: url.path), let frames = try? AudioCut.frames(url) else { continue }
            out[track] = Double(frames) / TrackWriter.sampleRate
        }
        return out
    }

    /// One free id for each start, none taken by another of them.
    private func freeIDs(_ starts: [Date]) -> [String] {
        var taken: Set<String> = []
        return starts.map { start in
            var id = CallRecorder.freeID(for: start, in: paths)
            var n = 2
            let base = CallRecorder.callID(for: start)
            while taken.contains(id) || FileManager.default.fileExists(atPath: paths.callDirectory(id).path)
                || FileManager.default.fileExists(atPath: paths.audio.appendingPathComponent(id + Self.cuttingSuffix).path) {
                id = "\(base)-\(n)"
                n += 1
            }
            taken.insert(id)
            return id
        }
    }

    /// Cuts a recording into parts at `cuts` (seconds of its own timeline) and returns the parts' ids. Each part is a
    /// recording at `recorded`; the original is removed only after every part is on disk and checked, with
    /// everything Mossad made of it. Throws `CutError.refused` with plain words, and changes nothing then.
    @discardableResult
    public func cut(callID: String, at cuts: [Cut]) async throws -> [String] {
        let plan = cutPlan(callID: callID, at: cuts)
        if let why = plan.refusal { throw CutError.refused(why) }
        guard inFlight.insert(callID).inserted else { throw CutError.refused("The meeting is being processed now. Try again when it is done.") }
        defer { inFlight.remove(callID) }
        // Waits while a call records, unless the owner said "Process now"; then at a low priority.
        let clearance = await clearance(callID, .recordingCut)
        let dir = paths.callDirectory(callID)
        // Read again after the wait: the record or the tracks may have changed.
        let fresh = cutPlan(callID: callID, at: cuts, ownRun: true)
        if let why = fresh.refusal { throw CutError.refused(why) }
        guard fresh.record != nil else { throw CutError.refused("There is no meeting \(callID) in this profile.") }
        let sorted = cuts.sorted { $0.at < $1.at }
        let parts = fresh.parts
        var ledger = CutLedger(original: callID, ids: parts.map(\.id), cuts: sorted, phase: .copying,
                               parts: zip(parts, [0] + sorted.map(\.at)).map { CallForget.CutPart(id: $0.id, from: $1, start: $0.start, end: $0.end) })
        do {
            try ledger.save(in: dir)
            try cutStop("copying saved")
            let paths = paths
            let body: @Sendable () async throws -> Void = { try Self.copyParts(of: dir, parts: parts, cuts: sorted, paths: paths) }
            if clearance.usesLane { try await runHeavy(callID, .recordingCut, clearance, body) } else {
                try await HeavyWork.run(priority: .background, body)
            }
            try cutStop("copying done")
            ledger.phase = .checked
            try ledger.save(in: dir)
            try cutStop("checked saved")
            try Self.checkParts(of: dir, ids: ledger.ids, paths: paths)
            try cutStop("checked done")
        } catch let stop as CutStop {
            throw stop
        } catch {
            Log.error("Cutting \(callID) failed; the recording is as it was: \(error)")
            rollBackCut(in: dir, ledger)
            throw CutError.failed(error.localizedDescription)
        }
        try await goForward(dir: dir, ledger: ledger)
        Log.info("Cut \(callID) into \(ledger.ids.count) parts: \(ledger.ids.joined(separator: ", "))")
        return ledger.ids
    }

    /// Each part into `Audio/<id>.cutting/`: both tracks by a ranged copy, the frames of its range, the live marks of
    /// its range, and its record. A copy left by an earlier try is replaced.
    static func copyParts(of dir: URL, parts: [CallRecord], cuts: [Cut], paths: Paths) throws {
        let fm = FileManager.default
        let borders = [0] + cuts.map(\.at)
        let lengths = trackLengths(dir)
        let marks = LivePointMarks.load(from: dir)
        for (k, part) in parts.enumerated() {
            let from = borders[k], to: TimeInterval? = k + 1 < borders.count ? borders[k + 1] : nil
            let folder = paths.audio.appendingPathComponent(part.id + cuttingSuffix)
            if fm.fileExists(atPath: folder.path) { try fm.removeItem(at: folder) }
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            for (track, length) in lengths {
                // A track shorter than the cut (its capture stopped early) gives the later parts an empty file, so the
                // frames still add up.
                let start = min(from, length), end = to.map { min($0, length) }
                try AudioCut.copy(dir.appendingPathComponent(track.fileName), from: start, to: end, into: folder.appendingPathComponent(track.fileName))
            }
            try FrameStore.cut(in: dir, from: from, to: to, into: folder)
            for file in part.deletedScreens ?? [] { FrameStore.removeFrame(file, in: folder) }
            if let marks {
                let own = marks.divided(from: from, to: to)
                if !own.marks.isEmpty || !own.asks.isEmpty || own.rejected != nil { try own.save(to: folder) }
            }
            try part.save(to: folder)
            try sync(folder.appendingPathComponent(CallRecord.fileName))
        }
    }

    /// The frames of the parts add up to the original's, for each track, and each part's record reads.
    static func checkParts(of dir: URL, ids: [String], paths: Paths) throws {
        for track in [Track.me, .them] {
            let source = dir.appendingPathComponent(track.fileName)
            guard FileManager.default.fileExists(atPath: source.path) else { continue }
            let total = try AudioCut.frames(source)
            let sum = try ids.reduce(Int64(0)) { sum, id in
                try sum + AudioCut.frames(paths.audio.appendingPathComponent(id + cuttingSuffix).appendingPathComponent(track.fileName))
            }
            guard sum == total else { throw CutError.failed("the parts of \(track.fileName) hold \(sum) of \(total) frames") }
        }
        for id in ids {
            let r = try CallRecord.load(from: paths.audio.appendingPathComponent(id + cuttingSuffix))
            guard r.id == id else { throw CutError.failed("a part's record has another id") }
        }
    }

    /// Before `published`: the parts' folders go, and the original is as it was.
    private func rollBackCut(in dir: URL, _ ledger: CutLedger) {
        for id in ledger.ids { try? FileManager.default.removeItem(at: paths.audio.appendingPathComponent(id + Self.cuttingSuffix)) }
        try? FileManager.default.removeItem(at: dir.appendingPathComponent(CutLedger.fileName))
    }

    /// From `published` on: every part is put in place, the original is forgotten, then removed. A step that cannot
    /// end now keeps the ledger, and the next run goes on.
    private func goForward(dir: URL, ledger start: CutLedger) async throws {
        var ledger = start
        let fm = FileManager.default
        if ledger.phase.isBefore(.published) {
            ledger.phase = .published
            try ledger.save(in: dir)
            try cutStop("published saved")
        }
        if ledger.phase == .published {
            for id in ledger.ids {
                let made = paths.audio.appendingPathComponent(id + Self.cuttingSuffix), final = paths.callDirectory(id)
                if fm.fileExists(atPath: final.path) { continue }
                guard fm.fileExists(atPath: made.path) else {
                    // Neither the part nor its copy: the original stays, whole, and nobody removes it.
                    Log.error("A part \(id) of the cut of \(ledger.original) is missing; the original is kept")
                    return
                }
                guard Darwin.rename(made.path, final.path) == 0 else {
                    Log.error("Putting the part \(id) of \(ledger.original) in place failed; the next run tries again")
                    return
                }
                try cutStop("published \(id)")
            }
            try cutStop("published done")
            ledger.phase = .forgetting
            try ledger.save(in: dir)
            try cutStop("forgetting saved")
        }
        if ledger.phase == .forgetting {
            let actions = forgetActions(removeFolder: { _ in true })
            for step in CallForget.Step.allCases where step != .folder && !ledger.forgotten.contains(step.rawValue) {
                guard try await CallForget.run(step, callID: ledger.original, purpose: .cut(ledger.parts), paths: paths, library: library,
                                               ownerName: ownerName, actions: actions, now: now())
                else {
                    Log.error("The cut of \(ledger.original) waits at its \(step.rawValue) step; the next run goes on")
                    return
                }
                ledger.forgotten.append(step.rawValue)
                try ledger.save(in: dir)
            }
            try cutStop("forgetting done")
            ledger.phase = .removed
            // The ledger goes to the first part, then the original's folder goes, then the ledger.
            try ledger.save(in: paths.callDirectory(ledger.ids[0]))
            try cutStop("removed saved")
        }
        try finishRemoval(ledger)
    }

    /// The last phase: the original's folder and note go, then the ledger in the first part.
    private func finishRemoval(_ ledger: CutLedger) throws {
        guard try CallForget.removeFolder(ledger.original, paths: paths, outside: CallForget.deleting(paths), forgetLog: false,
                                          stop: { try self.cutStopSync($0) })
        else {
            Log.error("The folder of \(ledger.original) could not be removed after its cut; the next run tries again")
            return
        }
        heavy.forget(ledger.original)
        try cutStop("removed done")
        try? FileManager.default.removeItem(at: paths.callDirectory(ledger.ids[0]).appendingPathComponent(CutLedger.fileName))
        for id in ledger.ids { if let r = try? CallRecord.load(from: paths.callDirectory(id)) { onStep(r) } }
    }

    /// A cut that a crash or a quit stopped: rolled back before `published`, finished from it. A part's folder that no
    /// ledger names is a copy of a rolled-back cut and goes.
    public func finishInterruptedCuts() async {
        let fm = FileManager.default
        let dirs = (try? fm.contentsOfDirectory(at: paths.audio, includingPropertiesForKeys: nil)) ?? []
        var named: Set<String> = []
        for dir in dirs where !dir.lastPathComponent.hasSuffix(Self.cuttingSuffix) {
            guard fm.fileExists(atPath: dir.appendingPathComponent(CutLedger.fileName).path) else { continue }
            guard let ledger = CutLedger.load(in: dir) else {
                Log.error("A cut ledger in \(dir.lastPathComponent) could not be read; leaving the folder as it is")
                continue
            }
            named.formUnion(ledger.ids)
            guard !inFlight.contains(ledger.original) else { continue }
            inFlight.insert(ledger.original)
            defer { inFlight.remove(ledger.original) }
            do {
                if ledger.phase.isBefore(.published) {
                    rollBackCut(in: dir, ledger)
                    Log.info("Undid the interrupted cut of \(ledger.original)")
                } else if ledger.phase == .removed {
                    // The original's folder may still hold its own ledger at an earlier phase: the removal ends it.
                    try finishRemoval(ledger)
                    Log.info("Finished the interrupted cut of \(ledger.original)")
                } else if dir.lastPathComponent == ledger.original {
                    try await goForward(dir: dir, ledger: ledger)
                    Log.info("Went on with the interrupted cut of \(ledger.original)")
                }
            } catch {
                Log.error("The interrupted cut of \(ledger.original) stopped again: \(error)")
            }
        }
        for dir in dirs where dir.lastPathComponent.hasSuffix(Self.cuttingSuffix) {
            let id = String(dir.lastPathComponent.dropLast(Self.cuttingSuffix.count))
            guard !named.contains(id) else { continue }
            try? fm.removeItem(at: dir)
        }
    }

    // MARK: Delete

    /// Deletes a written or failed meeting with everything Mossad made of it (`CallForget`): its voice samples, the
    /// coach's memory of it, its tasks, its points' references (a point for that one meeting goes), its chats, its
    /// share links, its backup copy, its note, and its folder. No person goes. The removal is saved step by step in
    /// `deletes.json`, so a quit in the middle goes on at the next launch. Returns the record as it was on disk; nil
    /// when the delete is refused (the call records, is in work, or is marked for another profile).
    @discardableResult
    public func deleteMeeting(callID: String) async -> CallRecord? {
        let dir = paths.callDirectory(callID)
        guard MovePaths.isID(callID), !inFlight.contains(callID), let r = try? CallRecord.load(from: dir),
              r.status == .written || r.status == .failed, r.moveTo == nil,
              !FileManager.default.fileExists(atPath: dir.appendingPathComponent(CutLedger.fileName).path),
              var deletes = DeleteLedger.load(paths) else { return nil }
        if !deletes.contains(callID) {
            deletes.entries.append(.init(callID: callID, removed: [], started: now()))
            do { try deletes.save(paths) } catch {
                Log.error("Deleting \(callID) failed: \(error)")
                return nil
            }
        }
        await finishDeletes(only: callID)
        return r
    }

    /// The deletes that a quit stopped, or whose step waited, go on.
    public func finishDeletes() async { await finishDeletes(only: nil) }

    private func finishDeletes(only: String?) async {
        guard var deletes = DeleteLedger.load(paths) else {
            Log.error("The list of deletes in progress could not be read; nothing is removed now")
            return
        }
        for callID in deletes.entries.map(\.callID) where only == nil || only == callID {
            guard !inFlight.contains(callID) else { continue }
            inFlight.insert(callID)
            defer { inFlight.remove(callID) }
            let actions = forgetActions(removeFolder: { [paths] id in
                (try? CallForget.removeFolder(id, paths: paths, outside: CallForget.deleting(paths), forgetLog: false, stop: { _ in })) ?? false
            })
            while let i = deletes.entries.firstIndex(where: { $0.callID == callID }), let step = deletes.entries[i].nextStep {
                let done = (try? await CallForget.run(step, callID: callID, purpose: .delete, paths: paths, library: library,
                                                      ownerName: ownerName, actions: actions, now: now())) ?? false
                guard done else {
                    Log.error("Deleting \(callID) waits at its \(step.rawValue) step; the next run goes on")
                    break
                }
                deletes.entries[i].removed.append(step.rawValue)
                if deletes.entries[i].nextStep == nil {
                    deletes.entries.remove(at: i)
                    heavy.forget(callID)
                    Log.info("Deleted call \(callID)")
                }
                do { try deletes.save(paths) } catch {
                    Log.error("The list of deletes could not be saved: \(error)")
                    return
                }
            }
        }
    }

    // MARK: The caller's actions and the test's stops

    /// The owner's way to change the coach's memory, the share links, and the backup: the window app gives its own;
    /// a worker and a command keep the files' own (`CallForget.Actions.files`).
    public nonisolated func setForgetActions(_ actions: CallForget.Actions?) { forgetActionsBox.withLock { $0 = actions } }

    func forgetActions(removeFolder: @escaping @Sendable (String) async -> Bool) -> CallForget.Actions {
        var a = forgetActionsBox.withLock { $0 } ?? CallForget.Actions.files(paths: paths, removeFolder: removeFolder)
        a.removeFolder = removeFolder
        return a
    }

    /// For a test: a stop at a named point of the cut, as a crash there would leave it.
    func setCutStop(_ stop: (@Sendable (String) throws -> Void)?) { cutStopHookBox.withLock { $0 = stop } }

    func cutStop(_ point: String) throws { try cutStopSync(point) }

    nonisolated func cutStopSync(_ point: String) throws {
        guard let hook = cutStopHookBox.withLock({ $0 }) else { return }
        do { try hook(point) } catch { throw CutStop() }
    }
}

/// A stop of the cut that a test injects: nothing is cleaned up after it, as after a crash.
struct CutStop: Error {}

extension Pipeline.CutLedger.Phase {
    func isBefore(_ other: Self) -> Bool {
        Self.allCases.firstIndex(of: self)! < Self.allCases.firstIndex(of: other)!
    }
}
