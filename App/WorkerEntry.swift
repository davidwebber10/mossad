import AVFoundation
import Foundation
import MossadCore

/// The entry of a worker process: no window, no menu bar item, no Dock icon, and none of the window app's objects.
/// It never returns.
enum WorkerEntry {
    static func run(_ identity: AppIdentity) -> Never {
        // The app in front ignores SIGTERM and handles it itself, and a child keeps an ignored signal: a worker sets
        // its own. Until its watch handles the signal, SIGTERM ends it at once.
        signal(SIGTERM, SIG_DFL)
        signal(SIGINT, SIG_DFL)
        let arguments = CommandLine.arguments
        let home = FileManager.default.homeDirectoryForCurrentUser
        let env = ProcessInfo.processInfo.environment
        let paths = Paths.live
        // `signals: true`: the worker's own SIGTERM and SIGINT handling, set by itself (the app's are not inherited).
        let stuck = proofStuck(identity, env)
        let watcher = ForegroundWatcher(file: ForegroundState.url(home: home, environment: env), signals: !stuck) { why in
            if stuck { return Log.info("Worker: ignores the stop (\(why.rawValue)) for a proof") }
            Log.info("Worker: stops (\(why.rawValue))")
            Log.flush()
            exit(WorkerLaunch.Exit.stopped.rawValue)
        }
        var attempt: InstanceLock.Attempt?
        var settings: ServiceSettings?
        var worker: ProfileWorker?
        // `WorkerStart` is the order: nothing of the profile's folder is read or written before its lock is held.
        let stop = WorkerStart.run(.init(
            refusal: { WorkerLaunch.refusal(identity, arguments: arguments) },
            foreground: {
                #if DEBUG
                if arguments.contains("--probe") { probe(identity, arguments) }
                #endif
                if stuck { signal(SIGTERM, SIG_IGN) }
                if case .stop = watcher.first() { return false }
                return true
            },
            // The lock file lives in the folder: a profile whose folder is not there yet gets it, and nothing else.
            makeRoot: { try? FileManager.default.createDirectory(at: paths.root, withIntermediateDirectories: true) },
            // For the life of the process: a worker never runs beside the window app of its profile.
            lock: {
                let held = InstanceLock.acquire(root: paths.root)
                attempt = held
                return WorkerLaunch.afterLock(held) == nil
            },
            prepare: {
                try? paths.ensureDirectories()
                Log.directory = paths.logs
                _ = NetworkPath.shared
            },
            proofCall: {
                #if DEBUG
                // A made-up recorded call for a proof, on a made-up registry only, in an empty folder.
                if identity.madeUpRegistry, let file = env["MOSSAD_PROOF_CALL"], !hasMeetings(paths) {
                    importProofCall(URL(fileURLWithPath: file), paths: paths)
                }
                #endif
            },
            // A profile whose setup is not finished gets no worker.
            setupDone: {
                let read = ServiceSettings.read(.standard, fullUserName: NSFullUserName())
                settings = read
                return WorkerLaunch.setupDone(finished: read.setupDone, hasMeetings: hasMeetings(paths))
            },
            watch: { watcher.start() },
            run: {
                guard let settings else { return }
                worker = ProfileWorker(.init(paths: paths, settings: settings, key: { Keychain.app.get($0) }, google: Keychain.app,
                                             remember: { UserDefaults.standard.set($1, forKey: $0) },
                                             hasICloud: CloudEntitlement.hasCloudKit, madeUpRegistry: identity.madeUpRegistry,
                                             macCalendarAuthorized: { CalendarSnapshot.Access.Read.macCalendar == .yes },
                                             callRecords: { watcher.callRecords }, now: Date.init))
            }))
        if let stop {
            switch stop.at {
            case .refuse: say(stop.refusal ?? "")
            case .foreground: say("Mossad: no foreground app; the worker does not start.")
            case .lock: say("Mossad: this profile is open in another copy; the worker does not start.")
            default:
                Log.info("Worker: setup is not finished")
                Log.flush()
            }
            exit(stop.exit.rawValue)
        }
        // The run, for the life of the process, with the lock held as long.
        guard let worker, let held = attempt else { exit(WorkerLaunch.Exit.lockNotHeld.rawValue) }
        Task {
            withExtendedLifetime(held) {}
            await worker.run()
        }
        dispatchMain()
    }

    #if DEBUG
    /// `--probe`: what this process, and one child of it, see of the calendar permission. Only the status is read:
    /// nothing asks. It touches no data folder.
    private static func probe(_ identity: AppIdentity, _ arguments: [String]) -> Never {
        print("calendar \(EventKitCalendarSource.permissionName) pid \(ProcessInfo.processInfo.processIdentifier)")
        fflush(stdout)
        if !arguments.contains("--probe-child"), let executable = Bundle.main.executableURL {
            let child = WorkerLaunch.process(executable: executable, profile: identity.profile, environment: ProcessInfo.processInfo.environment)
            child.arguments = (child.arguments ?? []) + ["--probe", "--probe-child"]
            child.standardOutput = FileHandle.standardOutput
            do {
                try child.run()
                child.waitUntilExit()
            } catch {
                say("Mossad: the probe's child did not start: \(error)")
            }
        }
        exit(WorkerLaunch.Exit.stopped.rawValue)
    }
    #endif

    /// `MOSSAD_PROOF_STUCK_WORKER=1` on a made-up registry, in a debug build: the worker ignores SIGTERM and the
    /// stop in the file, for the proof that the app kills a worker that does not end.
    private static func proofStuck(_ identity: AppIdentity, _ env: [String: String]) -> Bool {
        #if DEBUG
        identity.madeUpRegistry && env["MOSSAD_PROOF_STUCK_WORKER"] == "1"
        #else
        false
        #endif
    }

    private static func say(_ line: String) {
        FileHandle.standardError.write(Data((line + "\n").utf8))
    }

    /// A folder in `Audio`: the profile has meetings.
    private static func hasMeetings(_ paths: Paths) -> Bool {
        !((try? FileManager.default.contentsOfDirectory(atPath: paths.audio.path)) ?? []).filter { !$0.hasPrefix(".") }.isEmpty
    }

    #if DEBUG
    private static func importProofCall(_ file: URL, paths: Paths) {
        guard let audio = try? AVAudioFile(forReading: file) else { return say("Mossad: the proof call could not be read") }
        let seconds = Double(audio.length) / audio.fileFormat.sampleRate
        let start = Date().addingTimeInterval(-7200)
        let recording = PhoneRecording(id: CallID.make(start), start: start, end: start.addingTimeInterval(seconds), title: nil)
        do {
            _ = try PhoneRecording.importAudio(file, recording: recording, into: paths)
            Log.info("Worker: a made-up call for a proof is in the folder")
        } catch {
            say("Mossad: the proof call was not imported: \(error)")
        }
    }
    #endif
}
