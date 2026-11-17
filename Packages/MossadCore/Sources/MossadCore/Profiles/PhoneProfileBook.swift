import Foundation

/// The iPhone's list of profiles: from the Mac's `profiles` item and from scanned profile codes, with the phone's own
/// active profile and its last choice for an import. Kept in the standard settings under `phoneProfiles`, and only
/// when it holds something: with no item and no code the phone saves nothing new.
public struct PhoneProfileBook: Codable, Equatable, Sendable {
    public static let currentVersion = 1
    public static let defaultsKey = "phoneProfiles"

    public var version: Int
    /// As last known. May hold `default`, for its name and color.
    public var profiles: [PhoneProfile]
    /// Nil is `default`.
    public var active: String?
    /// The last profile chosen for an import. `default` is the same as none.
    public var importTarget: String?
    /// The saved book did not read: not known, so it is never saved over or removed in this run.
    public private(set) var unreadable = false

    enum CodingKeys: String, CodingKey { case version, profiles, active, importTarget }

    public init() {
        version = Self.currentVersion
        profiles = []
    }

    /// `default` first, then the item's order, then the coded ones. None that is gone.
    public var listed: [PhoneProfile] {
        let first = profiles.first { $0.isDefault }.map { p -> PhoneProfile in
            var copy = p
            copy.gone = nil
            return copy
        } ?? .default
        let here = profiles.filter { !$0.isDefault && $0.gone == nil }
        return [first] + here.filter { $0.source == .item } + here.filter { $0.source == .code }
    }

    /// Gone, and never `default`.
    public var leaving: [PhoneProfile] { profiles.filter { !$0.isDefault && $0.gone != nil } }

    public var showsProfiles: Bool { listed.count >= 2 }
    public var showsProfileRow: Bool { showsProfiles || !leaving.isEmpty }

    public var activeProfile: PhoneProfile {
        let all = listed
        return all.first { $0.id == active } ?? all[0]
    }

    public var importDefault: PhoneProfile {
        listed.first { $0.id == importTarget } ?? activeProfile
    }

    /// The one listed profile with this name, trimmed and the letter case ignored; two that fit is nobody.
    public func profile(named name: String) -> PhoneProfile? {
        let fits = profiles(named: name)
        return fits.count == 1 ? fits[0] : nil
    }

    /// Every listed profile with this name, for the sentence that names the choices.
    public func profiles(named name: String) -> [PhoneProfile] {
        let wanted = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !wanted.isEmpty else { return [] }
        return listed.filter { $0.name.trimmingCharacters(in: .whitespacesAndNewlines).compare(wanted, options: .caseInsensitive) == .orderedSame }
    }

    /// What the Keychain gave. Not known changes nothing. No item: every profile the item had leaves, and the first
    /// profile's entry goes. An item: its entries in its order, renamed in place by id; one it dropped leaves (the
    /// first date stays); a coded one stays until the item has listed it once. An entry this build could not read is
    /// not dropped: that profile stays as it was, and with an entry whose id did not read, no profile leaves.
    public mutating func take(_ read: ProfilesItem.Read, now: Date) {
        switch read {
        case .unknown:
            return
        case .none:
            profiles.removeAll { $0.isDefault }
            for i in profiles.indices where profiles[i].source == .item && profiles[i].gone == nil { profiles[i].gone = now }
        case .found(let item):
            var next: [PhoneProfile] = []
            for entry in item.profiles {
                var p = profiles.first { $0.id == entry.id }
                    ?? PhoneProfile(id: entry.id, name: entry.name, color: entry.color, sync: nil, source: .item)
                p.name = entry.name
                p.color = entry.color
                p.syncName = entry.sync
                p.source = .item
                p.gone = nil
                next.append(p)
            }
            let listedIDs = Set(item.profiles.map(\.id))
            let unreadIDs = Set(item.unread.compactMap { $0 })
            let anyUnknown = item.unread.contains { $0 == nil }
            for var p in profiles where !listedIDs.contains(p.id) && !p.isDefault {
                if p.source == .item, p.gone == nil, !anyUnknown, !unreadIDs.contains(p.id) { p.gone = now }
                next.append(p)
            }
            profiles = next
        }
        dropMissingActive()
    }

    /// A scanned profile code: a new profile from the code, or the known one with the code's name, color, and sync.
    public mutating func add(_ code: ProfileCode, now: Date) {
        if let i = profiles.firstIndex(where: { $0.id == code.id }) {
            profiles[i].name = code.name
            profiles[i].color = code.color
            profiles[i].syncName = code.sync
            // A profile the item dropped comes back by its code, and stays until the item lists it again.
            if profiles[i].gone != nil { profiles[i].source = .code }
            profiles[i].gone = nil
        } else {
            profiles.append(PhoneProfile(id: code.id, name: code.name, color: code.color, sync: SyncChoice(rawValue: code.sync), source: .code))
        }
    }

    /// The owner's own "Remove from this iPhone": the profile leaves, as one the Mac dropped. Never `default`.
    public mutating func removeFromPhone(_ id: String, now: Date) {
        guard id != Profile.defaultID, let i = profiles.firstIndex(where: { $0.id == id }) else { return }
        if profiles[i].gone == nil { profiles[i].gone = now }
        dropMissingActive()
    }

    /// After the profile's folder is gone.
    public mutating func forget(_ id: String) {
        guard id != Profile.defaultID else { return }
        profiles.removeAll { $0.id == id }
        if active == id { active = nil }
        if importTarget == id { importTarget = nil }
    }

