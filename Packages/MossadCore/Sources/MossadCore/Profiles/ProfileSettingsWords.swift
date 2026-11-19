import Foundation

/// What Settings > Profiles and its sheets show: the rows, the footer for each state of the file, what a profile
/// keeps apart and what the Mac shares, and the sheets' words. With one profile, the one row of that profile.
public enum ProfileSettingsWords {
    public static let oneTitle = "Profiles"
    public static let oneDetail = "Keep work and personal meetings apart."

    // What each profile keeps apart (`AppIdentity`: the folder, the Keychain service, the settings suite, the zone)
    // and what stays the Mac's (`MacDefaults.keys` and `prefixes`, the gate's do-not-record lists). Facts only.
    public static let apartLabel = "Apart"
    public static let apart = ["Its own folder, shown under its name",
                               "Its meetings, people, voices, points, and coach",
                               "Its API keys",
                               "Its settings",
                               "Its iCloud sync and its iPhone link"]
    public static let sharedLabel = "Shared on this Mac"
    public static let shared = ["Off, and Open Mossad at login",
                                "The do-not-record list: each profile's list stops a recording",
                                "Permissions",
                                "Not a call",
                                "Usage statistics",
                                "The quick panel's shortcut",
                                "Updates"]
    public static let addExplanation = "A profile has its own keys, settings, people, voices, coach, sync, and MCP. Nothing is copied from another profile. Mossad restarts and takes you through setup for the new profile."
    public static let renameNote = "The folder keeps its name."

    // The profile code for the iPhone.
    public static let codeButton = "Show code for iPhone…"
    public static func codeTitle(_ name: String) -> String { "Add “\(name)” to your iPhone" }
    public static let codeSteps = ["Open Mossad on your iPhone.", "Tap the gear on the Meetings screen.",
                                   "Tap Profile, then Add a profile. With no Profile row, tap Your server, then Scan code."]
    public static func codeSecretNote(seconds: Int) -> String {
        "The code holds this profile's server secret, so it hides again in 0:\(String(format: "%02d", max(0, min(seconds, 59))))."
    }
    public static let codeICloudNote = "This profile syncs through iCloud. Your iPhone needs the same iCloud account as this Mac."
    public static let codeNoSync = "This profile does not sync. Choose iCloud or your server in Settings › Storage & Sync first."
    public static let codeNoServer = "Finish this profile's server in Settings › Storage & Sync first."

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

    /// The one row with fewer than two live profiles: the active profile, which is the only one, with no delete.
    public static func only(_ profile: Profile) -> Row {
        Row(id: profile.id, name: profile.name, color: profile.color, folder: profile.isDefault ? Profile.default.root : profile.root,
            active: true, mayDelete: false)
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
