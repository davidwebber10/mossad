import Foundation

/// The speakers of a meeting imported from Gemini notes have names but no voices, so nothing else makes them saved
/// people. A speaker becomes one, with an address, only on a sure match: the full name is the name of exactly one
/// person of the directory and the contacts, one address of that person is invited, and no other invited entry can
/// be someone of that name.
public enum GeminiPeople {
    public struct Match: Equatable, Sendable {
        /// The directory's spelling.
        public var name: String
        public var email: String
        /// Every address of the directory person: each is given once with the match.
        public var addresses: [String] = []

        public init(name: String, email: String, addresses: [String] = []) {
            self.name = name
            self.email = email
            self.addresses = addresses
        }

        public static func == (a: Match, b: Match) -> Bool { a.name == b.name && a.email == b.email }
    }

    /// The directory's people by the key of their name, made once for a run. A name with a part in brackets is
    /// looked up by its whole key, so "Sam Carter (Acme)" is never the plain Sam Carter.
    public struct Index: Sendable {
        let byName: [String: [GoogleProfile]]
        let byWhole: [String: [GoogleProfile]]

        public init(_ directory: [GoogleProfile]) {
            var byName: [String: [GoogleProfile]] = [:], byWhole: [String: [GoogleProfile]] = [:]
            for p in directory {
                guard let name = p.name else { continue }
                byName[PersonNames.nameKey(name), default: []].append(p)
                byWhole[PersonNames.key(name), default: []].append(p)
            }
            self.byName = byName
            self.byWhole = byWhole
        }

        static func hasBrackets(_ name: String) -> Bool { name.contains { "(<[".contains($0) } }
        static func key(_ name: String) -> String { hasBrackets(name) ? PersonNames.key(name) : PersonNames.nameKey(name) }
        func named(_ name: String) -> [GoogleProfile] { (Self.hasBrackets(name) ? byWhole : byName)[Self.key(name)] ?? [] }
        var isEmpty: Bool { byName.isEmpty }
    }

    /// Whether an address is the owner's: an address of the owner's person or voice, or one made of an owner's name.
    public static func ownerAddresses(people: [Person], profiles: [VoiceProfile]) -> (String) -> Bool {
        let owner = people.first { $0.isOwner && $0.isLive }
        let mine = profiles.filter(\.isOwner)
        let emails = Set((owner.map(InviteRoster.addresses(of:)) ?? []).union(mine.flatMap { $0.emails.map(EmailIdentity.normalized) }))
        let names = Set((owner?.forms.map(\.text) ?? []) + mine.map(\.name))
        return { email in emails.contains(email) || names.contains { CalendarInfo.isOwnersAddress(email, ownerName: $0) } }
    }

    /// What one run did, in counts only.
    public struct Outcome: Equatable, Sendable {
        public var made = 0
        public var joined = 0
        /// A match that a saved person, an address, or a guess holds back; it is read again at the next run.
        public var left = 0
        public var failed = 0
        public var stopped = false
    }

    public static func matches(_ r: CallRecord, directory: [GoogleProfile], isOwner: (String) -> Bool = { _ in false }) -> [Match] {
        matches(r, index: Index(directory), isOwner: isOwner)
    }

    public static func matches(_ r: CallRecord, index: Index, isOwner: (String) -> Bool = { _ in false }) -> [Match] {
        guard r.isNotesOnly else { return [] }
        let entries = (r.invitees ?? []).filter { $0.isSelf != true && $0.kind == nil }
        // The owner's address, also on an entry that the invite does not mark as the owner's.
        let invited = Set(entries.compactMap(\.email).map(EmailIdentity.normalized)).filter { !isOwner($0) }
        var found: [String: Match] = [:]
        for (speaker, name) in r.speakerNames.sorted(by: { $0.key < $1.key }) where !speaker.hasPrefix("me:") {
            let wanted = Index.key(name)
            // A full name: one word could be anyone.
            guard wanted.contains(" ") else { continue }
            let named = index.named(name)
            let people = named.filter { $0.source == .directory }
            guard people.count == 1, let person = people.first, let spelled = person.name else { continue }
            // A contact of that name at none of these addresses is another person who can be the speaker.
            guard !named.contains(where: { $0.source != .directory && Set($0.emails).isDisjoint(with: person.emails) }) else { continue }
            let fits = invited.intersection(person.emails)
            guard fits.count == 1, let email = fits.first, found[email] == nil else { continue }
            guard let local = CompanyDomains.split(email)?.local, !CompanyDomains.isRole(local) else { continue }
            // Another invited entry that can be someone of this name: a guest, or a forwarded invite.
            let others = entries.filter { $0.email.map(EmailIdentity.normalized) != email }
            guard !others.contains(where: { o in
                [o.name, o.email.flatMap(InviteRoster.name(fromAddress:))].compactMap { $0 }.contains { Index.key($0) == wanted }
            }) else { continue }
            found[email] = Match(name: spelled, email: email, addresses: person.emails)
        }
        return found.values.sorted { $0.email < $1.email }
    }

