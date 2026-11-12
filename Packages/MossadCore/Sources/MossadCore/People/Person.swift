import Foundation

/// The id of a person: a lowercase UUID. It never changes and is never used again.
public struct PersonID: RawRepresentable, Hashable, Codable, Sendable, Comparable, CustomStringConvertible {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init() { rawValue = UUID().uuidString.lowercased() }
    public var description: String { rawValue }
    public static func < (a: PersonID, b: PersonID) -> Bool { a.rawValue < b.rawValue }
}

/// Where a value came from. Text, not a closed list, so a file from a newer build still reads.
public struct SourceKind: RawRepresentable, Hashable, Codable, Sendable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }

    public static let owner = SourceKind(rawValue: "owner")
    public static let voiceNaming = SourceKind(rawValue: "voiceNaming")
    public static let calendar = SourceKind(rawValue: "calendar")
    public static let orgChart = SourceKind(rawValue: "orgChart")
    public static let migration = SourceKind(rawValue: "migration")
    public static let call = SourceKind(rawValue: "call")
    /// Google's company directory or the owner's Google contacts.
    public static let googleDirectory = SourceKind(rawValue: "googleDirectory")
    public static let googleContacts = SourceKind(rawValue: "googleContacts")
    /// A name read from an email address, such as "Robin Ash" from "robin.ash@": a directory's name replaces it.
    public static let address = SourceKind(rawValue: "address")
}

/// What a directory says about a person: the job, the team, and the photo. Filled again at each read; the owner's
/// own words are never here.
public struct DirectoryDetails: Codable, Equatable, Sendable {
    public var jobTitle: String?
    public var department: String?
    public var photoURL: URL?
    public var source: SourceKind
    public var updated: Date

    public init(jobTitle: String?, department: String?, photoURL: URL?, source: SourceKind, updated: Date) {
        self.jobTitle = jobTitle
        self.department = department
        self.photoURL = photoURL
        self.source = source
        self.updated = updated
    }

    /// The same facts, whenever they were read.
    func sameFacts(as other: DirectoryDetails?) -> Bool {
        guard let other else { return false }
        return jobTitle == other.jobTitle && department == other.department && photoURL == other.photoURL && source == other.source
    }
}

/// The parts of a name, as keys. A part can be missing.
public struct NameParts: Codable, Equatable, Sendable {
    public var given: String?
    public var middle: [String]
    public var family: String?
    public var suffix: String?

    public init(given: String? = nil, middle: [String] = [], family: String? = nil, suffix: String? = nil) {
        self.given = given
        self.middle = middle
        self.family = family
        self.suffix = suffix
    }

    public init(_ parsed: ParsedName) {
        self.init(given: parsed.given, middle: parsed.middle, family: parsed.family, suffix: parsed.suffix)
    }

    enum CodingKeys: String, CodingKey { case given, middle, family, suffix }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        given = try c.decodeIfPresent(String.self, forKey: .given)
        middle = try c.decodeIfPresent([String].self, forKey: .middle) ?? []
        family = try c.decodeIfPresent(String.self, forKey: .family)
        suffix = try c.decodeIfPresent(String.self, forKey: .suffix)
    }
}

/// One written form of a person's name.
public struct NameForm: Codable, Equatable, Sendable {
    public struct Kind: RawRepresentable, Hashable, Codable, Sendable {
        public let rawValue: String
        public init(rawValue: String) { self.rawValue = rawValue }

        /// The name Mossad shows.
        public static let display = Kind(rawValue: "display")
        /// Another name the owner gave for this person.
        public static let alias = Kind(rawValue: "alias")
        /// A name the person had before: it continues to resolve.
        public static let former = Kind(rawValue: "former")
        public static let nickname = Kind(rawValue: "nickname")
        /// A source showed it next to this person.
        public static let seen = Kind(rawValue: "seen")
    }

