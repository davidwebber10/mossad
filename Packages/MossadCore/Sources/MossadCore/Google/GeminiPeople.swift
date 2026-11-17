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

    public static func matches(_ r: CallRecord, directory: [GoogleProfile]) -> [Match] {
        guard r.isNotesOnly else { return [] }
        let entries = (r.invitees ?? []).filter { $0.isSelf != true && $0.kind == nil }
        let invited = Set(entries.compactMap(\.email).map(EmailIdentity.normalized))
        var found: [String: Match] = [:]
        for (speaker, name) in r.speakerNames.sorted(by: { $0.key < $1.key }) where !speaker.hasPrefix("me:") {
            let wanted = PersonNames.nameKey(name)
            // A full name: one word could be anyone.
            guard wanted.contains(" ") else { continue }
            let named = directory.filter { $0.name.map(PersonNames.nameKey) == wanted }
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
                [o.name, o.email.flatMap(InviteRoster.name(fromAddress:))].compactMap { $0 }.contains { PersonNames.nameKey($0) == wanted }
            }) else { continue }
            found[email] = Match(name: spelled, email: email)
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
    /// run, so one held back now is read again later. `stop` (a call that started) ends the run between matches.
    /// Nothing is done without the people store's file in a state to write, or with a record of given addresses that
    /// cannot be read.
    @discardableResult
    public static func link(_ records: [CallRecord], library: VoiceLibrary, people store: PeopleStore, directory: [GoogleProfile], paths: Paths,
                            domains: CompanyDomains = .current, stop: () -> Bool = { false }) -> Outcome {
        var out = Outcome()
        guard !directory.isEmpty, var book = GeminiPeopleBook.load(paths) else { return out }
        var seen: Set<String> = []
        let all = records.flatMap { matches($0, directory: directory) }.filter { seen.insert($0.email).inserted }
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
            // The record comes first: an address that a failed save gave is never given again by this step.
            book.given.insert(m.email)
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
            // Nothing was given: the address may be given at a later run.
            if !added {
                book.given.remove(m.email)
                try? book.save(paths)
            }
        }
        return out
    }
}

/// The addresses that the Gemini people step gave, in the profile's data folder (`Google/gemini-people.json`). An
/// address is given once: a person the owner deleted, or an address the owner took off, does not come back.
public struct GeminiPeopleBook: Codable, Equatable, Sendable {
    public static let currentVersion = 1
    public var version = Self.currentVersion
    public var given: Set<String> = []

    public init(given: Set<String> = []) { self.given = given }

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
