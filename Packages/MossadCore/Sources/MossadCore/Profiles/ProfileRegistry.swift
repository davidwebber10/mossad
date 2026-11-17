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
