import CryptoKit
import Foundation

/// What both devices write and read: chats, the owner's ratings and conversation on a review, and the
/// coach's memory. Meetings themselves come only from the Mac.
public struct SharedPayload: Sendable {
    public enum Kind: String, Sendable { case chat, notes, profile, commitments, people, personas }

    public let kind: Kind
    /// "chat:<uuid>", "notes:<call id>", or "profile": the record name and the key in the sync state.
    public let key: String
    public let data: Data
    public let hash: String

    init(kind: Kind, key: String, data: Data) {
        self.kind = kind
        self.key = key
        self.data = data
        hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Whether a sync-state key belongs to a shared record, not a meeting: "chat:…", "notes:…", "profile", "commitments".
    static func isShared(_ key: String) -> Bool { key.contains(":") || key == "profile" || key == "commitments" || key == "people" || key == "personas" }

    public static func chat(_ chat: Chat) -> SharedPayload {
        SharedPayload(kind: .chat, key: "chat:\(chat.id.uuidString)", data: (try? JSONEncoder.callRecord.encode(chat)) ?? Data())
    }

    /// Only the owner's own part of a review: the Mac's coach writes the rest.
    public static func notes(callID: String, review: CoachReview) -> SharedPayload? {
        guard !review.feedback.isEmpty || !review.thread.isEmpty else { return nil }
        let notes = ReviewNotes(feedback: review.feedback, thread: review.thread)
        return SharedPayload(kind: .notes, key: "notes:\(callID)", data: (try? JSONEncoder.callRecord.encode(notes)) ?? Data())
    }

    public static func commitments(_ book: CommitmentBook) -> SharedPayload {
        SharedPayload(kind: .commitments, key: "commitments", data: (try? JSONEncoder.callRecord.encode(book)) ?? Data())
    }

    /// The people, from the Mac to the phone: only the fields of `SyncedPeople`, with the company's domains.
    public static func people(_ people: [Person], domains: CompanyDomains = .current) -> SharedPayload {
        SharedPayload(kind: .people, key: "people", data: (try? JSONEncoder.callRecord.encode(SyncedPeople(people, domains: domains))) ?? Data())
    }

    public static func profile(_ profile: CoachProfile) -> SharedPayload {
        SharedPayload(kind: .profile, key: "profile", data: (try? JSONEncoder.callRecord.encode(profile)) ?? Data())
    }
}

/// The owner's ratings and conversation on one review, as they travel between devices.
public struct ReviewNotes: Codable, Sendable {
    public var feedback: [String: CoachFeedback]
    public var thread: [ChatMessage]
}

extension SyncState {
    /// Shared records to upload, and the chats to delete in the store: only the ones deleted here on purpose
    /// (`deletedChats`). A chat that is merely not in `payloads` may be a file that could not be read.
    public func planShared(_ payloads: [SharedPayload], deletedChats: Set<UUID> = []) -> (upload: [SharedPayload], delete: [String]) {
        let keys = Set(payloads.map(\.key))
        return (payloads.filter { uploaded[$0.key] != $0.hash },
                deletedChats.map { "chat:\($0.uuidString)" }.filter { !keys.contains($0) }.sorted())
    }
}

/// The people as they go from the Mac to the phone and the owner's server. Built from a list of allowed fields, not
/// by removing fields from the whole record: a new private field of `Person` never syncs by accident. Never in it:
/// voice samples, the org data, ids of other services, the owner's own note on a person, a photo. The job title and
/// the team from the directory go, by the owner's choice, to the owner's own devices and server. It reads as the
/// people file (`version` and `people`, and `companyDomains` that the phone reads apart), so the phone keeps it as
/// its `people.json`.
public struct SyncedPeople: Codable, Equatable, Sendable {
    public struct Entry: Codable, Equatable, Sendable {
        public var id: PersonID
        public var displayName: String
        public var name: NameParts
        public var forms: [NameForm]
        public var emails: [EmailIdentity]
        public var isOwner: Bool
        public var company: String?
        public var doNotProfile: Bool
        public var provisional: Bool
        public var distinctFrom: [PersonID]
        public var mergedFrom: [PersonID]
        public var mergedInto: PersonID?
        public var created: Date
        public var updated: Date
        public var deleted: Date?
        /// The job and the team; never the photo, which stays on the Mac.
        public var directory: DirectoryDetails?

        init(_ p: Person) {
            id = p.id
            displayName = p.displayName
            name = p.name
            forms = p.forms
            emails = p.emails
            isOwner = p.isOwner
            company = p.company
            doNotProfile = p.doNotProfile
            provisional = p.provisional
            distinctFrom = p.distinctFrom
            mergedFrom = p.mergedFrom
            mergedInto = p.mergedInto
            created = p.created
            updated = p.updated
            deleted = p.deleted
            directory = p.directory.map { DirectoryDetails(jobTitle: $0.jobTitle, department: $0.department, photoURL: nil, source: $0.source, updated: $0.updated) }
                .flatMap { $0.jobTitle == nil && $0.department == nil ? nil : $0 }
        }
    }

    /// The keys a person may have in the payload. A test fails when the payload has any other key.
    public static let allowedKeys: Set<String> = ["id", "displayName", "name", "forms", "emails", "isOwner", "company", "doNotProfile", "provisional",
                                                  "distinctFrom", "mergedFrom", "mergedInto", "created", "updated", "deleted", "directory"]

    public var version = PeopleStore.currentVersion
    public var people: [Entry]
    /// The company's domains, so the phone links an address as the Mac does. Nil when the owner listed none.
    public var companyDomains: [String]?

    public init(_ people: [Person], domains: CompanyDomains = .none) {
        self.people = people.sorted { $0.id < $1.id }.map(Entry.init)
        companyDomains = domains.isEmpty ? nil : domains.domains
    }

    /// The domains in a people file or payload; none when it has no list.
    public static func domains(in data: Data) -> CompanyDomains {
        struct Domains: Decodable { var companyDomains: [String]? }
        return CompanyDomains((try? JSONDecoder.callRecord.decode(Domains.self, from: data))?.companyDomains ?? [])
    }
}