    /// As written: "Carter, Sam".
    public var text: String
    /// `PersonNames.nameKey(text)`: "carter sam".
    public var key: String
    public var kind: Kind
    public var source: SourceKind
    /// The owner entered or accepted it.
    public var confirmed: Bool
    public var firstSeen: Date
    public var lastSeen: Date

    public init(text: String, kind: Kind, source: SourceKind, confirmed: Bool, at date: Date) {
        self.text = text
        key = PersonNames.nameKey(text)
        self.kind = kind
        self.source = source
        self.confirmed = confirmed
        firstSeen = date
        lastSeen = date
    }

    enum CodingKeys: String, CodingKey { case text, key, kind, source, confirmed, firstSeen, lastSeen }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        text = try c.decode(String.self, forKey: .text)
        key = try c.decodeIfPresent(String.self, forKey: .key) ?? PersonNames.nameKey(text)
        kind = try c.decodeIfPresent(Kind.self, forKey: .kind) ?? .seen
        source = try c.decodeIfPresent(SourceKind.self, forKey: .source) ?? .migration
        confirmed = try c.decodeIfPresent(Bool.self, forKey: .confirmed) ?? false
        firstSeen = try c.decodeIfPresent(Date.self, forKey: .firstSeen) ?? .distantPast
        lastSeen = try c.decodeIfPresent(Date.self, forKey: .lastSeen) ?? firstSeen
    }
}

/// How sure a value of a person is.
public struct IdentityState: RawRepresentable, Hashable, Codable, Sendable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }

    /// The owner typed or picked it for this person.
    public static let verified = IdentityState(rawValue: "verified")
    /// A source showed it next to this person. It resolves only while one person has it.
    public static let seen = IdentityState(rawValue: "seen")
    /// The owner said it is not this person's.
    public static let rejected = IdentityState(rawValue: "rejected")
}

public struct EmailIdentity: Codable, Equatable, Sendable {
    /// Lowercase, with no other change.
    public var address: String
    public var state: IdentityState
    /// A team or room address: it never identifies a person.
    public var shared: Bool
    public var source: SourceKind
    public var firstSeen: Date
    public var lastSeen: Date

    public init(address: String, state: IdentityState, shared: Bool = false, source: SourceKind, at date: Date) {
        self.address = Self.normalized(address)
        self.state = state
        self.shared = shared
        self.source = source
        firstSeen = date
        lastSeen = date
    }

    public static func normalized(_ address: String) -> String { address.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }

    enum CodingKeys: String, CodingKey { case address, state, shared, source, firstSeen, lastSeen }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        address = Self.normalized(try c.decode(String.self, forKey: .address))
        state = try c.decodeIfPresent(IdentityState.self, forKey: .state) ?? .seen
        shared = try c.decodeIfPresent(Bool.self, forKey: .shared) ?? false
        source = try c.decodeIfPresent(SourceKind.self, forKey: .source) ?? .migration
        firstSeen = try c.decodeIfPresent(Date.self, forKey: .firstSeen) ?? .distantPast
        lastSeen = try c.decodeIfPresent(Date.self, forKey: .lastSeen) ?? firstSeen
    }
}

/// A person's id in another service. No source writes one yet; the resolver reads them.
public struct SourceIdentity: Codable, Equatable, Sendable {
    public var source: SourceKind
    /// The workspace or team it belongs to.
    public var account: String?
    /// "userID", "phone", "handle", or "displayName".
    public var kind: String
    public var value: String
    /// The display name the source showed.
    public var label: String?
    public var state: IdentityState
    public var firstSeen: Date
    public var lastSeen: Date

    public init(source: SourceKind, account: String? = nil, kind: String, value: String, label: String? = nil, state: IdentityState, at date: Date) {
        self.source = source
        self.account = account
        self.kind = kind
        self.value = value
        self.label = label
        self.state = state
        firstSeen = date
        lastSeen = date
    }

