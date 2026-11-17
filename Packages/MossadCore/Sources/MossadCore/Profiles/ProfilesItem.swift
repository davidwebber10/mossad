import Foundation
import Security

/// The iCloud Keychain item `profiles`: the Mac's live profiles for the iPhone. Each entry holds its id, name, color,
/// and how it syncs; never an address, a secret, or a folder. Only the Mac's foreground app writes it, and only with a
/// registry file; with one profile it is deleted, and with no registry file it is never read, written, or deleted.
public struct ProfilesItem: Codable, Equatable, Sendable {
    public static let currentVersion = 1
    public static let account = "profiles"
    /// The allowed fields of an entry.
    public static let fields = ["id", "name", "color", "sync"]

    public struct Entry: Codable, Equatable, Sendable {
        public var id: String
        public var name: String
        public var color: ProfileColor
        /// "icloud", "server", "off", or a word of a newer build; nil when the Mac does not know.
        public var sync: String?

        public init(id: String, name: String, color: ProfileColor, sync: String?) {
            self.id = id
            self.name = name
            self.color = color
            self.sync = sync
        }
    }

    public var version: Int
    public var profiles: [Entry]

    public init(version: Int = currentVersion, profiles: [Entry]) {
        self.version = version
        self.profiles = profiles
    }

    /// The live profiles, `default` first.
    public static func make(from registry: ProfileRegistry) -> ProfilesItem {
        ProfilesItem(profiles: registry.live.map { Entry(id: $0.id, name: $0.name, color: $0.color, sync: $0.sync) })
    }

    /// Sorted keys, so two Macs with one list write the same bytes.
    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(self)
    }

    private struct Lossy: Decodable {
        var version: Int
        var profiles: [Entry?]?

        struct Field: Decodable {
            var value: Entry?
            init(from decoder: Decoder) throws { value = try? Entry(from: decoder) }
        }

        enum CodingKeys: String, CodingKey { case version, profiles }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            version = try c.decode(Int.self, forKey: .version)
            profiles = try c.decodeIfPresent([Field].self, forKey: .profiles)?.map(\.value)
        }
    }

    /// Nil only when the data is no item (no `version`). A newer item is read as far as this build knows it; an entry
    /// with a bad or repeated id, or one that does not read, is left out.
    public static func decode(_ data: Data) -> ProfilesItem? {
        guard let lossy = try? JSONDecoder().decode(Lossy.self, from: data) else { return nil }
        var seen = Set<String>()
        let entries = (lossy.profiles ?? []).compactMap { $0 }.filter { entry in
            (entry.id == Profile.defaultID || ProfileRegistry.isID(entry.id)) && seen.insert(entry.id).inserted
        }
        return ProfilesItem(version: lossy.version, profiles: entries)
    }

    /// What the Keychain gave: an item, no item, or not known (any other failure, or data that is no item).
    public enum Read: Equatable, Sendable { case found(ProfilesItem), none, unknown }
    public enum Plan: Equatable, Sendable { case write(ProfilesItem), delete, leave }

    /// The Mac's rule. With no registry file, or one that cannot be saved (unreadable, partial, newer): leave. With
    /// two or more live profiles: write unless the item is the same or newer. With one: delete an item this build
    /// knows; leave one it does not, and one it cannot read.
    public static func plan(_ loaded: ProfileRegistry.Loaded, existing: Read) -> Plan {
        guard loaded.state == .read else { return .leave }
        if case .found(let found) = existing, found.version > currentVersion { return .leave }
        let item = make(from: loaded.registry)
        if item.profiles.count >= 2 {
            if case .found(let found) = existing, found == item { return .leave }
            return .write(item)
        }
        if case .found = existing { return .delete }
        return .leave
    }

    /// The plan, reading the item only when a registry file was read cleanly: with no file (one profile) the
    /// Keychain is never touched.
    public static func decide(_ loaded: ProfileRegistry.Loaded, read: () -> Read) -> Plan {
        guard loaded.state == .read else { return .leave }
        return plan(loaded, existing: read())
    }

    static func query() -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: SharedAIKey.service,
         kSecAttrAccount as String: account,
         kSecAttrAccessGroup as String: SharedAIKey.accessGroup,
         kSecAttrSynchronizable as String: true,
         kSecUseDataProtectionKeychain as String: true]
    }

    /// Not found: `.none`. Any other failure, or data that is no item: `.unknown`. A preview never reads it.
    public static func read() -> Read {
        guard !AppIdentity.current.isPreview else { return .unknown }
        var q = query()
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &out)
        if status == errSecItemNotFound { return .none }
        guard status == errSecSuccess, let data = out as? Data, let item = decode(data) else { return .unknown }
        return .found(item)
    }

    public func save() throws {
        let data = try encoded()
        try SharedItemsGate.perform {
            let status = SecItemUpdate(Self.query() as CFDictionary, [kSecValueData as String: data] as CFDictionary)
            if status == errSecItemNotFound {
                var add = Self.query()
                add[kSecValueData as String] = data
                add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
                let result = SecItemAdd(add as CFDictionary, nil)
                guard result == errSecSuccess else { throw KeychainError(status: result) }
            } else if status != errSecSuccess {
                throw KeychainError(status: status)
            }
        }
    }

    public static func delete() {
        SharedItemsGate.perform { SecItemDelete(query() as CFDictionary) }
    }
}