    public enum Verdict: Equatable, Sendable {
        /// Nobody saved can be this name: a new person with the address.
        case make
        /// The one saved person of this whole name, with no address: the address joins them (their name).
        case join(String)
        case leave
    }

    /// What to do with one match, by the project's identity rules: the address first (any state, the owner's "Not
    /// their address" too, and the company domains), then the name (`PersonResolver`, and `PersonDirectory.existing`
    /// for a join). Two who fit, a short form, a middle name, a renamed person's old name, and the owner are nobody.
    /// An address given once is never given again, so a person the owner deleted is not made again.
    public static func verdict(_ m: Match, people: [Person], profiles: [VoiceProfile], given: Set<String>, domains: CompanyDomains) -> Verdict {
        guard !given.contains(m.email) else { return .leave }
        let live = people.filter(\.isLive)
        guard !live.contains(where: { $0.emails.contains { $0.address == m.email } }),
              !profiles.contains(where: { $0.emails.contains { EmailIdentity.normalized($0) == m.email } }) else { return .leave }
        let resolver = PersonResolver(people: live, domains: domains)
        guard resolver.resolve(PersonObservation(email: m.email)) == .unknown else { return .leave }
        // A voice and its person are one name, not two who fit.
        var names: Set<String> = []
        let saved = (live.map(\.displayName) + profiles.map(\.name)).filter { names.insert($0).inserted }.map { PersonDirectory.Person(name: $0, email: nil) }
        switch resolver.resolve(PersonObservation(name: m.name)) {
        case .unknown:
            // A voice with no person in the store yet is read by the join rule and by its key.
            let key = PersonNames.nameKey(m.name)
            guard PersonDirectory.existing(name: m.name, email: nil, among: saved) == nil,
                  !profiles.contains(where: { PersonNames.nameKey($0.name) == key }) else { return .leave }
            return .make
        case .resolved(let id, let rule, _) where [.nameForm, .sameName, .provedOrder].contains(rule):
            guard let p = live.first(where: { $0.id == id }), !p.isOwner,
                  PersonDirectory.existing(name: m.name, email: nil, among: saved) == p.displayName,
                  InviteRoster.addresses(of: p).isEmpty, !InviteRoster.refuses(p, m.email) else { return .leave }
            // Its voice may have an address the store does not have yet.
            let own = profiles.filter { PeopleStore.id(forVoiceName: $0.name, isOwner: $0.isOwner, in: live) == id }
            guard own.allSatisfy({ !$0.isOwner && $0.emails.isEmpty }) else { return .leave }
            return .join(p.displayName)
        default:
            return .leave
        }
    }

    /// Saves each sure match of the meetings as a person with the address, the way the People page adds a person by
    /// address: one with no voice samples is made when nobody saved can be the name. Every meeting is read at each
    /// run, so one held back now is read again later. `stop` (a call that started) ends the run after any meeting or
    /// match. Nothing is done with a people store that cannot be written, or a record of given addresses that cannot
    /// be read.
    @discardableResult
    public static func link(_ records: [CallRecord], library: VoiceLibrary, people store: PeopleStore, directory: [GoogleProfile], paths: Paths,
                            domains: CompanyDomains = .current, stop: () -> Bool = { false }) -> Outcome {
        var out = Outcome()
        guard !directory.isEmpty, !store.isReadOnly, store.loadError == nil, var book = GeminiPeopleBook.load(paths) else { return out }
        book.settle(held: { held($0, people: store.people, profiles: library.profiles) }, paths: paths)
        let index = Index(directory)
        let isOwner = ownerAddresses(people: store.people, profiles: library.profiles)
        var seen: Set<String> = []
        var all: [Match] = []
        for r in records {
            if stop() { out.stopped = true; return out }
            all += matches(r, index: index, isOwner: isOwner).filter { seen.insert($0.email).inserted }
        }
        for m in all {
            if stop() { out.stopped = true; break }
            let decision = verdict(m, people: store.people, profiles: library.profiles, given: book.given, domains: domains)
            let name: String
            switch decision {
            case .leave:
                out.left += 1
                continue
            case .join(let saved): name = saved
            case .make: name = m.name
            }
            // The record comes first, with the new addresses pending until the write is done: a quit between the
            // two saves leaves them pending, and the next run gives them back if nobody holds one.
            let new = Set([m.email] + m.addresses.map(EmailIdentity.normalized)).subtracting(book.given)
            book.given.formUnion(new)
            book.pending = new
            do { try book.save(paths) } catch {
                Log.error("Gemini people: the record of given addresses was not saved: \(error)")
                out.failed += 1
                break
            }
            var added = false
            do {
                if decision == .make { try store.ensure(voiceName: name, isOwner: false, origin: .googleDirectory, actor: "google") }
                switch try library.addEmail(m.email, for: name, actor: "google") {
                case .added:
                    added = true
                    if decision == .make { out.made += 1 } else { out.joined += 1 }
                default: out.left += 1
                }
            } catch {
                Log.error("Gemini people: an address was not saved: \(error)")
                out.failed += 1
            }
            // Nothing was given: the addresses may be given at a later run.
            if !added { book.given.subtract(new) }
            book.pending = nil
            do { try book.save(paths) } catch { Log.error("Gemini people: the record of given addresses was not saved: \(error)") }
        }
        return out
    }

