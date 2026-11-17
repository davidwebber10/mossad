import CryptoKit
import Foundation

/// The pure rules of profiles: names, folders, ids, colors, the delete rule, and the server each profile owns.
public enum ProfileRules {
    public static let nameLimit = 40
    /// Folders that are never a new profile's: the first profile's and Rehearsal's.
    static let reservedFolders: Set<String> = ["mossad", "mossad rehearsal"]

    public static func nameProblem(_ typed: String, in registry: ProfileRegistry, renaming id: String? = nil) -> String? {
        let name = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty { return "Give the profile a name." }
        let taken = registry.live.contains { $0.id != id && $0.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == name.lowercased() }
        return taken ? "Another profile has this name." : nil
    }

    /// "Mossad <Name>" with only letters, digits, spaces, `-`, and `_` of the name (40 at most), so the note's
    /// `audio:` line stays valid YAML; " 2", " 3" when taken, letter case ignored.
    public static func folderName(for name: String, taken: Set<String>) -> String {
        let kept = String(name.filter { $0.isLetter || $0.isWholeNumber || $0 == " " || $0 == "-" || $0 == "_" })
        let words = kept.split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
        let short = String(words.prefix(nameLimit)).trimmingCharacters(in: .whitespaces)
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
        if id == active { return "Switch to another profile first." }
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

        public init(id: String, name: String, color: ProfileColor, active: Bool) {
            self.id = id
            self.name = name
            self.color = color
            self.active = active
        }
    }

    public static let add = "Add profile…", manage = "Manage profiles…"

    public let rows: [Row]
    public let title: String
    public let color: ProfileColor
    public let note: String?

    public init?(_ registry: ProfileRegistry, active: String, recording: Bool) {
        let live = registry.live
        guard live.count >= 2 else { return nil }
        let current = registry.profile(active) ?? .default
        rows = live.map { Row(id: $0.id, name: $0.name, color: $0.color, active: $0.id == current.id) }
        title = current.name
        color = current.color
        note = recording ? ProfileSwitch.refusal : nil
    }
}
