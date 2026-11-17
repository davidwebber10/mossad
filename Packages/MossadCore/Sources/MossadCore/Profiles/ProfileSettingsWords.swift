import Foundation

/// What Settings > General > Profiles and its sheets show: the rows, the footer for each state of the file, and
/// the sheets' words. With one profile there are no rows, only the one row that offers "Add profile…".
public enum ProfileSettingsWords {
    public static let oneTitle = "Profiles"
    public static let oneDetail = "Keep work and personal meetings apart."
    public static let addExplanation = "A profile has its own keys, settings, people, voices, coach, sync, and MCP. Nothing is copied from another profile. Mossad restarts and takes you through setup for the new profile."
    public static let renameNote = "The folder keeps its name."

    public struct Row: Equatable, Sendable, Identifiable {
        public let id: String
        public let name: String
        public let color: ProfileColor
        /// The folder as the registry writes it (`~/Mossad Work`).
        public let folder: String
        public let active: Bool
        /// Never the first profile, never the active one.
        public let mayDelete: Bool
    }

    /// One row for each live profile, or none with fewer than two.
    public static func rows(_ registry: ProfileRegistry, active: String) -> [Row] {
        let live = registry.live
        guard live.count >= 2 else { return [] }
        return live.map {
            Row(id: $0.id, name: $0.name, color: $0.color, folder: $0.isDefault ? Profile.default.root : $0.root,
                active: $0.id == active, mayDelete: ProfileRemoval.mayRun($0, active: active))
        }
    }

    /// The group's footer: the last problem, else the state of the file, else a delete that has not ended.
    public static func footer(_ loaded: ProfileRegistry.Loaded, problem: String? = nil) -> String? {
        if let problem { return problem }
        switch loaded.state {
        case .unreadable: return "The list of profiles could not be read. Mossad runs as the first profile."
        case .newer: return "A newer Mossad wrote the list of profiles. This one can switch, but changes nothing in it."
        case .partial: return "Mossad left out a profile whose folder it cannot use: \(loaded.leftOut.joined(separator: ", ")). It did not change the file."
        case .none, .read: break
        }
        return loaded.registry.removing.isEmpty ? nil : "A deleted profile is still being removed. Mossad tries again at the next launch."
    }

    /// Why no change of the list may be made now, or nil when one may.
    public static func changeRefusal(_ loaded: ProfileRegistry.Loaded) -> String? {
        switch loaded.state {
        case .none, .read: nil
        case .newer: "This Mac has a profile list from a newer Mossad. Update Mossad to change profiles."
        case .partial, .unreadable: footer(loaded)
        }
    }

    public static func deleteText(_ profile: Profile) -> String {
        "This removes the profile's keys and settings from this Mac and its meetings from iCloud, and moves \(profile.root) to the Trash."
    }

    /// The server sentence only when the profile had a server.
    public static func deleteNotes(_ profile: Profile) -> [String] {
        (profile.server == nil ? [] : [ProfileRemoval.serverNote]) + [ProfileRemoval.bucketNote]
    }

    public static func accessibilityLabel(_ profile: Profile) -> String { "Profile, \(profile.name)" }
}