    /// Whether a live person or a voice has the address, in any state.
    static func held(_ address: String, people: [Person], profiles: [VoiceProfile]) -> Bool {
        people.contains { $0.isLive && $0.emails.contains { $0.address == address } }
            || profiles.contains { $0.emails.contains { EmailIdentity.normalized($0) == address } }
    }
}

/// The addresses that the Gemini people step gave or that the owner took away, in the profile's data folder
/// (`Google/gemini-people.json`). The step never gives one of them: a person the owner deleted, or an address the
/// owner removed, does not come back. `pending` holds the addresses of a write in progress.
public struct GeminiPeopleBook: Codable, Equatable, Sendable {
    public static let currentVersion = 1
    public var version = Self.currentVersion
    public var given: Set<String> = []
    public var pending: Set<String>?

    public init(given: Set<String> = [], pending: Set<String>? = nil) { self.given = given; self.pending = pending }

    public struct Unreadable: Error {}

    /// The owner removed these addresses or deleted their person: the step never gives them.
    public static func refuse(_ addresses: [String], paths: Paths) throws {
        let list = addresses.map(EmailIdentity.normalized).filter { $0.contains("@") }
        guard !list.isEmpty else { return }
        guard var book = load(paths) else { throw Unreadable() }
        let before = book
        book.given.formUnion(list)
        // A refused address never leaves the record through `settle`.
        if let pending = book.pending {
            let left = pending.subtracting(list)
            book.pending = left.isEmpty ? nil : left
        }
        if book != before { try book.save(paths) }
    }

    /// Before the owner deletes a person: each address of the voice and of the person, in any state, and each
    /// address of the directory's people with that name, so the step never makes them again.
    public static func refuse(personNamed name: String, library: VoiceLibrary, paths: Paths) throws {
        let profile = library.profiles.first { $0.name == name }
        var all = profile?.emails ?? []
        if let store = library.identity?.people, let id = store.id(forVoiceName: name, isOwner: profile?.isOwner ?? false), let p = store.person(id) {
            all += p.emails.map(\.address)
        }
        if let cache = GoogleDirectoryCache.load(paths) { all += GeminiPeople.Index(cache.profiles).named(name).flatMap(\.emails) }
        try refuse(all, paths: paths)
    }

    /// A write that a quit cut off: its addresses leave the record when nobody holds one of them.
    mutating func settle(held: (String) -> Bool, paths: Paths) {
        guard let pending else { return }
        if !pending.contains(where: held) { given.subtract(pending) }
        self.pending = nil
        do { try save(paths) } catch { Log.error("Gemini people: the record of given addresses was not saved: \(error)") }
    }

    public static func url(_ paths: Paths) -> URL { paths.root.appendingPathComponent("Google").appendingPathComponent("gemini-people.json") }

    /// Empty when there is no file; nil when the file cannot be read or is from a newer build, so nothing is given.
    public static func load(_ paths: Paths) -> GeminiPeopleBook? {
        guard let data = try? Data(contentsOf: url(paths)) else {
            return FileManager.default.fileExists(atPath: url(paths).path) ? nil : GeminiPeopleBook()
        }
        guard let book = try? JSONDecoder().decode(GeminiPeopleBook.self, from: data), book.version <= currentVersion else { return nil }
        return book
    }

    public func save(_ paths: Paths) throws {
        try FileManager.default.createDirectory(at: Self.url(paths).deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: Self.url(paths), options: .atomic)
    }
}