    private mutating func dropMissingActive() {
        if let active, !listed.contains(where: { $0.id == active }) { self.active = nil }
    }

    public var isEmpty: Bool {
        profiles.isEmpty && (active == nil || active == Profile.defaultID) && (importTarget == nil || importTarget == Profile.defaultID)
    }

    /// No book: the first profile, as before. A book that does not read: the first profile for this run, and the
    /// saved bytes are kept.
    public static func load(_ defaults: UserDefaults) -> PhoneProfileBook {
        guard let data = defaults.data(forKey: defaultsKey) else { return PhoneProfileBook() }
        guard let book = try? JSONDecoder().decode(PhoneProfileBook.self, from: data) else {
            var unknown = PhoneProfileBook()
            unknown.unreadable = true
            return unknown
        }
        return book
    }

    /// Removes the key when the book is empty. A book a newer build wrote, or one that did not read, is never saved
    /// over or removed.
    public func save(to defaults: UserDefaults) {
        guard version <= Self.currentVersion, !unreadable else { return }
        guard !isEmpty else {
            defaults.removeObject(forKey: Self.defaultsKey)
            return
        }
        guard let data = try? JSONEncoder().encode(self) else { return }
        defaults.set(data, forKey: Self.defaultsKey)
    }

    public enum Cleanup: Equatable, Sendable { case stays, holds(Int), unknown, waits, remove }

    /// How long a profile must be gone before its folder goes: one read with no item never removes one at once.
    public static let removalWait: TimeInterval = 7 * 86_400

    /// A profile's folder on the phone: it stays while the profile is listed; a gone one holds while a recording
    /// waits, is not known while its outbox or its audio cannot be read, waits while an import or an upload of it
    /// runs and for a week from its saved `gone` date, and goes only then, with both empty.
    public static func cleanup(_ profile: PhoneProfile, outbox: Int?, audio: Int?, busy: Bool, now: Date) -> Cleanup {
        guard !profile.isDefault, let gone = profile.gone else { return .stays }
        guard let outbox, let audio else { return .unknown }
        let held = max(outbox, audio)
        if held > 0 { return .holds(held) }
        if busy || now.timeIntervalSince(gone) < removalWait { return .waits }
        return .remove
    }
}

/// The phone's switch of profile.
public enum PhoneProfileSwitch {
    public static let recordingRefusal = "A room recording is running. Switch when it ends."
    public static let importRefusal = "A recording is being added. Switch when it is done."

    public enum Decision: Equatable, Sendable { case go(String), refused(String), stay }

    /// Only to a listed profile that is not the active one, and never while the recorder runs or an import is added.
    public static func decide(to id: String, book: PhoneProfileBook, active: String, recording: Bool, importing: Bool) -> Decision {
        guard id != active, book.listed.contains(where: { $0.id == id }) else { return .stay }
        if recording { return .refused(recordingRefusal) }
        if importing { return .refused(importRefusal) }
        return .go(id)
    }

    /// The order of a `.go`.
    public enum Step: String, CaseIterable, Sendable { case closeOld, remember, buildNew }
}

/// Whether a profile's store may still start work. A closed store (after a switch) starts nothing new and only
/// finishes an edit already made.
public struct StoreLife: Equatable, Sendable {
    public enum Work: CaseIterable, Sendable { case read, sync, index, findings, timer, finishEdit }

    public init() {}

    public private(set) var closed = false

    public mutating func close() { closed = true }

    public func allows(_ work: Work) -> Bool { !closed || work == .finishEdit }
}

/// The words of the phone's Profile row and screen.
public enum PhoneProfileWords {
    public static func label(_ name: String) -> String { "Profile, \(name)" }

    public static func waiting(_ count: Int) -> String {
        count == 1 ? "1 recording waits to send" : "\(count) recordings wait to send"
    }

    public static let leavingTitle = "No longer on your Mac"

    public static func leavingRow(name: String, count: Int) -> String {
        count == 1 ? "1 recording of “\(name)” was not sent" : "\(count) recordings of “\(name)” were not sent"
    }

    public static let leavingFooter = "Your Mac no longer has this profile, so Mossad does not send these recordings. Share a recording to keep it, or delete it."

    /// The one line under a profile that cannot sync as it is, or nil.
    public static func note(for profile: PhoneProfile, hasServer: Bool) -> String? {
        guard !profile.isDefault else { return nil }
        switch profile.sync {
        case nil: return "Open this profile in Mossad on your Mac once. Then this iPhone knows how it syncs."
        case .server: return hasServer ? nil : "Scan this profile's code on your Mac to connect its server."
        case .off: return "This profile does not sync on your Mac."
        case .icloud:
            return profile.source == .code ? "This profile syncs through iCloud. It reaches your Mac only when this iPhone uses the same iCloud account." : nil
        }
    }

    public static func noProfileNamed(_ name: String) -> String { "Mossad has no profile named “\(name)” on this iPhone." }
    public static func noneNamed(_ name: String, choices: [String]) -> String {
        "\(noProfileNamed(name)) Its profiles are \(choices.joined(separator: ", "))."
    }
    public static func manyNamed(_ name: String, choices: [String]) -> String {
        "More than one profile on this iPhone is named “\(name)”: \(choices.joined(separator: ", ")). Rename one on your Mac."
    }
    public static func connected(name: String, host: String) -> String { "Connected “\(name)” to \(host)." }
    public static func added(_ name: String) -> String { "Added “\(name)”." }
    public static let cannotOpen = "This profile could not be opened on this iPhone."
    public static let notInProfile = "That meeting is not in this profile on this iPhone."
}
