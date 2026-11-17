import Foundation

/// A worker: `Mossad --profile <id> --worker`, a process of the same app with no window, which finishes the meetings
/// of a profile that is not the one in front. This part says whether such a run may start and how it is started.
public enum WorkerLaunch {
    public static let argument = "--worker"

    public enum Exit: Int32, Sendable {
        case stopped = 0, refused = 2, noForeground = 3, lockNotHeld = 4, setupNotDone = 5
    }

    public static func isWorker(_ arguments: [String]) -> Bool { arguments.contains(argument) }

    /// Why this run may not be a worker, or nil. In this order: profiles, a command, `--profile`.
    public static func refusal(_ identity: AppIdentity, arguments: [String]) -> String? {
        guard identity.takesProfiles else { return "Mossad: a worker needs profiles; not starting." }
        if arguments.contains(where: AppIdentity.commands.contains) { return "Mossad: --worker cannot run with a command; not starting." }
        guard arguments.contains("--profile") else { return "Mossad: --worker needs --profile <id>; not starting." }
        return identity.profileRefusal
    }

    /// A worker runs only while it holds its profile's folder lock: the window app of that profile, or another
    /// worker, has it, or it could not be tried. The window app goes on when a lock fails; a worker never does.
    public static func afterLock(_ attempt: InstanceLock.Attempt) -> Exit? {
        if case .held = attempt { return nil }
        return .lockNotHeld
    }

    /// A profile whose window app would open setup at launch gets no worker.
    public static func setupDone(finished: Bool, hasMeetings: Bool) -> Bool {
        !Onboarding.opensAtLaunch(finished: finished, hasMeetings: hasMeetings, preview: false, forced: false, rehearsal: false)
    }

    /// The profiles that get a worker: each other live profile, only from the app in front (`startWorkers`), never
    /// from a copy that takes no profiles. One profile: none. `proof` (a debug hook) lets the window app of a made-up
    /// registry start them, and never for `default`, which on a made-up registry is the owner's real folder.
    public static func profiles(_ identity: AppIdentity, mode: RunMode, proof: Bool = false) -> [Profile] {
        if proof && identity.madeUpRegistry && identity.takesProfiles && mode != .worker {
            return identity.registry.registry.live.filter { $0.id != identity.profile.id && !$0.isDefault }
        }
        guard mode.does(.startWorkers) else { return [] }
        return identity.otherProfiles
    }

    /// The app writes `foreground.json` only when it starts a worker: with one profile there is no file.
    public static func writesForegroundFile(profiles: [Profile]) -> Bool { !profiles.isEmpty }

    public enum Restart: Equatable, Sendable { case after(TimeInterval), never, gaveUp }
    public static let restartWaits: [TimeInterval] = [5, 30, 120]
    /// A worker that ran this long starts the count of failed starts again.
    public static let longRun: TimeInterval = 600

    /// What the app does when a worker ended. `failures`: the failed starts in a row before this exit.
    /// Never after a stop of the app's own, a refusal, or a profile whose setup is not done.
    public static func restart(exit: Int32, failures: Int, stopping: Bool) -> Restart {
        if stopping || exit == Exit.refused.rawValue || exit == Exit.setupNotDone.rawValue { return .never }
        return failures < restartWaits.count ? .after(restartWaits[failures]) : .gaveUp
    }

    /// The `failures` of an exit: the count so far, or 0 when the worker ran `longRun` or more.
    public static func failures(after count: Int, ranSeconds: TimeInterval) -> Int { ranSeconds >= longRun ? 0 : count }

    /// A worker's whole arguments: nothing else, never a secret.
    public static func arguments(for profile: Profile) -> [String] { ["--profile", profile.id, argument] }

    #if os(macOS)
    /// The child process of the foreground app: no input or output, at utility priority.
    public static func process(executable: URL, profile: Profile, environment: [String: String]) -> Process {
        let p = Process()
        p.executableURL = executable
        p.arguments = arguments(for: profile)
        p.environment = environment
        p.standardInput = FileHandle.nullDevice
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        p.qualityOfService = .utility
        return p
    }
    #endif
}

/// The order of a switch with workers: the target's worker stops and its folder is free before anything is saved or
/// started, so the new window app never meets its own worker's lock, and a refusal leaves everything as it was.
public enum WorkerSwitch {
    public static let waitSeconds: TimeInterval = 5
    public enum Step: Equatable, Sendable { case stopWorkers, waitForFolder, saveActive, startInstance, quit, resumeWorkers, restoreActive }
    public static let order: [Step] = [.stopWorkers, .waitForFolder, .saveActive, .startInstance, .quit]

    /// What undoes a step that failed. Nothing after the quit.
    public static func afterFailure(of step: Step) -> [Step] {
        switch step {
        case .waitForFolder, .saveActive: [.resumeWorkers]
        case .startInstance: [.restoreActive, .resumeWorkers]
        default: []
        }
    }

    public static func refusal(_ name: String) -> String {
        "Mossad could not stop the background work of \u{201C}\(name)\u{201D}. Try again in a moment."
    }
}
