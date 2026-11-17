import Foundation

/// A profile's background run: the meetings of a profile that is not the one in front go on to "written", with their
/// sync, backup, and what follows each meeting, and nothing else. Every duty asks `RunMode.worker.runs` first, so the
/// table of Task 2 is the one place that says what a worker does. A stop is the end of the process: every step it
/// may be in is resumable from its last saved record, as after a Quit.
public actor ProfileWorker {
    public struct Setup: Sendable {
        public var paths: Paths
        public var settings: ServiceSettings
        public var key: @Sendable (APIKey) -> String?
        public var google: any GoogleSecrets
        /// A setting the worker saves: "personaSince", "commitmentsSince".
        public var remember: @Sendable (String, Double) -> Void
        public var hasICloud: Bool
        public var madeUpRegistry: Bool
        public var macCalendarAuthorized: @Sendable () -> Bool
        public var callRecords: @Sendable () -> Bool
        public var now: @Sendable () -> Date
        /// This profile's id: a moved meeting is taken in only when its marker is addressed to it.
        public var profileID: String = "default"
        /// Where another profile's folder is now: `MoveRules.target` with the registry read again at each call.
        public var target: @Sendable (String) -> MoveRules.TargetPlace = { _ in .unknown }
        /// The DEBUG proofs: the process ends when a move's ledger says "copied", or a take-in says "takingIn"; "refuse"
        /// makes the take-in's rename into `Audio` fail as on another volume, after its first half.
        public var proofStop: String? = nil
        /// The DEBUG proof of a Cancel during a long copy: the copy waits this long at its first file.
        public var proofHold: TimeInterval? = nil

        public init(paths: Paths, settings: ServiceSettings, key: @escaping @Sendable (APIKey) -> String?, google: any GoogleSecrets,
                    remember: @escaping @Sendable (String, Double) -> Void, hasICloud: Bool, madeUpRegistry: Bool,
                    macCalendarAuthorized: @escaping @Sendable () -> Bool, callRecords: @escaping @Sendable () -> Bool,
                    now: @escaping @Sendable () -> Date) {
            self.paths = paths
            self.settings = settings
            self.key = key
            self.google = google
            self.remember = remember
            self.hasICloud = hasICloud
            self.madeUpRegistry = madeUpRegistry
            self.macCalendarAuthorized = macCalendarAuthorized
            self.callRecords = callRecords
            self.now = now
        }
    }

    /// The services the worker uses: a test gives fakes; the worker builds them from `settings`.
    public struct Services: Sendable {
        public var transcriber: Transcribing
        public var summarizer: Summarizing?
        public var embeddings: EmbeddingProvider
        public var calendar: CalendarSource
        public var llm: (any LanguageModel)?
        public var main: CloudSync?
        public var mirror: CloudSync?
        public var archive: CloudArchive?
        /// The text of the shared screens, read on this Mac (Vision), as the window app reads it.
        public var screenReader: ScreenTextReading?

        public init(transcriber: Transcribing, summarizer: Summarizing?, embeddings: EmbeddingProvider, calendar: CalendarSource,
                    llm: (any LanguageModel)?, main: CloudSync?, mirror: CloudSync?, archive: CloudArchive?,
                    screenReader: ScreenTextReading? = nil) {
            self.transcriber = transcriber
            self.summarizer = summarizer
            self.embeddings = embeddings
            self.calendar = calendar
            self.llm = llm
            self.main = main
            self.mirror = mirror
            self.archive = archive
            self.screenReader = screenReader
        }
    }

    public struct Pass: Equatable, Sendable {
        public var ran: Set<Duty> = []
        public var changed = false
        public var received = 0
    }

    /// The failures the status counts beside the records, shared with the pipeline's `onStep`.
    final class Failures: @unchecked Sendable {
        private let lock = NSLock()
        private var backup = 0, sync = false
        func set(backup: Int? = nil, sync: Bool? = nil) {
            lock.withLock {
                if let backup { self.backup = backup }
                if let sync { self.sync = sync }
            }
        }
        var values: (backup: Int, sync: Bool) { lock.withLock { (backup, sync) } }
    }

    private let setup: Setup
    private let services: Services
    private let library: VoiceLibrary
    private let usage: UsageLog
    private let pipeline: Pipeline
    private let failures = Failures()
    private var pace = WorkerPace()
    private var referencesReady = false
    private var configSent = false
    /// The worker's own count of changes, for the digest's key in place of the window app's three versions.
    private var changes = 0
    private var digestSent: String?
    private var digestPending: (key: String, parts: [SharedPayload])?
    private let moveSource: MoveSource
    private let moveIntake: MoveIntake
    /// The start dates this worker set, once each, so a later pass does not move them.
    private var personaSince: Double?
    private var commitmentsSince: Double?

    public init(_ setup: Setup, services given: Services? = nil) {
        self.setup = setup
        let paths = setup.paths, settings = setup.settings, key = setup.key
        let usage = UsageLog(directory: paths.usage)
        self.usage = usage
        let library = VoiceLibrary(directory: paths.voices)
        self.library = library
        let services = given ?? Self.build(setup, usage: usage)
        self.services = services
        let failures = failures
        let callRecords = setup.callRecords, now = setup.now
        // Where the invite is not matched (a made-up registry), a calendar that asks nothing and says it cannot read.
        let calendar: CalendarSource = RunMode.worker.runs(.inviteMatch, madeUpRegistry: setup.madeUpRegistry)
            ? services.calendar : WorkerCalendar(mac: .unknown, macSource: services.calendar, google: nil)
        let archive = services.archive
        pipeline = Pipeline(paths: paths, transcriber: services.transcriber, library: library, embeddings: services.embeddings,
                            calendar: calendar, summarizer: services.summarizer, notify: { _ in }, now: now,
                            ownerName: settings.ownerName, voiceFingerprints: settings.voiceFingerprints,
                            onStep: { _ in Self.writeStatus(paths: paths, settings: settings, key: key, failures: failures, now: now()) },
                            titles: { OrgChart.titleLines(for: $0, paths: paths, library: library) },
                            onDiscard: { record in Self.forget(record, paths: paths, archive: archive) },
                            heavy: HeavyWorkGate(isCallRecording: { callRecords() }, worker: true),
                            // The pipeline ties it to this gate (`ScreenStep.gated(by:)`): while any call records, it reads
                            // one frame at a time at background priority with a rest between frames, as in the window app.
                            screenStep: services.screenReader.map { ScreenStep(reader: $0) })
        (moveSource, moveIntake) = Self.moves(setup, pipeline: pipeline, library: library, usage: usage, archive: archive)
    }

    /// The two halves of a move in this worker. It goes on with a move of its own profile and never starts one.
    static func moves(_ setup: Setup, pipeline: Pipeline, library: VoiceLibrary, usage: UsageLog,
                      archive: CloudArchive?) -> (MoveSource, MoveIntake) {
        let paths = setup.paths, settings = setup.settings
        let backs = RunMode.worker.runs(.backup, madeUpRegistry: setup.madeUpRegistry)
        let actions = MoveRemoval.Actions(
            forgetPersona: { PersonaStore(paths: paths).delete($0) },
            coach: { change in
                var profile = try CoachProfile.load(from: paths.coach)
                let before = profile
                change(&profile)
                if profile != before { try profile.save(to: paths.coach) }
            },
            stopShares: { callID in
                // A share link is marked as stopping; the window app tells the server.
                var book = ShareBook.load(from: paths.shares)
                let before = book
                book.markStopping(callID: callID)
                if book != before { try? book.save(to: paths.shares) }
            },
            backup: { r in
                // A copy that cannot be removed now is remembered by the archive, and tried again at each pass.
                // The answer is the real one: a copy neither removed nor remembered leaves the step not done.
                if backs, let archive { return await archive.deleteForMove(r) }
                return CloudArchive.rememberDeletes(of: r, paths: paths)
            },
            removeFolder: { await pipeline.removeMoved(callID: $0, target: $1) })
        var stop: @Sendable (String) throws -> Void = { _ in }
        #if DEBUG
        let proof = setup.proofStop, hold = setup.proofHold
        if proof != nil || hold != nil {
            let once = ProofOnce()
            stop = { label in
                // The proof of a Cancel during a long copy: the copy waits at its first file.
                if let hold, label.hasPrefix("copy "), once.first() {
                    Log.info("Proof: the copy is held for \(Int(hold)) s")
                    Thread.sleep(forTimeInterval: hold)
                }
                guard let proof, Self.proofStops(proof, paths: paths) else { return }
                Log.info("Worker: stops for the proof at \(proof)")
                Log.flush()
                exit(0)
            }
        }
        #endif
        let source = MoveSource(MoveSource.Setup(
            paths: paths, profileID: setup.profileID, pipeline: pipeline, library: library, ownerName: { settings.ownerName },
            target: setup.target,
            fetch: { r, folder in
                guard backs, let archive else { return nil }
                return await archive.fetch(r, into: folder)
            },
            usage: { usage.events(forCall: $0).events }, actions: actions, now: setup.now, stop: stop),
            calling: setup.callRecords)
        var rename: @Sendable (String, String) -> Int32 = MoveFiles.exclusive
        #if DEBUG
        // The proof of a refusal after the first half: the rename into `Audio` meets "another volume".
        if setup.proofStop == "refuse" { rename = { from, to in to.hasPrefix(paths.audio.path + "/") ? EXDEV : MoveFiles.exclusive(from, to) } }
        #endif
        let intake = MoveIntake(paths: paths, me: setup.profileID, library: library, ownerName: { settings.ownerName },
                                voiceFingerprints: { settings.voiceFingerprints }, stop: stop, rename: rename)
        return (source, intake)
    }

    #if DEBUG
    final class ProofOnce: @unchecked Sendable {
        private let lock = NSLock()
        private var done = false
        func first() -> Bool { lock.withLock { defer { done = true }; return !done } }
    }

    /// The DEBUG proof of the owner's Cancel: cancels the move of this folder that is not done, as the menu would.
    public func proofCancel() async {
        guard let out = MoveOut.all(setup.paths).moves.first(where: { $0.state != .done }) else { return Log.info("Proof: no move to cancel") }
        let answer = await moveSource.cancelMove(out.callID)
        Log.info("Proof: the owner's Cancel of \(out.callID): \(answer)")
    }

    /// The proof's state on disk: a ledger of this folder that says "copied", or a claimed marker in its `Incoming`
    /// that says "takingIn".
    static func proofStops(_ proof: String?, paths: Paths) -> Bool {
        switch proof {
        case "copied":
            return MoveOut.all(paths).moves.contains { $0.state == .copied }
        case "takingIn":
            let names = (try? FileManager.default.contentsOfDirectory(atPath: paths.incoming.path)) ?? []
            return names.contains { name in
                if case .claimed(let m) = MoveMarker.look(paths.incoming.appendingPathComponent(name)) { return m.intake == .takingIn }
                return false
            }
        default:
            return false
        }
    }
    #endif

    /// The services from the profile's own settings and Keychain.
    static func build(_ setup: Setup, usage: UsageLog) -> Services {
        let s = setup.settings, key = setup.key, paths = setup.paths
        let server = s.serverConnection(key: key)
        let stores = s.syncStores(server: server, hasICloud: setup.hasICloud)
        let mac = WorkerCalendar.mac(authorized: setup.macCalendarAuthorized(), chosen: s.calendarIDs, madeUpRegistry: setup.madeUpRegistry)
        let macSource = EventKitCalendarSource()
        macSource.choose(s.calendarIDs.map(Set.init))
        let names = GoogleDirectoryCache.load(paths)?.names ?? [:]
        let google = GoogleCalendarSource(session: GoogleSession(secrets: setup.google, chosen: s.googleScopes), names: { names })
        return Services(transcriber: s.transcriber(key: key, usage: usage), summarizer: s.summarizer(key: key, usage: usage),
                        embeddings: FluidEmbeddingProvider(), calendar: WorkerCalendar(mac: mac, macSource: macSource, google: google),
                        llm: s.languageModel(key: key, usage: usage),
                        main: stores.main.map { CloudSync(paths: paths, store: $0.store) },
                        mirror: stores.mirror.map { CloudSync(paths: paths, store: $0.store) },
                        archive: s.archive(key: key, paths: paths, server: server), screenReader: VisionScreenReader())
    }

    private func runs(_ duty: Duty) -> Bool { RunMode.worker.runs(duty, madeUpRegistry: setup.madeUpRegistry) }
    private var calling: Bool { setup.callRecords() }

    // MARK: Start

    /// Recover, then the people store, then the status file.
    public func start() async -> Set<Duty> {
        var ran: Set<Duty> = []
        let paths = setup.paths
        if runs(.recover) {
            _ = ProcessingQueue(paths: paths).recoverInterrupted()
            await pipeline.continueSplitMeetings()
            ran.insert(.recover)
        }
        if runs(.people) {
            ran.insert(.people)
            if let identity = PeopleMigration.runAtLaunch(paths: paths, library: library, ownerName: setup.settings.ownerName,
                                                          notDuplicates: setup.settings.notDuplicates) {
                library.identity = identity
                _ = await pipeline.refreshLabels()
                do { _ = try OrgMatches.linkPeople(paths: paths) } catch { Log.error("People: the org matches by id were not saved: \(error)") }
                let people = identity.people.people
                let records = ProcessingQueue(paths: paths).allRecords()
                Self.linkCommitments(people: people, records: records, paths: paths)
                if setup.settings.coachEnabled { Self.linkCoach(people: people, records: records, paths: paths) }
            }
            referencesReady = true
        }
        if await moves() { ran.insert(.takeInMoved) }
        writeStatus()
        ran.insert(.statusFile)
        return ran
    }

    #if DEBUG
    /// The DEBUG proof: moves the one written meeting of this folder to that profile. A worker never starts a move
    /// otherwise. It waits up to a minute for the meeting to be written.
    public func proofMove(to profile: String) async {
        var written: [CallRecord] = []
        for _ in 0..<30 {
            written = ProcessingQueue(paths: setup.paths).allRecords().filter { $0.status == .written && $0.moveTo == nil }
            if written.count == 1 { break }
            try? await Task.sleep(for: .seconds(2))
        }
        guard written.count == 1, let r = written.first else { return Log.info("Proof: no one written meeting to move") }
        let started = await moveSource.start(r.id, to: profile)
        Log.info("Proof: the move of \(r.id) to \(profile): \(started)")
        if await moves() { _ = await pass([.queue], moved: true) }
    }
    #endif

    // MARK: Moves

    /// The duty `takeInMoved`: goes on with this profile's own moves, then takes in what waits. True when a meeting
    /// came in, left, or a move ended. A look that finds nothing reads two folder names and writes nothing.
    func moves() async -> Bool {
        guard runs(.takeInMoved), referencesReady, MoveRules.hasWork(setup.paths) else { return false }
        // Its own removals first: a meeting that comes back waits while this profile still removes it.
        let events = await moveSource.runAll()
        let ended = events.values.contains { event in
            switch event {
            case .moved, .cancelled: true
            default: false
            }
        }
        // The take-in hashes every file: it waits while a call records, and runs at the lowest priority.
        let callRecords = setup.callRecords, intake = moveIntake
        let takeIn = MoveWorkPlan.plan(.takeIn, callRecording: callRecords(), worker: true)
        let taken = takeIn == .hold ? [] : ((try? await HeavyWork.run(priority: takeIn.priority) {
            intake.run(held: { MoveWorkPlan.plan(.takeIn, callRecording: callRecords(), worker: true) == .hold })
        }) ?? [])
        for (callID, event) in events.sorted(by: { $0.key < $1.key }) {
            switch event {
            case .moved: Log.info("Worker: a meeting moved to another profile")
            case .cancelled(let why): Log.info("Worker: a move ended without moving (\(callID), \(why.rawValue))")
            default: break
            }
        }
        for callID in taken { Log.info("Worker: a meeting moved here from another profile (\(callID))") }
        return ended || !taken.isEmpty
    }

    // MARK: A pass

    public func pass(_ work: [WorkerPace.Work]) async -> Pass {
        await pass(work, moved: moves())
    }

    /// A pass after the look at the moves: the queue also runs when a meeting came in or left.
    private func pass(_ work: [WorkerPace.Work], moved: Bool) async -> Pass {
        var pass = Pass()
        let before = Self.stamp(setup.paths)
        if moved { pass.ran.insert(.takeInMoved) }
        if work.contains(.queue) || moved { await queueDuties(&pass) }
        if work.contains(.sync), !calling, runs(.sync) {
            await sync(&pass)
            if pass.received > 0 { await queueDuties(&pass) }
        }
        pass.changed = Self.stamp(setup.paths) != before
        if pass.changed { changes += 1 }
        writeStatus()
        pass.ran.insert(.statusFile)
        return pass
    }

    private func queueDuties(_ pass: inout Pass) async {
        let paths = setup.paths, settings = setup.settings
        if runs(.queue) {
            await pipeline.runPending()
            pass.ran.insert(.queue)
        }
        if runs(.backup), !calling {
            pass.ran.insert(.backup)
            let archive = services.archive
            Self.makeMissing(Recording.missing(audioRoot: paths.audio, hasBackup: { archive?.holds($0) ?? false }),
                             calling: { setup.callRecords() }, make: { Recording.makeIfMissing(in: $0) })
            if let archive {
                // Uploads only: the removal of old local copies waits for the window app, like retention.
                let report = await archive.sync(keepLocalDays: Self.keepLocalDays, pipeline: pipeline)
                failures.set(backup: report.failed.count)
            }
        }
        let llm = services.llm
        if runs(.coach), settings.coachEnabled, let llm {
            pass.ran.insert(.coach)
            let people: @Sendable () -> CoachPeople = { CoachPeople.read(paths: paths) }
            let library = library
            let runner = CoachRunner(paths: paths, coach: LLMCoach(llm: llm, ownerName: settings.ownerName, people: people), owner: settings.ownerName,
                                     since: Date(timeIntervalSince1970: settings.coachSince),
                                     titles: { OrgChart.titleLines(for: $0, paths: paths, library: library) })
            _ = await runner.run()
        }
        if runs(.personas), settings.coachEnabled, settings.personaEnabled, !calling,
           let made = PersonaExtractor.model(provider: settings.aiProvider, chosen: settings.aiModel, key: settings.aiProvider.key.flatMap(setup.key),
                                             usage: usage, serverURL: settings.localServerBase) {
            pass.ran.insert(.personas)
            // Set once, as the app's `personaSince`: the settings value is from the start, so the actor keeps it.
            var since = personaSince ?? settings.personaSince
            if since == 0 {
                since = setup.now().timeIntervalSince1970
                setup.remember("personaSince", since)
            }
            personaSince = since
            let usage = usage, callRecords = setup.callRecords
            let out = await PersonaBacklog.run(runner: PersonaRunner(paths: paths, llm: made.llm, owner: settings.ownerName), paths: paths,
                                               owner: settings.ownerName, model: made.name, service: made.service,
                                               since: Date(timeIntervalSince1970: since), referencesReady: referencesReady, callsPerRound: 10,
                                               spent: { from in usage.all().filter { $0.purpose == .persona && $0.date >= from }.reduce(0) { $0 + Pricing.cost($1) } },
                                               isLive: { callRecords() })
            let calls = out.newCalls.calls + out.olderCalls.calls
            if calls > 0 { Log.info("Worker: persona step read \(calls) calls") }
        }
        if runs(.commitments), let llm {
            pass.ran.insert(.commitments)
            var since = commitmentsSince ?? settings.commitmentsSince
            if since == 0 {
                since = setup.now().addingTimeInterval(-14 * 86_400).timeIntervalSince1970
                setup.remember("commitmentsSince", since)
            }
            commitmentsSince = since
            _ = await CommitmentRunner(paths: paths, finder: CommitmentFinder(llm: llm, ownerName: settings.ownerName),
                                       since: Date(timeIntervalSince1970: since)).run()
        }
        if runs(.nextTime), !calling, let llm, Self.hasOpenPoint(paths) {
            pass.ran.insert(.nextTime)
            // The upcoming meetings from the snapshot the window app wrote, never from the calendar.
            let events = CalendarSnapshot.load(from: paths.calendar)?.calendarEvents ?? []
            let records = ProcessingQueue(paths: paths).allRecords()
            let upcoming = UpcomingMeeting.from(events, limit: .max, recorded: records)
            let callRecords = setup.callRecords
            _ = await NextTimeRunner(paths: paths, checker: NextTimeChecker(llm: llm))
                .run(upcoming: upcoming, owner: settings.ownerName, directory: PersonDirectory(profiles: library.profiles),
                     ownerEmails: [settings.ownerEmail], aliases: SeriesCatalog.aliases(events)) { callRecords() }
        }
    }

    private func sync(_ pass: inout Pass) async {
        let settings = setup.settings, paths = setup.paths
        let server = settings.serverConnection(key: setup.key)
        let main = services.main, mirror = services.mirror
        if main == nil { CloudSync.nothingToMerge(paths: paths) }
        guard main != nil || mirror != nil else { return }
        pass.ran.insert(.sync)
        let personasHere = settings.personasInMCP, owner = settings.ownerName
        // The server's config once in a run, when a server is connected.
        if runs(.serverConfig), !configSent, let server {
            pass.ran.insert(.serverConfig)
            do {
                try await ServerClient(server).putConfig(owner: owner, personasInMCP: personasHere)
                configSent = true
            } catch {
                Log.error("Worker: telling the server the owner's name failed; it is tried again at the next sync: \(error)")
            }
        }
        let calling = setup.callRecords()
        let callRecords = setup.callRecords
        var makeDigest: (@Sendable () -> [SharedPayload]?)?
        var kept: [SharedPayload]?
        let key = DigestPlan.key(meetings: changes, coach: changes, commitments: changes, personas: personasHere, day: setup.now())
        if runs(.digest) {
            let step = DigestPlan.step(server: server != nil, calling: calling, meetingsLoaded: true, key: key, sent: digestSent, pending: digestPending?.key)
            if step == .resend { kept = digestPending?.parts }
            if step == .make {
                pass.ran.insert(.digest)
                let records = ProcessingQueue(paths: paths).allRecords()
                makeDigest = {
                    let tools = ChatTools(records: records, owner: owner, paths: paths, personaTraits: personasHere)
                    return ServerDigest.parts(tools, personasInMCP: personasHere, cache: DigestCache(directory: paths.sync), stop: callRecords)
                }
            }
        }
        let stores = settings.syncStores(server: server, hasICloud: false)
        let inputs = Self.syncInputs(main: main, mirror: mirror, stores: stores, server: server, owner: owner, personasHere: personasHere,
                                     calling: calling, callStarted: callRecords, kept: kept, makeDigest: makeDigest)
        let result = await SyncPass.run(inputs)
        if result.digestArrived {
            digestSent = key
            digestPending = nil
        } else if let digest = result.digest {
            digestPending = (key, digest)
        }
        pass.received = result.received
        failures.set(sync: result.failure != nil)
        pace.synced(ok: result.failure == nil, at: setup.now())
    }

    // MARK: The run

    /// Start, then passes by `WorkerPace`, for the life of the process.
    public func run() async {
        let id = AppIdentity.current.profile.id
        Log.info("Worker: started for \(id)")
        let mac = WorkerCalendar.mac(authorized: setup.macCalendarAuthorized(), chosen: setup.settings.calendarIDs, madeUpRegistry: setup.madeUpRegistry)
        switch mac {
        case .readable: Log.info("Worker: Mac calendars: readable")
        case .none: Log.info("Worker: Mac calendars: none chosen")
        case .unknown:
            Log.info(setup.settings.calendarIDs == nil && setup.macCalendarAuthorized()
                     ? "Worker: Mac calendars: not chosen yet" : "Worker: Mac calendars: not readable (\(EventKitCalendarSource.permissionName))")
        }
        _ = await start()
        while !Task.isCancelled {
            let now = setup.now()
            let (work, sleep) = pace.due(now: now, callRecords: calling)
            if !work.isEmpty {
                let syncsBefore = pace.lastSync
                let done = await pass(work)
                if work.contains(.queue) { pace.queued(at: now) }
                if work.contains(.sync), pace.lastSync == syncsBefore, !done.ran.contains(.sync) { pace.synced(ok: true, at: now) }
                if done.changed { pace.changed() }
                if done.changed || done.received > 0 {
                    Log.info("Worker: a pass changed meetings; \(done.received) changes from other devices")
                }
            }
            // Sleeps of 15 s at most, with a look at the moves after each: two folder listings when nothing waits.
            var slept: TimeInterval = 0
            while slept < sleep, !Task.isCancelled {
                let piece = min(MoveRules.look, sleep - slept)
                try? await Task.sleep(for: .seconds(piece))
                slept += piece
                guard MoveRules.hasWork(setup.paths), await moves() else { continue }
                let done = await pass([.queue], moved: true)
                if done.changed { pace.changed() }
            }
        }
    }

    // MARK: Parts

    private func writeStatus() {
        Self.writeStatus(paths: setup.paths, settings: setup.settings, key: setup.key, failures: failures, now: setup.now())
    }

    static func writeStatus(paths: Paths, settings: ServiceSettings, key: (APIKey) -> String?, failures: Failures, now: Date) {
        let f = failures.values
        let status = WorkerStatus.make(records: ProcessingQueue(paths: paths).allRecords(), incoming: MoveIntake.waitingCount(paths),
                                       missing: settings.missingKeys(key: key),
                                       backupFailed: f.backup, syncFailed: f.sync, now: now)
        do { try status.save(root: paths.root) } catch { Log.error("Worker: the status was not saved: \(error)") }
    }

    /// What changed on disk: each record's status and attempts.
    static func stamp(_ paths: Paths) -> [String: String] {
        Dictionary(ProcessingQueue(paths: paths).allRecords().map { ($0.id, "\($0.status.rawValue)|\($0.attempts)|\($0.cloudKey ?? "")") },
                   uniquingKeysWith: { a, _ in a })
    }

    /// A worker never removes a local recording: that waits for the window app, like retention.
    static let keepLocalDays: Int? = nil

    /// Makes the missing recordings one at a time, and stops when a call starts: that call gets the processor, and
    /// the rest waits for the next pass. Returns how many it made.
    @discardableResult
    static func makeMissing(_ dirs: [URL], calling: () -> Bool, make: (URL) -> Void) -> Int {
        var made = 0
        for dir in dirs {
            guard !calling() else { break }
            make(dir)
            made += 1
        }
        return made
    }

    /// The sync pass of a worker: no personas for the phone (the window app sends them) and no phone notices (the
    /// window app tells them).
    static func syncInputs(main: CloudSync?, mirror: CloudSync?, stores: ServiceSettings.SyncStores, server: ServerConnection?,
                           owner: String, personasHere: Bool, calling: Bool, callStarted: @escaping @Sendable () -> Bool,
                           kept: [SharedPayload]?, makeDigest: (@Sendable () -> [SharedPayload]?)?) -> SyncPass.Inputs {
        var inputs = SyncPass.Inputs(main: main, mirror: mirror, serverIsMain: stores.serverIsMain, place: stores.place, connection: server,
                                     owner: owner, personasInMCP: personasHere, personas: nil, calling: calling, callStarted: callStarted,
                                     keptDigest: kept, makeDigest: makeDigest)
        inputs.tellsRecordings = false
        return inputs
    }

    static func hasOpenPoint(_ paths: Paths) -> Bool {
        (try? NextTimeBook.load(from: paths.nextTime))?.points.contains(where: \.isOpen) == true
    }

    /// The four parts of the window app's `forget`, without the views.
    static func forget(_ record: CallRecord, paths: Paths, archive: CloudArchive?) {
        if record.cloudKey != nil || record.cloudLeftovers?.isEmpty == false {
            if let archive { Task { await archive.delete(record) } } else { CloudArchive.rememberDeletes(of: record, paths: paths) }
        }
        var book = ShareBook.load(from: paths.shares)
        book.markStopping(callID: record.id)
        try? book.save(to: paths.shares)
        if var coach = try? CoachProfile.load(from: paths.coach) {
            let before = coach
            coach.forget(callID: record.id)
            if coach != before { try? coach.save(to: paths.coach) }
        }
        _ = PersonaStore(paths: paths).forget(callID: record.id)
    }

    /// The commitments get the ids of their people, as the window app gives them.
    static func linkCommitments(people: [Person], records: [CallRecord], paths: Paths) {
        guard !people.isEmpty else { return }
        let refs = PersonReferences(people: people)
        let file = paths.commitments.appendingPathComponent(CommitmentBook.fileName)
        guard let book = try? CommitmentBook.load(from: paths.commitments), refs.refresh(book, records: records) != book,
              ReferenceBackup.keep(file, as: CommitmentBook.fileName, paths: paths) else { return }
        do { try refs.refresh(book, records: records).save(to: paths.commitments) } catch { Log.error("Worker: commitments were not saved: \(error)") }
    }

    /// What the coach knows of a person gets that person's id.
    static func linkCoach(people: [Person], records: [CallRecord], paths: Paths) {
        guard !people.isEmpty, var profile = try? CoachProfile.load(from: paths.coach) else { return }
        let before = profile
        _ = profile.linkPeople(CoachPeople(people: people), records: records)
        if profile != before { try? profile.save(to: paths.coach) }
    }
}