    func isSame(_ other: SourceIdentity) -> Bool {
        source == other.source && account == other.account && kind == other.kind && value == other.value
    }

    enum CodingKeys: String, CodingKey { case source, account, kind, value, label, state, firstSeen, lastSeen }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        source = try c.decode(SourceKind.self, forKey: .source)
        account = try c.decodeIfPresent(String.self, forKey: .account)
        kind = try c.decodeIfPresent(String.self, forKey: .kind) ?? "userID"
        value = try c.decode(String.self, forKey: .value)
        label = try c.decodeIfPresent(String.self, forKey: .label)
        state = try c.decodeIfPresent(IdentityState.self, forKey: .state) ?? .seen
        firstSeen = try c.decodeIfPresent(Date.self, forKey: .firstSeen) ?? .distantPast
        lastSeen = try c.decodeIfPresent(Date.self, forKey: .lastSeen) ?? firstSeen
    }
}

/// One person, in `~/Mossad/People/people.json`. The id is the truth; each name is a label. Voice samples and
/// org data are not here.
public struct Person: Codable, Equatable, Sendable, Identifiable {
    public var id: PersonID
    /// What Mossad shows. The owner can change it.
    public var displayName: String
    public var name: NameParts
    /// Every written form: the display name, former names, and forms that sources showed.
    public var forms: [NameForm]
    public var emails: [EmailIdentity]
    public var identities: [SourceIdentity]
    /// The person who records. One person at most.
    public var isOwner: Bool
    public var company: String?
    public var note: String?
    public var doNotProfile: Bool
    /// Made by a source, and not yet met or confirmed.
    public var provisional: Bool
    /// The owner said these are other people.
    public var distinctFrom: [PersonID]
    /// The ids this record took in.
    public var mergedFrom: [PersonID]
    /// Set on a record that another one took in: it is a redirect now.
    public var mergedInto: PersonID?
    public var created: Date
    public var origin: SourceKind
    public var updated: Date
    /// A marker with no personal data, so the id is never used again.
    public var deleted: Date?
    /// The job title, the department, and the photo from Google's directory or contacts; nil without one. Local:
    /// the people sync does not send it.
    public var directory: DirectoryDetails?

    public init(id: PersonID = PersonID(), displayName: String, isOwner: Bool = false, origin: SourceKind, at date: Date) {
        self.id = id
        self.displayName = displayName
        name = NameParts(PersonNames.parse(displayName))
        forms = [NameForm(text: displayName, kind: .display, source: origin, confirmed: true, at: date)]
        emails = []
        identities = []
        self.isOwner = isOwner
        doNotProfile = false
        provisional = false
        distinctFrom = []
        mergedFrom = []
        created = date
        self.origin = origin
        updated = date
    }

    /// A person that links can go to: not deleted, and not a redirect.
    public var isLive: Bool { deleted == nil && mergedInto == nil }

    enum CodingKeys: String, CodingKey {
        case id, displayName, name, forms, emails, identities, isOwner, company, note, doNotProfile, provisional
        case distinctFrom, mergedFrom, mergedInto, created, origin, updated, deleted, directory
    }

