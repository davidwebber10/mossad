import Foundation

/// Which profile a process is. `--profile <id>` when given; else the window app is the registry's active profile and
/// every command is `default`, so an AI app set up before a second profile keeps reading the first.
public enum ProfileLaunch {
    public enum Choice: Equatable, Sendable { case profile(Profile), refused(String) }

    /// Whether the window app also takes the Mac-wide lock (`AppIdentity.macWideLockFolder`), so only one profile is
    /// the foreground app. Only with a registry file: with none, nothing new is made on disk. A made-up registry
    /// takes its own lock beside its file.
    public static func takesForegroundLock(_ identity: AppIdentity) -> Bool {
        identity.takesProfiles && identity.registry.state != .none
    }

    public static func choice(arguments: [String], registry: ProfileRegistry.Loaded) -> Choice {
        // `--profile=<id>` and the like would read as no profile, and a command would then serve `default`.
        if let typo = arguments.first(where: { $0.hasPrefix("--profile") && $0 != "--profile" }) {
            return .refused("Mossad: \(typo) is not --profile <id>; not starting.")
        }
        if let i = arguments.firstIndex(of: "--profile") {
            guard let id = arguments.dropFirst(i + 1).first, !id.hasPrefix("-") else {
                return .refused("Mossad: --profile needs a profile id; not starting.")
            }
            guard let profile = registry.registry.profile(id) else {
                return .refused("Mossad: no profile with the id \(id); not starting.")
            }
            return .profile(profile)
        }
        if arguments.contains(where: AppIdentity.commands.contains) {
            return .profile(registry.registry.profile(Profile.defaultID) ?? .default)
        }
        return .profile(registry.registry.activeProfile)
    }
}
