import Foundation

/// A profile as the iPhone knows it: from the Mac's `profiles` item, or from a profile code.
public struct PhoneProfile: Codable, Equatable, Sendable, Identifiable {
    public enum Source: String, Codable, Sendable { case item, code }

    public var id: String
    public var name: String
    public var color: ProfileColor
    /// "icloud", "server", or "off", as the Mac said. A word this build does not know is kept and reads as not known.
    public var syncName: String?
    /// A source of a newer build reads as `.item`, and is written back as it was read until this build changes it.
    public var source: Source {
        didSet { sourceText = nil }
    }
    private var sourceText: String?
    /// Since when the Mac no longer lists it.
    public var gone: Date?
    /// The owner removed it from this iPhone (a coded profile): not one that left the Mac.
    public var removedHere = false

    public init(id: String, name: String, color: ProfileColor, sync: SyncChoice?, source: Source, gone: Date? = nil) {
        self.id = id
        self.name = name
        self.color = color
        syncName = sync?.rawValue
        self.source = source
        self.gone = gone
    }

    enum CodingKeys: String, CodingKey { case id, name, color, syncName = "sync", source, gone, removedHere }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        color = try c.decode(ProfileColor.self, forKey: .color)
        syncName = try c.decodeIfPresent(String.self, forKey: .syncName)
        let raw = try c.decode(String.self, forKey: .source)
        source = Source(rawValue: raw) ?? .item
        sourceText = Source(rawValue: raw) == nil ? raw : nil
        gone = try c.decodeIfPresent(Date.self, forKey: .gone)
        removedHere = try c.decodeIfPresent(Bool.self, forKey: .removedHere) ?? false
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(color, forKey: .color)
        try c.encodeIfPresent(syncName, forKey: .syncName)
        try c.encode(sourceText ?? source.rawValue, forKey: .source)
        try c.encodeIfPresent(gone, forKey: .gone)
        if removedHere { try c.encode(true, forKey: .removedHere) }
    }

    /// Nil for no word or a word this build does not know.
    public var sync: SyncChoice? { syncName.flatMap(SyncChoice.init(rawValue:)) }
    public var isDefault: Bool { id == Profile.defaultID }

    public static let `default` = PhoneProfile(id: Profile.defaultID, name: Profile.default.name, color: Profile.default.color,
                                               sync: nil, source: .item)
}

/// Every name of one profile on the iPhone, from its id alone. The first profile, `default`, keeps the names of the
/// phone of before: its folder, its Keychain service, the standard settings, the zone, and the two accounts.
public struct PhoneProfileContext: Equatable, Hashable, Sendable {
    public let id: String

    /// Nil unless `default` or 8 characters of 0-9a-f.
    public init?(id: String) {
        guard id == Profile.defaultID || ProfileRegistry.isID(id) else { return nil }
        self.id = id
    }

    public static let `default` = PhoneProfileContext(id: Profile.defaultID)!

    public var isDefault: Bool { id == Profile.defaultID }

    /// `default`: `MOSSAD_ROOT` when set (as today's `Paths.live` reads it, an empty value too), else
    /// `Documents/Mossad`. Another profile: `<first root> Profiles/<id>`.
    public func root(documents: URL, environment: [String: String]) -> URL {
        let first = environment["MOSSAD_ROOT"].map { URL(fileURLWithPath: $0) } ?? documents.appendingPathComponent("Mossad")
        guard !isDefault else { return first }
        return first.deletingLastPathComponent()
            .appendingPathComponent(first.lastPathComponent + " Profiles")
            .appendingPathComponent(id)
    }

    public func paths(documents: URL, environment: [String: String]) -> Paths {
        Paths(root: root(documents: documents, environment: environment))
    }

    /// The Mac's names, so a profile is one name on both devices.
    public var keychainService: String {
        isDefault ? AppIdentity.mainBundleID : AppIdentity.mainBundleID + ".profile." + id
    }

    /// Nil for `default`, which keeps the standard settings.
    public var settingsSuite: String? { isDefault ? nil : keychainService }

    /// The profile's settings. A profile whose suite cannot be made has none: never the first profile's.
    public func settings(standard: UserDefaults, makeSuite: (String) -> UserDefaults?) -> UserDefaults? {
        guard let suite = settingsSuite else { return standard }
        return makeSuite(suite)
    }

    public var cloudZone: String { isDefault ? "Mossad" : "Mossad-" + id }
    public var aiAccount: String { SharedAIKey.account(profile: id) }
    public var serverAccount: String { ServerPairing.account(profile: id) }

    /// The owner's choice on this iPhone, else what the Mac says. `default` keeps today's rule: the saved choice,
    /// else iCloud. Another profile with neither is not known.
    public func sync(saved: String?, listed: SyncChoice?) -> SyncChoice? {
        if let chosen = saved.flatMap(SyncChoice.init(rawValue:)) { return chosen }
        return isDefault ? .icloud : listed
    }

    /// Only another profile's own folder, exactly: never the first profile's, the folder of all profiles, or another's.
    public func mayRemove(_ folder: URL, documents: URL, environment: [String: String]) -> Bool {
        guard !isDefault else { return false }
        return folder.standardizedFileURL.path == root(documents: documents, environment: environment).standardizedFileURL.path
    }

    /// The settings of each profile's own: in the standard domain for `default`, in its suite for another.
    public static let ownKeys = ["syncWith", "serverAddress", "recentSearches", "findingsSeen"]
    /// How the owner likes to look, and the phone's list of profiles: in the standard domain for all.
    public static let sharedKeys = ["analyticsPreset", "analyticsStart", "analyticsEnd", "analyticsTrendSplit", "peopleSort", "phoneProfiles"]
}
