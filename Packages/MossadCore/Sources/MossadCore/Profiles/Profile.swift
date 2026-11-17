import Foundation

/// The color that marks a profile in the switcher and the menu bar.
public enum ProfileColor: String, Codable, CaseIterable, Sendable {
    case orange, blue, green, purple, pink, graphite

    /// A color this build does not know reads as graphite, so a newer file still opens.
    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = ProfileColor(rawValue: raw) ?? .graphite
    }
}

/// One profile: its own folder, Keychain service, and settings. The first one, `default`, is the Mossad of before.
public struct Profile: Codable, Equatable, Sendable, Identifiable {
    public static let defaultID = "default"
    public static let `default` = Profile(id: defaultID, name: "Mossad", color: .orange, root: "~/Mossad")

    public var id: String
    public var name: String
    public var color: ProfileColor
    /// `~/<folder>` under the home folder, or an absolute path (a made-up registry). Ignored for `default`.
    public var root: String
    /// The SHA-256 of the profile's server address, never the address.
    public var server: String?
    /// How the profile syncs: "icloud", "server", or "off". Written by that profile's own foreground app, for the
    /// iPhone's list. Nil until that profile ran once with this build. A build of before reads past it.
    public var sync: String?
    /// Set while a delete runs: the profile cannot start and does not show.
    public var removing: Bool?
    /// The steps of that delete that ended (`ProfileRemoval.Step`), so a later run does nothing twice.
    public var removed: [String]?

    public init(id: String, name: String, color: ProfileColor, root: String) {
        self.id = id
        self.name = name
        self.color = color
        self.root = root
    }

    public var isDefault: Bool { id == Self.defaultID }

    public func rootURL(home: URL) -> URL {
        if isDefault { return home.appendingPathComponent("Mossad") }
        if root.hasPrefix("~/") { return home.appendingPathComponent(String(root.dropFirst(2))) }
        return URL(fileURLWithPath: root)
    }
}
