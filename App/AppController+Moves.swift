import Foundation
import MossadCore

/// The window app's look at a move, for its own profile: its own moves go on (a removal after the target took the
/// meeting in, or a cancel), and a meeting that another profile moved here is taken in, as a worker does. Only with two profiles or
/// more (`MoveRules.looks`): with one there is no look, no timer, and no folder.
struct MoveLook {
    var running = false
    var again = false
    var timer: Task<Void, Never>?
    /// The reasons shown once in this run of the app.
    var shown: Set<String> = []
}

/// The confirmation of "Move to", with what the first profile already sent, read off the main actor.
struct MoveRequest: Identifiable {
    let record: CallRecord
    let target: Profile
    let sent: MoveRules.Sent
    let deletedChats: Int
    var id: String { record.id }
}

extension AppController {
    // MARK: What shows

    /// The other live profiles, in the registry's order: none with one profile, and none in a copy that may not move
    /// (a preview shows the menu of its made-up registry, and moves nothing).
    var moveTargets: [Profile] {
        guard AppIdentity.current.isPreview || MoveRules.mayMove(mode: mode, identity: .current, registry: profiles) else { return [] }
        return MoveRules.targets(profiles.registry, active: activeProfile.id)
    }

    /// A live profile's name; nil for one that is gone or `removing`.
    func profileName(_ id: String?) -> String? {
        guard let id else { return nil }
        return profiles.registry.live.first { $0.id == id }?.name
    }

    /// The row's move line of a meeting, from what the app holds in memory; nil for a meeting with no move.
    func moveRow(_ r: CallRecord) -> MoveShow.Row? {
        let move = moves[r.id]
        guard move != nil || r.moveTo != nil else { return nil }
        let to = move?.to ?? r.moveTo
        let held = moveEnded[r.id].flatMap { MoveWords.refusal($0.why, target: profileName($0.to) ?? MoveWords.otherProfile) }
        return MoveShow.row(r, move: move, name: profileName(to), copied: moveProgress[r.id], reach: to.map { moveReach[$0] ?? .open } ?? .open,
                            held: held, now: Date(), me: activeProfile.id)
    }

    /// The "Move to" items of a meeting, from the record in memory. The full check (its files, the usage log) runs
    /// off the main actor when an item is chosen.
    func moveMenu(_ r: CallRecord) -> MoveShow.Menu {
        let targets = moveTargets
        guard !targets.isEmpty || r.moveTo != nil else { return .none }
        if MoveShow.arriving(r, me: activeProfile.id) { return .none }
        let open = moves[r.id]
        let offer = MoveRules.offer(r, busy: progress[r.id] != nil, files: [], usage: [], move: open)
        return MoveShow.menu(offer, record: r, targets: targets, held: moveRow(r)?.held == true)
    }

    func isArriving(_ r: CallRecord) -> Bool { MoveShow.arriving(r, me: activeProfile.id) }

    /// The sentence in place of a chat's field while its meeting moves; nil when it may ask. Read before any request.
    /// Not the call that records now: its reasons are `LiveOffReason`.
    func chatOff(_ callID: String?) -> String? {
        guard let callID, var r = meetings.first(where: { $0.id == callID }), r.status != .recording else { return nil }
        if r.moveTo == nil, let to = moves[callID]?.to { r.moveTo = to }
        return MoveShow.chatOff(r, name: profileName(r.moveTo), me: activeProfile.id)
    }

