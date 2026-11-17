import Foundation

/// `~/Library/Application Support/Mossad/profiles.json`: the profiles of this Mac and the one that is active. Only the
/// foreground app writes it. A file that cannot be read, or that a newer build wrote, is never written over.
public struct ProfileRegistry: Codable, Equatable, Sendable {
    public static let currentVersion = 1

    public var version: Int
    public var profiles: [Profile]
    public var active: String
    /// A random id of this Mac's list, made once, for the iPhone's item: a Mac deletes only an item it wrote itself.
    /// Never a hardware id. A build of before reads past it, and drops it at its next save.
    public var writer: String?

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

    /// `partial`: read, but an entry was left out (a bad id, a repeated id, or an unsafe root). A save would remove
    /// that entry for good, so the file is read and never saved, as a newer one.
    public enum State: Equatable, Sendable { case none, read, newer, unreadable, partial }

    public struct Loaded: Equatable, Sendable {
        public var registry: ProfileRegistry
        public var state: State
        /// The names of the entries left out (`partial`), for the sentence in Settings.
        public var leftOut: [String] = []

        public init(registry: ProfileRegistry, state: State, leftOut: [String] = []) {
            self.registry = registry
            self.state = state
            self.leftOut = leftOut
        }

        public var canSave: Bool { state == .none || state == .read }
        public static let none = Loaded(registry: ProfileRegistry(), state: .none)
    }

    /// Reads the file. It never writes and never moves it: unknown is not empty. `home` is given for the real file
    /// only: its roots must then be a folder of their own under it (`safeRoot`); a made-up file may name any path.
    public static func load(from file: URL, home: URL? = nil) -> Loaded {
        guard let data = try? Data(contentsOf: file) else {
            let missing = !FileManager.default.fileExists(atPath: file.path)
            return missing ? .none : Loaded(registry: ProfileRegistry(), state: .unreadable)
        }
        guard let decoded = try? JSONDecoder().decode(ProfileRegistry.self, from: data) else {
            return Loaded(registry: ProfileRegistry(), state: .unreadable)
        }
        let (registry, leftOut) = decoded.cleaned(home: home)
        let state: State = decoded.version > currentVersion ? .newer : leftOut ? .partial : .read
        let kept = Set(registry.profiles.map(\.id))
        let names = decoded.profiles.filter { !$0.isDefault && !kept.contains($0.id) }.map(\.name)
        return Loaded(registry: registry, state: state, leftOut: names)
    }

    /// `default` first, always there, always on `~/Mossad`; an entry with a bad or repeated id, or with a root that is
    /// not safe in the real file, left out. True when an entry was left out.
    func cleaned(home: URL?) -> (ProfileRegistry, Bool) {
        var copy = self
        var seen = Set<String>()
        var roots = Set<String>()
        var others: [Profile] = []
        var first: Profile?
        var leftOut = false
        for profile in profiles {
            if profile.isDefault {
                if first == nil { first = profile } else { leftOut = true }
                continue
            }
            guard Self.isID(profile.id), !seen.contains(profile.id),
                  home.map({ Self.safeRoot(profile.root, home: $0, taken: roots) }) ?? true else {
                leftOut = true
                continue
            }
            seen.insert(profile.id)
            roots.insert(profile.root.lowercased())
            others.append(profile)
        }
        var head = first ?? .default
        head.removing = nil
        head.root = Profile.default.root
        copy.profiles = [head] + others
        return (copy, leftOut)
    }

    /// A root of the real registry: `~/` and one folder name, not the first profile's or Rehearsal's, not another
    /// entry's (letter case ignored), with no `..`, and not a symbolic link when it exists. Anything else could put
    /// a profile on another one's meetings.
    static func safeRoot(_ root: String, home: URL, taken: Set<String>) -> Bool {
        guard root.hasPrefix("~/") else { return false }
        let name = String(root.dropFirst(2))
        guard !name.isEmpty, !name.contains("/"), !name.contains(".."), name != ".",
              !ProfileRules.reservedFolders.contains(name.lowercased()), !taken.contains(root.lowercased()) else { return false }
        let url = home.appendingPathComponent(name)
        let link = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.type] as? FileAttributeType == .typeSymbolicLink
        return !link
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

    /// 16 characters of 0-9a-f, random.
    public static func newWriter() -> String {
        (0..<8).map { _ in String(format: "%02x", UInt8.random(in: 0...255)) }.joined()
    }

    /// Makes this Mac's writer id once. True when it was made now and the registry needs a save.
    public mutating func ensureWriter(random: () -> String = ProfileRegistry.newWriter) -> Bool {
        guard writer == nil else { return false }
        writer = random()
        return true
    }

    public mutating func setSync(_ sync: String?, for id: String) {
        guard let i = profiles.firstIndex(where: { $0.id == id }) else { return }
        profiles[i].sync = sync
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
    /// The registry to save with this profile's sync word, or nil: only a file that read cleanly, and only when the
    /// word changed. A Mac with no file gets none, so a Mac with one profile never makes one.
    public func notingSync(_ word: String, for id: String) -> ProfileRegistry.Loaded? {
        guard state == .read, registry.profile(id)?.sync != word else { return nil }
        var next = self
        next.registry.setSync(word, for: id)
        return next
    }

    public func save(to file: URL) throws {
        guard canSave else { throw ProfileRegistry.ReadOnly() }
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(registry).write(to: file, options: .atomic)
    }
}
