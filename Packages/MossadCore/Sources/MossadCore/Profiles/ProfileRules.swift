import CryptoKit
import Foundation

/// The pure rules of profiles: names, folders, ids, colors, the delete rule, and the server each profile owns.
public enum ProfileRules {
    /// The longest name of a profile, in characters (an emoji is one).
    public static let nameLimit = 30

    /// A name that came from another device: no control characters, cut to the limit, then trimmed, so a cut never
    /// ends in a space. Nil when nothing is left.
    public static func cleanName(_ raw: String) -> String? {
        let plain = String(String.UnicodeScalarView(raw.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }))
        let name = String(plain.trimmingCharacters(in: .whitespacesAndNewlines).prefix(nameLimit))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? nil : name
    }
    /// The most characters of the name that a folder keeps.
    public static let folderLimit = 40
    /// Folders that are never a new profile's: the first profile's and Rehearsal's.
    static let reservedFolders: Set<String> = ["mossad", "mossad rehearsal"]

    public static func nameProblem(_ typed: String, in registry: ProfileRegistry, renaming id: String? = nil) -> String? {
        let name = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty { return "Give the profile a name." }
        if name.count > nameLimit { return "Use a name of \(nameLimit) characters or fewer." }
        let taken = registry.live.contains { $0.id != id && $0.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == name.lowercased() }
        return taken ? "Another profile has this name." : nil
    }

    /// "Mossad <Name>" with only letters, digits, spaces, `-`, and `_` of the name (40 at most), so the note's
    /// `audio:` line stays valid YAML; " 2", " 3" when taken, letter case ignored.
    public static func folderName(for name: String, taken: Set<String>) -> String {
        let kept = String(name.filter { $0.isLetter || $0.isWholeNumber || $0 == " " || $0 == "-" || $0 == "_" })
        let words = kept.split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
        let short = String(words.prefix(folderLimit)).trimmingCharacters(in: .whitespaces)
        let base = "Mossad " + (short.isEmpty ? "Profile" : short)
        let all = Set(taken.map { $0.lowercased() }).union(reservedFolders)
        guard all.contains(base.lowercased()) else { return base }
        var n = 2
        while all.contains("\(base) \(n)".lowercased()) { n += 1 }
        return "\(base) \(n)"
    }

    public static func randomID() -> String {
        String(format: "%08x", UInt32.random(in: .min ... .max))
    }

    public static func newID(taken: Set<String>, random: () -> String) -> String {
        while true {
            let id = random()
            if ProfileRegistry.isID(id), !taken.contains(id) { return id }
        }
    }

    /// The first color no live profile has.
    public static func nextColor(in registry: ProfileRegistry) -> ProfileColor {
        let used = Set(registry.live.map(\.color))
        return ProfileColor.allCases.first { !used.contains($0) } ?? ProfileColor.allCases[registry.live.count % ProfileColor.allCases.count]
    }

    public static func deleteProblem(_ id: String, in registry: ProfileRegistry, active: String, typed: String) -> String? {
        if id == Profile.defaultID { return "The first profile cannot be deleted." }
        // This copy's profile, and the file's active one (the target of a switch that is still going on).
        if id == active || id == registry.active { return "Switch to another profile first." }
        guard let profile = registry.profile(id), typed.trimmingCharacters(in: .whitespacesAndNewlines) == profile.name else {
            return "Type the profile's name to delete it."
        }
        return nil
    }

    /// The SHA-256 (hex) of the address in lower case: the registry never holds the address itself.
    public static func serverHash(_ address: URL) -> String {
        SHA256.hash(data: Data(serverKey(address).utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// One text for one server however its address is written: no user information, no default port (443 on
    /// https, 80 on http), no dot at the end of the host, all in lower case.
    static func serverKey(_ address: URL) -> String {
        guard var c = URLComponents(url: address, resolvingAgainstBaseURL: false) else { return address.absoluteString.lowercased() }
        c.user = nil
        c.password = nil
        let scheme = c.scheme?.lowercased()
        if (scheme == "https" && c.port == 443) || (scheme == "http" && c.port == 80) { c.port = nil }
        if let host = c.host, host.hasSuffix(".") { c.host = String(host.dropLast()) }
        return (c.url?.absoluteString ?? address.absoluteString).lowercased()
    }

    public static func serverOwner(of address: URL, in registry: ProfileRegistry, except id: String) -> Profile? {
        let hash = serverHash(address)
        return registry.live.first { $0.id != id && $0.server == hash }
    }

    public static func serverRefusal(_ owner: Profile) -> String {
        "The profile “\(owner.name)” already uses this server. Each profile needs its own server."
    }
}

/// A switch saves `active`, starts a new instance, and quits; never while a call records.
public enum ProfileSwitch {
    public static let refusal = "A call is recording. Switch when it ends."
    public static let addRefusal = "A call is recording. Add a profile when it ends."

    public enum Decision: Equatable, Sendable { case go(save: Bool, arguments: [String]), refused(String), stay }

    public static func decide(to id: String, registry: ProfileRegistry.Loaded, active: String, recording: Bool, arguments: [String]) -> Decision {
        if recording { return .refused(refusal) }
        guard registry.state != .unreadable, id != active, registry.registry.profile(id) != nil else { return .stay }
        var kept: [String] = []
        var rest = arguments.dropFirst()[...]
        while let arg = rest.popFirst() {
            switch arg {
            case "--profile", "--open-window": _ = rest.popFirst()
            case "--switched", "--background": continue
            default: kept.append(arg)
            }
        }
        kept.append("--switched")
        if !registry.canSave { kept += ["--profile", id] }
        return .go(save: registry.canSave, arguments: kept)
    }

    public enum AfterStart: Equatable, Sendable { case quit, restore(active: String), stay }

    public static func afterStart(started: Bool, saved: Bool, was active: String) -> AfterStart {
        if started { return .quit }
        return saved ? .restore(active: active) : .stay
    }

    /// Whether a change of profiles may start: a copy that changes the registry, and no switch going on.
    public static func mayChange(inert: Bool, mayChangeRegistry: Bool, switching: Bool) -> Bool {
        !inert && mayChangeRegistry && !switching
    }

    /// The tries to take the Mac-wide lock again after a switch that did not happen, while the new instance ends.
    public static let lockRetries: [TimeInterval] = [0.2, 0.5, 1, 2, 4]

    /// How long a problem shows under the switcher; a refusal for a call goes as soon as no call records.
    public static let problemShows: TimeInterval = 30

    public static func problemStays(_ problem: String, recording: Bool, age: TimeInterval) -> Bool {
        guard age <= problemShows else { return false }
        if problem == refusal || problem == addRefusal { return recording }
        return true
    }

    /// Right before the old instance quits: a call that started after the decision stops the switch.
    public enum AtQuit: Equatable, Sendable { case quit, refused(String) }

    public static func atQuit(recording: Bool) -> AtQuit { recording ? .refused(refusal) : .quit }

    /// The new instance of a switch waits for the old one's locks.
    public static func waitSeconds(_ arguments: [String]) -> TimeInterval { arguments.contains("--switched") ? 10 : 0 }
}

/// The switcher's menu: shown only with two live profiles or more.
public struct ProfileMenu: Equatable, Sendable {
    public struct Row: Equatable, Sendable, Identifiable {
        public let id: String
        public let name: String
        public let color: ProfileColor
        public let active: Bool
        /// The worker's line of another profile ("2 meetings in work"); never on the active row.
        public let status: String?

        public init(id: String, name: String, color: ProfileColor, active: Bool, status: String? = nil) {
            self.id = id
            self.name = name
            self.color = color
            self.active = active
            self.status = status
        }
    }

    public static let add = "Add profile…", manage = "Manage profiles…"

    public let rows: [Row]
    public let title: String
    public let color: ProfileColor
    public let note: String?

    public init?(_ registry: ProfileRegistry, active: String, recording: Bool, status: [String: String] = [:]) {
        let live = registry.live
        guard live.count >= 2 else { return nil }
        let current = registry.profile(active) ?? .default
        rows = live.map {
            Row(id: $0.id, name: $0.name, color: $0.color, active: $0.id == current.id, status: $0.id == current.id ? nil : status[$0.id])
        }
        title = current.name
        color = current.color
        note = recording ? ProfileSwitch.refusal : nil
    }
}
