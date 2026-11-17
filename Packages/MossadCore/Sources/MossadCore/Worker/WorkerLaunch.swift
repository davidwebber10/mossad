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
