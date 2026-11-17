import Foundation

/// `~/Library/Application Support/Mossad/profiles.json`: the profiles of this Mac and the one that is active. Only the
/// foreground app writes it. A file that cannot be read, or that a newer build wrote, is never written over.
public struct ProfileRegistry: Codable, Equatable, Sendable {
    public static let currentVersion = 1

    public var version: Int
    public var profiles: [Profile]
    public var active: String

    /// One profile, `default`, active: what a Mac with no file has.
    public init() {
        version = Self.currentVersion
        profiles = [.default]
        active = Profile.defaultID
    }

    public static func folder(home: URL) -> URL {
        home.appendingPathComponent("Library/Application Support/Mossad", isDirectory: true)
    }

    public static func fileURL(home: URL) -> URL {
        folder(home: home).appendingPathComponent("profiles.json")
    }

    /// The profiles that can start and show: not the ones being deleted.
    public var live: [Profile] { profiles.filter { $0.removing != true } }

    /// A live profile by id. `default` always answers.
    public func profile(_ id: String) -> Profile? {
        if let found = live.first(where: { $0.id == id }) { return found }
        return id == Profile.defaultID ? .default : nil
    }

    public var activeProfile: Profile { profile(active) ?? .default }

    public enum State: Equatable, Sendable { case none, read, newer, unreadable }

    public struct Loaded: Equatable, Sendable {
        public var registry: ProfileRegistry
        public var state: State

        public init(registry: ProfileRegistry, state: State) {
            self.registry = registry
            self.state = state
        }

        public var canSave: Bool { state == .none || state == .read }
        public static let none = Loaded(registry: ProfileRegistry(), state: .none)
    }

    /// Reads the file. It never writes and never moves it: unknown is not empty.
    public static func load(from file: URL) -> Loaded {
        guard let data = try? Data(contentsOf: file) else {
            let missing = !FileManager.default.fileExists(atPath: file.path)
            return missing ? .none : Loaded(registry: ProfileRegistry(), state: .unreadable)
        }
        guard let decoded = try? JSONDecoder().decode(ProfileRegistry.self, from: data) else {
            return Loaded(registry: ProfileRegistry(), state: .unreadable)
        }
        return Loaded(registry: decoded.cleaned(), state: decoded.version > currentVersion ? .newer : .read)
    }

    /// `default` first and always there; an entry with a bad or repeated id left out.
    func cleaned() -> ProfileRegistry {
        var copy = self
        var seen = Set<String>()
        var others: [Profile] = []
        var first: Profile?
        for profile in profiles {
            if profile.isDefault {
                if first == nil { first = profile }
                continue
            }
            guard Self.isID(profile.id), seen.insert(profile.id).inserted else { continue }
            others.append(profile)
        }
        var head = first ?? .default
        head.removing = nil
        copy.profiles = [head] + others
        return copy
    }

    /// 8 characters of 0-9a-f.
    static func isID(_ id: String) -> Bool {
        id.utf8.count == 8 && id.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
}

/// The changes the foreground app makes to the registry. Saved in one atomic write, never over a file it could not read.
extension ProfileRegistry {
    public struct ReadOnly: Error {}

    /// A new profile with a new id and a folder no other has. The active profile does not change.
    public mutating func add(name: String, color: ProfileColor, takenFolders: Set<String>, random: () -> String = ProfileRules.randomID) -> Profile {
        let ids = Set(profiles.map(\.id)).union([Profile.defaultID])
        let own = Set(profiles.map { ($0.root as NSString).lastPathComponent.lowercased() })
        let folder = ProfileRules.folderName(for: name, taken: takenFolders.union(own))
        let profile = Profile(id: ProfileRules.newID(taken: ids, random: random), name: name.trimmingCharacters(in: .whitespacesAndNewlines),
                              color: color, root: "~/" + folder)
        profiles.append(profile)
        return profile
    }

    /// The name and the color; never the folder.
    public mutating func rename(_ id: String, name: String, color: ProfileColor) {
        guard let i = profiles.firstIndex(where: { $0.id == id }) else { return }
        profiles[i].name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        profiles[i].color = color
    }

    public mutating func setActive(_ id: String) { active = id }

    public mutating func setServer(_ hash: String?, for id: String) {
        guard let i = profiles.firstIndex(where: { $0.id == id }) else { return }
        profiles[i].server = hash
    }

    /// The first step of a delete: the profile cannot start and does not show. `default` is never removed.
    public mutating func markRemoving(_ id: String) {
        guard id != Profile.defaultID, let i = profiles.firstIndex(where: { $0.id == id }) else { return }
        profiles[i].removing = true
    }

    public mutating func remove(_ id: String) {
        guard id != Profile.defaultID else { return }
        profiles.removeAll { $0.id == id }
    }

    /// The profiles whose delete has not finished.
    public var removing: [Profile] { profiles.filter { $0.removing == true } }
}

extension ProfileRegistry.Loaded {
    public func save(to file: URL) throws {
        guard canSave else { throw ProfileRegistry.ReadOnly() }
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(registry).write(to: file, options: .atomic)
    }
}