    // Each field that can be missing has a default, so a file from an older build reads.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(PersonID.self, forKey: .id)
        displayName = try c.decodeIfPresent(String.self, forKey: .displayName) ?? ""
        name = try c.decodeIfPresent(NameParts.self, forKey: .name) ?? NameParts(PersonNames.parse(displayName))
        forms = try c.decodeIfPresent([NameForm].self, forKey: .forms) ?? []
        emails = try c.decodeIfPresent([EmailIdentity].self, forKey: .emails) ?? []
        identities = try c.decodeIfPresent([SourceIdentity].self, forKey: .identities) ?? []
        isOwner = try c.decodeIfPresent(Bool.self, forKey: .isOwner) ?? false
        company = try c.decodeIfPresent(String.self, forKey: .company)
        note = try c.decodeIfPresent(String.self, forKey: .note)
        doNotProfile = try c.decodeIfPresent(Bool.self, forKey: .doNotProfile) ?? false
        provisional = try c.decodeIfPresent(Bool.self, forKey: .provisional) ?? false
        distinctFrom = try c.decodeIfPresent([PersonID].self, forKey: .distinctFrom) ?? []
        mergedFrom = try c.decodeIfPresent([PersonID].self, forKey: .mergedFrom) ?? []
        mergedInto = try c.decodeIfPresent(PersonID.self, forKey: .mergedInto)
        created = try c.decodeIfPresent(Date.self, forKey: .created) ?? .distantPast
        origin = try c.decodeIfPresent(SourceKind.self, forKey: .origin) ?? .migration
        updated = try c.decodeIfPresent(Date.self, forKey: .updated) ?? created
        deleted = try c.decodeIfPresent(Date.self, forKey: .deleted)
        directory = try c.decodeIfPresent(DirectoryDetails.self, forKey: .directory)
    }
}

extension Person {
    /// The verified address, for the one-email views of today.
    public var email: String? { emails.first { $0.state == .verified }?.address }

    /// Adds a written form, or marks an existing one as seen again. Returns true when the record changed.
    @discardableResult
    public mutating func addForm(_ text: String, kind: NameForm.Kind, source: SourceKind, confirmed: Bool, at date: Date) -> Bool {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = PersonNames.nameKey(text)
        guard !key.isEmpty else { return false }
        if let i = forms.firstIndex(where: { $0.key == key && $0.text == text }) {
            // A form the owner confirmed stays confirmed; the kind of a known form does not change by a sighting.
            guard confirmed, !forms[i].confirmed else { return false }
            forms[i].confirmed = true
            forms[i].lastSeen = date
            updated = date
            return true
        }
        forms.append(NameForm(text: text, kind: kind, source: source, confirmed: confirmed, at: date))
        updated = date
        return true
    }

    /// Adds an address, or raises a seen one to verified. A rejected address stays rejected.
    @discardableResult
    public mutating func addEmail(_ address: String, state: IdentityState, source: SourceKind, at date: Date) -> Bool {
        let address = EmailIdentity.normalized(address)
        guard address.contains("@") else { return false }
        if let i = emails.firstIndex(where: { $0.address == address }) {
            guard emails[i].state == .seen, state == .verified else { return false }
            emails[i].state = .verified
            emails[i].lastSeen = date
            updated = date
            return true
        }
        emails.append(EmailIdentity(address: address, state: state, source: source, at: date))
        updated = date
        return true
    }

    /// One verified address, as the People page keeps it today: a new one replaces the old one, and nil or a
    /// blank one clears it. Returns true when the record changed.
    @discardableResult
    public mutating func setVerifiedEmail(_ email: String?, at date: Date) -> Bool {
        let address = email.map(EmailIdentity.normalized).flatMap { $0.contains("@") ? $0 : nil }
        guard address != self.email else { return false }
        emails.removeAll { $0.state == .verified }
        if let address {
            emails.removeAll { $0.address == address }
            emails.insert(EmailIdentity(address: address, state: .verified, source: .owner, at: date), at: 0)
        }
        updated = date
        return true
    }

    /// Gives the person a new display name. The old one stays as a former form, so it continues to resolve.
    public mutating func rename(to new: String, source: SourceKind, at date: Date) {
        let new = new.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !new.isEmpty, new != displayName else { return }
        for i in forms.indices where forms[i].kind == .display { forms[i].kind = .former }
        if let i = forms.firstIndex(where: { $0.text == new }) {
            forms[i].kind = .display
            forms[i].confirmed = true
            forms[i].lastSeen = date
        } else {
            forms.append(NameForm(text: new, kind: .display, source: source, confirmed: true, at: date))
        }
        displayName = new
        name = NameParts(PersonNames.parse(new))
        updated = date
    }
}
