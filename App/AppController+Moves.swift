import Foundation
import MossadCore

/// The window app's look at a move, for its own profile: its own moves go on (a removal after the target took the
/// meeting in, or a cancel), and a meeting that another profile moved here is taken in, as a worker does. Only with two profiles or
/// more (`MoveRules.looks`): with one there is no look, no timer, and no folder.
struct MoveLook {
    var running = false
    var again = false
    var timer: Task<Void, Never>?
}

extension AppController {
    /// One look at a time; a call during a look asks for one more. Off the main actor. A look that finds nothing reads
    /// two folder names and ends (`MoveRules.hasWork`).
    func checkMoves() {
        guard MoveRules.looks(mode: mode, liveProfiles: profiles.registry.live.count), library.identity != nil, let pipeline else { return }
        if moveLook.running {
            moveLook.again = true
            return
        }
        moveLook.running = true
        let halves = moveHalves(pipeline)
        let paths = paths
        Task.detached(priority: .utility) { [weak self] in
            var ended = false
            var taken: [String] = []
            while true {
                if MoveRules.hasWork(paths) {
                    let events = await halves.source.runAll()
                    for (callID, event) in events.sorted(by: { $0.key < $1.key }) {
                        switch event {
                        case .moved:
                            ended = true
                            Log.info("Moves: a meeting moved to another profile (\(callID))")
                        case .cancelled(let why):
                            ended = true
                            Log.info("Moves: a move ended without moving (\(callID), \(why.rawValue))")
                        default: break
                        }
                    }
                    let here = halves.intake.run()
                    for callID in here { Log.info("Moves: a meeting moved here from another profile (\(callID))") }
                    taken += here
                }
                let again = await MainActor.run { () -> Bool in
                    guard let self else { return false }
                    let again = self.moveLook.again
                    self.moveLook.again = false
                    if !again { self.moveLook.running = false }
                    return again
                }
                if !again { break }
            }
            guard ended || !taken.isEmpty else { return }
            await MainActor.run {
                guard let self else { return }
                self.refresh()
                self.syncNow()
                self.coachVersion += 1
                if !taken.isEmpty { self.processPending() }
            }
        }
    }

    /// The owner's delete of a meeting whose move waits: the move is cancelled first, when the other profile has not
    /// claimed the copy yet. True when the delete may go on. A refusal is logged with its sentence; the row shows it
    /// once the moves have their line on the page.
    func cancelMoveBeforeDelete(_ callID: String) async -> Bool {
        guard let pipeline, let r = try? CallRecord.load(from: paths.callDirectory(callID)), let target = r.moveTo else { return true }
        let name = profiles.registry.profile(target)?.name ?? target
        let answer = await moveHalves(pipeline).source.cancelMove(callID)
        guard answer == .cancelled, (try? CallRecord.load(from: paths.callDirectory(callID)))?.moveTo == nil else {
            Log.info("Moves: a delete was refused: \(answer == .unreachable ? MoveWords.unreachable : MoveWords.moving(to: name))")
            return false
        }
        return true
    }

    /// The look every 15 s, made only when the look runs at all.
    func startMoveLook() {
        guard moveLook.timer == nil, MoveRules.looks(mode: mode, liveProfiles: profiles.registry.live.count) else { return }
        moveLook.timer = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(MoveRules.look))
                self?.checkMoves()
            }
        }
    }

    /// The two halves with this app's own objects. The removal's changes of what the app holds in memory (the coach's
    /// memory, the share links, the reads) go through the app's own paths, on the main actor.
    private func moveHalves(_ pipeline: Pipeline) -> (source: MoveSource, intake: MoveIntake) {
        let paths = paths, library = library, usage = usage, archive = cloudArchive
        let owner = ownerName, prints = voiceFingerprints, backs = mode.does(.backup)
        let identity = AppIdentity.current, env = ProcessInfo.processInfo.environment
        let home = FileManager.default.homeDirectoryForCurrentUser
        let madeUp = identity.madeUpRegistry
        let file = madeUp ? env["MOSSAD_PROFILES"].map { URL(fileURLWithPath: $0) } : ProfileRegistry.fileURL(home: home)
        let actions = MoveRemoval.Actions(
            forgetPersona: { id in Self.onMain { self.forgetPersona(id) } },
            coach: { change in try Self.onMain { _ = try self.changeCoachProfile(change) } },
            stopShares: { callID in Self.onMain { self.stopSharing(callID: callID) } },
            backup: { r in
                // A copy that cannot be removed now is remembered by the archive, and tried again at each pass.
                if backs, let archive { await archive.delete(r) } else { CloudArchive.rememberDeletes(of: r, paths: paths) }
                return true
            },
            removeFolder: { await pipeline.removeMoved(callID: $0, target: $1) })
        let source = MoveSource(MoveSource.Setup(
            paths: paths, profileID: identity.profile.id, pipeline: pipeline, library: library, ownerName: { owner },
            target: { id in file.map { MoveRules.target(id, registryFile: $0, home: home, madeUpRegistry: madeUp) } ?? .unknown },
            fetch: { r, folder in
                guard backs, let archive else { return nil }
                return await archive.fetch(r, into: folder)
            },
            usage: { usage.events(forCall: $0).events }, actions: actions))
        let intake = MoveIntake(paths: paths, me: identity.profile.id, library: library, ownerName: { owner }, voiceFingerprints: { prints })
        return (source, intake)
    }

    /// A change of what the app holds, from the look's thread: on the main actor, and at once when already there.
    nonisolated private static func onMain<T: Sendable>(_ body: @MainActor () throws -> T) rethrows -> T {
        if Thread.isMainThread { return try MainActor.assumeIsolated(body) }
        return try DispatchQueue.main.sync { try MainActor.assumeIsolated(body) }
    }
}
