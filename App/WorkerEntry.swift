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
        if let refusal = WorkerLaunch.refusal(identity, arguments: arguments) {
            say(refusal)
            exit(WorkerLaunch.Exit.refused.rawValue)
        }
        #if DEBUG
        // `--probe`: what this process, and one child of it, see of the calendar permission. Only the status is
        // read: nothing asks. It touches no data folder.
        if arguments.contains("--probe") {
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
        let home = FileManager.default.homeDirectoryForCurrentUser
        let env = ProcessInfo.processInfo.environment
        // 1. The app in front: nothing of the data folder is touched before it is known.
        // `signals: true`: the worker's own SIGTERM and SIGINT handling, set by itself (the app's are not inherited).
        let stuck = proofStuck(identity, env)
        let watcher = ForegroundWatcher(file: ForegroundState.url(home: home, environment: env), signals: !stuck) { why in
            if stuck { return Log.info("Worker: ignores the stop (\(why.rawValue)) for a proof") }
            Log.info("Worker: stops (\(why.rawValue))")
            Log.flush()
            exit(WorkerLaunch.Exit.stopped.rawValue)
        }
        if stuck { signal(SIGTERM, SIG_IGN) }
        if case .stop = watcher.first() {
            say("Mossad: no foreground app; the worker does not start.")
            exit(WorkerLaunch.Exit.noForeground.rawValue)
        }
        // 2. The profile's folder lock, for the life of the process: a worker never runs beside the window app of
        // its profile.
        let paths = Paths.live
        // The lock file lives in the folder: a profile whose folder is not there yet gets it, and nothing else.
        try? FileManager.default.createDirectory(at: paths.root, withIntermediateDirectories: true)
        let attempt = InstanceLock.acquire(root: paths.root)
        if let code = WorkerLaunch.afterLock(attempt) {
            say("Mossad: this profile is open in another copy; the worker does not start.")
            exit(code.rawValue)
        }
        // 3. The folder and the log.
        try? paths.ensureDirectories()
        Log.directory = paths.logs
        _ = NetworkPath.shared
        #if DEBUG
        // 4. A made-up recorded call for a proof, on a made-up registry only, in an empty folder.
        if identity.madeUpRegistry, let file = env["MOSSAD_PROOF_CALL"], !hasMeetings(paths) {
            importProofCall(URL(fileURLWithPath: file), paths: paths)
        }
        #endif
        // 5. A profile whose setup is not finished gets no worker.
        let settings = ServiceSettings.read(.standard, fullUserName: NSFullUserName())
        guard WorkerLaunch.setupDone(finished: settings.setupDone, hasMeetings: hasMeetings(paths)) else {
            Log.info("Worker: setup is not finished")
            Log.flush()
            exit(WorkerLaunch.Exit.setupNotDone.rawValue)
        }
        // 6. The watch, then the run, for the life of the process.
        watcher.start()
        let worker = ProfileWorker(.init(paths: paths, settings: settings, key: { Keychain.app.get($0) }, google: Keychain.app,
                                         remember: { UserDefaults.standard.set($1, forKey: $0) },
                                         hasICloud: CloudEntitlement.hasCloudKit, madeUpRegistry: identity.madeUpRegistry,
                                         macCalendarAuthorized: { CalendarSnapshot.Access.Read.macCalendar == .yes },
                                         callRecords: { watcher.callRecords }, now: Date.init))
        Task {
            withExtendedLifetime(attempt) {}
            await worker.run()
        }
        dispatchMain()
    }

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