    /// One line above the list, for its time. Text only.
    func showMoveLine(_ line: MoveShow.Line) {
        moveLine = line
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(line.lasts))
            if self?.moveLine == line { self?.moveLine = nil }
        }
    }

    /// A command that would change a meeting while its move waits: the sentence shows, and the command does nothing.
    func refusedForMove(_ callID: String) -> Bool {
        guard let r = meetings.first(where: { $0.id == callID }), r.status != .recording,
              let text = MoveShow.refusesCommand(r, name: profileName(r.moveTo), me: activeProfile.id) else { return false }
        showMoveLine(.refusal(text, at: Date()))
        return true
    }

    // MARK: "This call is for"

    /// The choice of a call: `callChoice` while that call records; after it, the mark on its record.
    func choice(forCall callID: String) -> MoveAfterCall.Choice {
        if let c = callChoice, c.callID == callID { return c.choice }
        return MoveAfterCall.choice(of: meetings.first { $0.id == callID }?.moveTo)
    }

    /// The panel's row while a call records; nil with one profile, or no call.
    var callForMenu: MoveAfterCall.Menu? {
        guard !moveTargets.isEmpty else { return nil }
        let callID: String
        if case .recording(_, let since) = status { callID = CallRecorder.callID(for: since) }
        // A preview shows the made-up call of `MOSSAD_CALL_FOR`; it records nothing.
        else if AppIdentity.current.isPreview, let c = callChoice { callID = c.callID } else { return nil }
        return MoveAfterCall.menu(profiles.registry, active: activeProfile.id, choice: choice(forCall: callID))
    }

    /// "This call is for ▸ <profile>". The record has the choice first (saved by the recorder, so a crash keeps it);
    /// for another profile the live transcript, its title, the names, the points' check, and the answer of a live
    /// chat stop, and `live.json` goes, so `current_call` has nothing to give. Taken back, nothing starts again.
    func setCallProfile(_ profileID: String) {
        guard !moveTargets.isEmpty, profileID == activeProfile.id || moveTargets.contains(where: { $0.id == profileID }) else { return }
        let callID: String
        if case .recording(_, let since) = status { callID = CallRecorder.callID(for: since) }
        else if AppIdentity.current.isPreview, let c = callChoice { callID = c.callID } else { return }
        let now = choice(forCall: callID)
        let next = MoveAfterCall.next(now, picked: profileID, active: activeProfile.id)
        guard next != now else { return }
        if AppIdentity.current.isPreview {
            callChoice = (callID, next)
            liveOff = MoveAfterCall.liveOff(next)
            return
        }
        let recorder = recorder, mark = next.moveTo
        CaptureQueue.queue.async {
            recorder.setMoveTarget(mark, forCall: callID)
            Task { @MainActor in self.refresh() }
        }
        callChoice = (callID, next)
        if case .other = next {
            stopLive()
            live.removeFile(paths.callDirectory(callID).appendingPathComponent(LiveTranscript.fileName))
            liveChatSessions[callID]?.stop()
            Log.info("Live: the call \(callID) is for another profile; nothing more of it is sent from here")
        }
        liveOff = MoveAfterCall.liveOff(next)
    }

    /// The end of a call marked for another profile: it moves as "recorded"; a move that fails or is refused keeps
    /// the mark (`MoveSource.keepsMark`), and the row offers "Process here" and "Move to".
    func moveAfterCall(_ callID: String, to profileID: String) {
        guard !AppIdentity.current.isPreview, let pipeline else { return }
        let source = moveHalves(pipeline).source
        Task {
            // A start that is refused leaves the mark: the call waits here, and the next look tries again.
            _ = await source.start(callID, to: profileID, name: profileName(profileID), afterCall: true)
            refresh()
            checkMoves()
        }
    }

    // MARK: The owner's acts

    /// "Move to ▸ <profile>": reads what was sent and which chats are deleted, off the main actor, then opens the
    /// confirmation; a meeting that may not move gets its sentence instead.
    func askMove(_ r: CallRecord, to target: Profile) {
        let dir = paths.callDirectory(r.id), usage = usage, chats = paths.chats
        let open = moves[r.id], busy = progress[r.id] != nil
        let others = Set(meetings.filter { $0.id != r.id }.map(\.title))
        if AppIdentity.current.isPreview {
            // `MOSSAD_MOVE_CHATS=<n>`: the chats a made-up meeting would lose.
            let chats = Int(ProcessInfo.processInfo.environment["MOSSAD_MOVE_CHATS"] ?? "") ?? 0
            moveRequest = MoveRequest(record: r, target: target, sent: MoveRules.sent(r, hasLiveFile: false, usage: []), deletedChats: chats)
            return
        }
        Task {
            let found = await Task.detached(priority: .userInitiated) { () -> (MoveRules.Offer, MoveRules.Sent, Int) in
                let files = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
                let events = usage.events(forCall: r.id).events
                let offer = MoveRules.offer(r, busy: busy, files: files, usage: events, move: open)
                let sent = MoveRules.sent(r, hasLiveFile: files.contains(LiveTranscript.fileName), usage: events)
                let mine = ChatStore(directory: chats).all().filter { $0.callID == r.id }
                return (offer, sent, MovedChats.split(mine, title: r.title, otherTitles: others).deleted.count)
            }.value
            switch found.0 {
            case .refused(let text): showMoveLine(.refusal(text, at: Date()))
            case .offer: moveRequest = MoveRequest(record: r, target: target, sent: found.1, deletedChats: found.2)
            case .moving where moveRow(r)?.held == true:
                moveRequest = MoveRequest(record: r, target: target, sent: found.1, deletedChats: found.2)
            case .moving(let to): showMoveLine(.refusal(MoveWords.moving(to: profileName(to) ?? MoveWords.otherProfile), at: Date()))
            case .hidden: break
            }
        }
    }

    /// The confirmation's "Move".
    func moveMeeting(_ callID: String, to profileID: String) {
        guard !AppIdentity.current.isPreview, let pipeline, moveTargets.contains(where: { $0.id == profileID }) else { return }
        let held = meetings.first { $0.id == callID }.map { moveRow($0)?.held == true } ?? false
        let name = profileName(profileID)
        let source = moveHalves(pipeline).source
        Task {
            let started = await source.start(callID, to: profileID, name: name, afterCall: held)
            if case .refused(let text) = started, !text.isEmpty { showMoveLine(.refusal(text, at: Date())) }
            if started == .started { moveEnded[callID] = nil }
            refresh()
            checkMoves()
        }
    }

    /// The row's Cancel: each of the four answers in words.
    func cancelMove(_ callID: String) {
        guard !AppIdentity.current.isPreview, let pipeline, let to = moves[callID]?.to ?? meetings.first(where: { $0.id == callID })?.moveTo else { return }
        let source = moveHalves(pipeline).source
        let name = profileName(to) ?? MoveWords.otherProfile
        Task {
            let answer = await source.cancelMove(callID)
            showMoveLine(.cancel(answer, target: name, at: Date()))
            refresh()
            checkMoves()
        }
    }

    /// "Process here" on a held call: the mark goes, and the call is processed in this profile.
    func processHere(_ callID: String) {
        guard !AppIdentity.current.isPreview, let pipeline, moves[callID] == nil else { return }
        let paths = paths
        Task {
            guard await pipeline.setMoveTarget(callID: callID, nil) else { return }
            await Task.detached { MoveEnded.shown(callID, paths: paths) }.value
            moveEnded[callID] = nil
            refresh()
            processPending()
        }
    }

    /// "Try again" on a removal that waits.
    func tryMoveAgain(_ callID: String) {
        guard !AppIdentity.current.isPreview, let pipeline else { return }
        let source = moveHalves(pipeline).source
        Task {
            if case .moved(let to) = await source.tryAgain(callID) { movedHere(callID, to: to) }
            checkMoves()
        }
    }

    private func movedHere(_ callID: String, to: String) {
        showMoveLine(.moved(to: profileName(to) ?? MoveWords.otherProfile, at: Date()))
        if selectedMeetingID == callID { selectedMeetingID = nil }
    }

    // MARK: The look

    /// One look at a time; a call during a look asks for one more. Off the main actor. A look that finds nothing reads
    /// the names in `Moves` and `Incoming` and ends (`MoveRules.hasWork`).
    func checkMoves() {
        guard MoveRules.looks(mode: mode, liveProfiles: profiles.registry.live.count), library.identity != nil, let pipeline else { return }
        // A second profile added since the launch gets its timer here.
        startMoveLook()
        if moveLook.running {
            moveLook.again = true
            return
        }
        moveLook.running = true
        var halves = moveHalves(pipeline)
        halves.source = MoveSource(halves.setup) { [weak self] id, share in
            Task { @MainActor in self?.moveProgress[id] = share }
        }
        // A call marked during its recording that has no move yet (a quit, a crash, a copy that failed to start):
        // its move starts now, or it waits for the owner.
        let recordingID = meetings.first { isLive($0) }?.id
        for r in meetings where r.status == .recorded && r.moveTo != nil && r.id != recordingID && moves[r.id] == nil && moveEnded[r.id] == nil {
            if case .move(let to) = MoveAfterCall.atEnd(r, targets: moveTargets.map(\.id)) { moveAfterCall(r.id, to: to) }
        }
        let paths = paths, home = FileManager.default.homeDirectoryForCurrentUser
        let targets = profiles.registry.live.filter { $0.id != activeProfile.id }
        let workerReach = Dictionary(uniqueKeysWithValues: targets.map { ($0.id, workers?.reach($0.id) ?? .open) })
        let place = halves.setup.target
        let flag = callFlag
        Task.detached(priority: MoveWorkPlan.plan(.smallStep, callRecording: flag.recording, worker: false).priority) { [weak self] in
            var moved: [(String, String)] = []
            var taken: [String] = []
            var ended = false
            while true {
                if MoveRules.hasWork(paths) {
                    let events = await halves.source.runAll()
                    for (callID, event) in events.sorted(by: { $0.key < $1.key }) {
                        switch event {
                        case .moved(let to): moved.append((callID, to)); ended = true
                        case .cancelled: ended = true
                        default: break
                        }
                    }
                    let here = MoveWorkPlan.plan(.takeIn, callRecording: flag.recording, worker: false) == .hold ? []
                        : halves.intake.run(held: { MoveWorkPlan.plan(.takeIn, callRecording: flag.recording, worker: false) == .hold })
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
            // What the rows show: the moves that are not done, the reasons kept, and why a target cannot take a meeting.
            let open = MoveOut.all(paths).moves.filter { $0.state != .done }
            let kept = MoveEnded.all(paths)
            let phoneChats = MovingChats.all(paths)
            var reach: [String: MoveShow.Reach] = [:]
            for (id, worker) in workerReach where open.contains(where: { $0.to == id }) {
                if case .paths = place(id) { reach[id] = worker } else { reach[id] = .unreachable }
            }
            await MainActor.run { [moved, taken, ended] in
                guard let self else { return }
                self.moves = Dictionary(uniqueKeysWithValues: open.map { ($0.callID, $0) })
                self.moveProgress = self.moveProgress.filter { id, _ in open.contains { $0.callID == id && $0.state == .copying } }
                self.moveReach = reach
                self.showEnded(kept)
                for (callID, n) in phoneChats.sorted(by: { $0.key < $1.key }) {
                    self.showMoveLine(.refusal(MoveWords.phoneChatsNotKept(n), at: Date()))
                    Task.detached { MovingChats.shown(callID, paths: paths) }
                }
                for (callID, to) in moved { self.movedHere(callID, to: to) }
                guard ended || !taken.isEmpty else { return }
                self.refresh()
                self.syncNow()
                self.coachVersion += 1
                if !taken.isEmpty { self.processPending() }
            }
        }
    }

    /// A reason kept in `Moves` shows once as the line. One of a call marked during its recording stays on the row
    /// until the owner chooses; any other goes once it showed.
    private func showEnded(_ kept: [MoveEnded]) {
        moveEnded = Dictionary(uniqueKeysWithValues: kept.filter(\.afterCall).map { ($0.callID, $0) })
        let paths = paths
        for e in kept where !moveLook.shown.contains(e.callID) {
            moveLook.shown.insert(e.callID)
            if let text = MoveWords.refusal(e.why, target: profileName(e.to) ?? MoveWords.otherProfile) {
                showMoveLine(.refusal(text, at: Date()))
            }
            if !e.afterCall { Task.detached { MoveEnded.shown(e.callID, paths: paths) } }
        }
    }

    /// The owner's delete of a meeting whose move waits: the move is cancelled first, when the other profile has not
    /// claimed the copy yet; a held call loses its mark. True when the delete may go on. A meeting with no mark in
    /// the list reads nothing (one profile reads nothing).
    func cancelMoveBeforeDelete(_ callID: String) async -> Bool {
        guard let r = meetings.first(where: { $0.id == callID }), let target = r.moveTo else { return true }
        guard !isArriving(r), let pipeline else {
            showMoveLine(.refusal(MoveWords.arriving, at: Date()))
            return false
        }
        let paths = paths
        let ledger = await Task.detached { MoveOut.leftIDs(paths).contains(callID) }.value
        if !ledger, moveRow(r)?.held == true {
            guard await pipeline.setMoveTarget(callID: callID, nil) else { return false }
            await Task.detached { MoveEnded.shown(callID, paths: paths) }.value
            return true
        }
        let answer = await moveHalves(pipeline).source.cancelMove(callID)
        let unmarked = await Task.detached { (try? CallRecord.load(from: paths.callDirectory(callID)))?.moveTo == nil }.value
        guard answer == .cancelled, unmarked else {
            let line: MoveShow.Line = answer == .cancelled
                ? .refusal(MoveWords.moving(to: profileName(target) ?? MoveWords.otherProfile), at: Date())
                : .cancel(answer, target: profileName(target) ?? MoveWords.otherProfile, at: Date())
            showMoveLine(line)
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
    func moveHalves(_ pipeline: Pipeline) -> (source: MoveSource, intake: MoveIntake, setup: MoveSource.Setup) {
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
                // A copy that cannot be removed now is remembered by the archive, and tried again at each pass. The
                // answer is the real one: a delete that was not remembered is not done.
                if backs, let archive { return await archive.deleteForMove(r) }
                return CloudArchive.rememberDeletes(of: r, paths: paths)
            },
            removeFolder: { await pipeline.removeMoved(callID: $0, target: $1) })
        var setup = MoveSource.Setup(
            paths: paths, profileID: identity.profile.id, pipeline: pipeline, library: library, ownerName: { owner },
            target: { id in file.map { MoveRules.target(id, registryFile: $0, home: home, madeUpRegistry: madeUp) } ?? .unknown },
            fetch: { r, folder in
                guard backs, let archive else { return nil }
                return await archive.fetch(r, into: folder)
            },
            usage: { usage.events(forCall: $0).events }, actions: actions)
        let flag = callFlag
        setup.calling = { flag.recording }
        let intake = MoveIntake(paths: paths, me: identity.profile.id, library: library, ownerName: { owner }, voiceFingerprints: { prints })
        return (MoveSource(setup), intake, setup)
    }

    /// A change of what the app holds, from the look's thread: on the main actor, and at once when already there.
    nonisolated private static func onMain<T: Sendable>(_ body: @MainActor () throws -> T) rethrows -> T {
        if Thread.isMainThread { return try MainActor.assumeIsolated(body) }
        return try DispatchQueue.main.sync { try MainActor.assumeIsolated(body) }
    }
}

extension MoveSource {
    /// The same setup with the copy's progress sent to the app.
    init(_ setup: Setup, progress: @escaping @Sendable (String, Double) -> Void) {
        var s = setup
        s.progress = progress
        self.init(s)
    }
}
