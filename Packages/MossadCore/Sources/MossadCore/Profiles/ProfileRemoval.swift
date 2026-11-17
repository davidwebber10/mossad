import Foundation

/// The delete of a profile, in steps that each do nothing when done already, so a stop at any point goes on at the
/// next launch. The order: the iCloud Keychain items, the Keychain items, the settings, the folder to the Trash, then
/// the iCloud zone; the local steps first, so an offline Mac still removes the profile from this Mac. Nothing here
/// ever names the first profile's things or the active profile's.
public enum ProfileRemoval {
    public enum Step: String, CaseIterable, Sendable { case sharedItems, keys, settings, folder, zone }

    public struct Names: Equatable, Sendable {
        public let id, service, suite, zone: String
        public let root: URL

        public init(id: String, service: String, suite: String, zone: String, root: URL) {
            self.id = id
            self.service = service
            self.suite = suite
            self.zone = zone
            self.root = root
        }
    }

    public static func names(of profile: Profile, home: URL) -> Names {
        let own = AppIdentity.mainBundleID + ".profile." + profile.id
        return Names(id: profile.id, service: own, suite: own, zone: "Mossad-" + profile.id, root: profile.rootURL(home: home))
    }

    /// Every name is the profile's own: never the first profile's service, settings, or zone.
    public static func namesAreSafe(_ n: Names) -> Bool {
        let own = AppIdentity.mainBundleID + ".profile." + n.id
        return ProfileRegistry.isID(n.id) && n.service == own && n.suite == own
            && n.zone == "Mossad-" + n.id && CloudKitStore.mayDelete(zone: n.zone)
    }

    /// Never the first profile, never the active one.
    public static func mayRun(_ profile: Profile, active: String) -> Bool {
        !profile.isDefault && profile.id != active
    }

    public struct Actions: Sendable {
        public var sharedItems: @Sendable (String) -> Void
        public var keys: @Sendable (String) -> Void
        public var settings: @Sendable (String) -> Void
        public var trash: @Sendable (URL) throws -> Void
        public var zone: @Sendable (String) async throws -> Void

        public init(sharedItems: @escaping @Sendable (String) -> Void, keys: @escaping @Sendable (String) -> Void,
                    settings: @escaping @Sendable (String) -> Void, trash: @escaping @Sendable (URL) throws -> Void,
                    zone: @escaping @Sendable (String) async throws -> Void) {
            self.sharedItems = sharedItems
            self.keys = keys
            self.settings = settings
            self.trash = trash
            self.zone = zone
        }
    }

    public struct Outcome: Equatable, Sendable {
        public var done: [Step]
        public var failed: Step?
        public var complete: Bool { failed == nil && done == Step.allCases }
    }

    /// Only a direct child of the home folder whose name starts with "Mossad " and has more after it; never
    /// `~/Mossad`, `~/Mossad Rehearsal`, another profile's folder (letter case ignored), or a symbolic link.
    public static func mayTrash(_ root: URL, home: URL, others: [URL]) -> Bool {
        let r = root.standardizedFileURL
        guard r.deletingLastPathComponent().standardizedFileURL.path == home.standardizedFileURL.path else { return false }
        let name = r.lastPathComponent
        guard name.hasPrefix("Mossad "), !name.dropFirst(7).trimmingCharacters(in: .whitespaces).isEmpty,
              name.lowercased() != "mossad rehearsal" else { return false }
        guard !others.contains(where: { $0.standardizedFileURL.path.lowercased() == r.path.lowercased() }) else { return false }
        let type = (try? FileManager.default.attributesOfItem(atPath: r.path))?[.type] as? FileAttributeType
        return type != .typeSymbolicLink
    }

    /// Runs the steps not in `done`, in order, and stops at the first one that fails. `record` hears each step as
    /// it ends, so the caller saves the progress and a later run does nothing twice.
    public static func run(_ profile: Profile, home: URL, others: [Profile], done: Set<Step>, active: String? = nil,
                           actions: Actions, record: (@Sendable (Step) async -> Void)? = nil) async -> Outcome {
        let n = names(of: profile, home: home)
        guard mayRun(profile, active: active ?? Profile.defaultID), namesAreSafe(n) else {
            return Outcome(done: [], failed: nil)
        }
        var outcome = Outcome(done: [], failed: nil)
        for step in Step.allCases {
            if done.contains(step) {
                outcome.done.append(step)
                continue
            }
            do {
                switch step {
                case .sharedItems: actions.sharedItems(n.id)
                case .keys: actions.keys(n.service)
                case .settings: actions.settings(n.suite)
                case .folder:
                    let kept = [home.appendingPathComponent("Mossad"), home.appendingPathComponent("Mossad Rehearsal")]
                        + others.filter { $0.id != profile.id }.map { $0.rootURL(home: home) }
                    let there = (try? FileManager.default.attributesOfItem(atPath: n.root.path)) != nil
                    if there, mayTrash(n.root, home: home, others: kept) { try actions.trash(n.root) }
                case .zone: try await actions.zone(n.zone)
                }
            } catch {
                outcome.failed = step
                return outcome
            }
            outcome.done.append(step)
            await record?(step)
        }
        return outcome
    }

    /// Before the first step: the rule of the sheet, then the folder's lock. The lock is kept until the run ends, so
    /// the profile cannot start meanwhile.
    public enum Start: Equatable {
        case go(InstanceLock?), refused(String)

        public static func == (a: Start, b: Start) -> Bool {
            switch (a, b) {
            case (.go, .go): true
            case (.refused(let x), .refused(let y)): x == y
            default: false
            }
        }
    }

    public static func start(_ id: String, in registry: ProfileRegistry, active: String, typed: String, home: URL) -> Start {
        if let problem = ProfileRules.deleteProblem(id, in: registry, active: active, typed: typed) { return .refused(problem) }
        guard let profile = registry.profile(id) else { return .refused("Type the profile's name to delete it.") }
        switch InstanceLock.acquire(root: profile.rootURL(home: home)) {
        case .held(let lock): return .go(lock)
        case .taken: return .refused("Mossad has this profile open. Quit that copy first.")
        case .failed: return .go(nil)
        }
    }

    public static let serverNote = "This profile used a server. Mossad does not remove it: it is yours to remove."
    public static let bucketNote = "Recordings that this profile backed up to a bucket stay in the bucket."
}

extension ProfileRegistry {
    /// A step of a delete that ended, kept with the entry so a later run does not do it again.
    public mutating func noteRemoved(_ step: ProfileRemoval.Step, for id: String) {
        guard let i = profiles.firstIndex(where: { $0.id == id }) else { return }
        var steps = profiles[i].removed ?? []
        if !steps.contains(step.rawValue) { steps.append(step.rawValue) }
        profiles[i].removed = steps
    }

    public func removedSteps(of id: String) -> [ProfileRemoval.Step] {
        let saved = profiles.first { $0.id == id }?.removed ?? []
        return ProfileRemoval.Step.allCases.filter { saved.contains($0.rawValue) }
    }
}
