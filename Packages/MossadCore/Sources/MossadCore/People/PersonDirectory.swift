import Foundation

/// The saved people, for turning a name or an email written in a meeting into the person it stands for.
///
/// There are two questions, with two answers. `link` says whose profile a click on the name opens: only a sure
/// match, because a wrong profile is worse than no link. `match` says which saved person an invited name is: it
/// may read a short form, but only among the people of the meeting, and only when one of them fits.
public struct PersonDirectory: Sendable, Equatable {
    public struct Person: Sendable, Equatable {
        public var name: String
        public var email: String?

        public init(name: String, email: String?) {
            self.name = name
            self.email = email
        }
    }

    public let people: [Person]
    private let resolver: PersonResolver
    private let names: [PersonID: String]
    private let contexts = ContextCache()

    /// The address one meeting's invite gave with each name, by the key of the name.
    private var inviteEmails: [String: String] = [:]

    public static func == (a: PersonDirectory, b: PersonDirectory) -> Bool { a.people == b.people && a.inviteEmails == b.inviteEmails }

    /// The same people for one meeting's invite: an invited name carries the address the invite gave with it, so
    /// a name that fits nobody is still the saved person with that address.
    public func with(invitees: [Invitee]?) -> PersonDirectory {
        var copy = self
        copy.inviteEmails = Invitee.emails(byName: invitees)
        return copy
    }

    /// A written entry as the resolver wants it, with the invite's address for a name.
    private func observation(_ text: String) -> PersonObservation {
        var o = PersonObservation(text: text)
        if o.email == nil, let name = o.name { o.email = inviteEmails[PersonNames.nameKey(name)] }
        return o
    }

    public init(_ people: [Person] = []) {
        self.people = people
        var names: [PersonID: String] = [:]
        var records: [MossadCore.Person] = []
        for (i, p) in people.enumerated() {
            // The ids keep the order of the list, so "the first one" is the same person as before.
            var record = MossadCore.Person(id: PersonID(rawValue: String(format: "%08d", i)), displayName: p.name, origin: .voiceNaming, at: .distantPast)
            if let email = p.email { record.addEmail(email, state: .verified, source: .voiceNaming, at: .distantPast) }
            names[record.id] = p.name
            records.append(record)
        }
        self.names = names
        resolver = PersonResolver(people: records)
    }

    public init(profiles: [VoiceProfile]) {
        self.init(profiles.map { Person(name: $0.name, email: $0.email) })
    }

    /// Lowercase words without the period of an initial: "Sam C." gives "sam", "c".
    private static func words(_ name: String) -> [String] {
        name.lowercased().split(whereSeparator: \.isWhitespace).map { $0.trimmingCharacters(in: CharacterSet(charactersIn: ".,")) }.filter { !$0.isEmpty }
    }

    /// Whether `written` can be a form of the name `full`: the same first name or its short form, and, when
    /// `written` has more words, the same last name or its initial.
    private static func fits(_ written: [String], _ full: [String]) -> Bool {
        guard let first = written.first, let theirFirst = full.first, first == theirFirst || Nicknames.shortAndFull(first, theirFirst) else { return false }
        guard written.count > 1, let last = written.last else { return true }
        guard full.count > 1, let theirLast = full.last else { return false }
        return last == theirLast || (last.count == 1 && theirLast.hasPrefix(last))
    }

    /// Whether a name as someone wrote it ("Sam", "Sam C.") can stand for the full name `full`. A label such as
    /// "Speaker C" and an email are not names.
    public static func isForm(_ written: String, of full: String) -> Bool {
        guard !written.contains("@"), !written.hasPrefix("Speaker ") else { return false }
        let short = words(written)
        return !short.isEmpty && fits(short, words(full))
    }

    // MARK: Links

    /// The rules that are sure enough to open a profile: an email, a whole name in any written form, and the two
    /// names in the other order when that person is in the meeting. Never a first name or a short form.
    private static let sure: Set<Resolution.Rule> = [.ownerLink, .verifiedEmail, .seenEmail, .externalID, .nameForm, .provedOrder, .sameName, .swappedName]

    /// The people of a meeting as the resolver wants them: the saved ones, and the names of the others. An email
    /// and a label such as "Speaker C" are not names.
    private func context(_ meeting: [String]) -> ResolutionContext {
        // A page asks about each of its names with the same meeting, so the last answer is kept.
        if let hit = contexts.get(meeting) { return hit }
        var context = ResolutionContext()
        for name in meeting where !name.contains("@") && !name.hasPrefix("Speaker ") {
            // With nobody around it, a name resolves only by a sure rule, or as a person saved under that one word.
            if case .resolved(let id, _, _) = resolver.resolve(PersonObservation(name: name), in: ResolutionContext()) {
                if !context.roster.contains(id) { context.roster.append(id) }
            } else {
                context.otherNames.append(name)
            }
        }
        contexts.set(meeting, context)
        return context
    }

    /// The people of the last meeting asked about.
    private final class ContextCache: @unchecked Sendable {
        private let lock = NSLock()
        private var last: (meeting: [String], context: ResolutionContext)?

        func get(_ meeting: [String]) -> ResolutionContext? { lock.withLock { last?.meeting == meeting ? last?.context : nil } }
        func set(_ meeting: [String], _ context: ResolutionContext) { lock.withLock { last = (meeting, context) } }
    }

    /// The saved person whose profile `text` may open: the person with that email, or the one saved person with
    /// that name of two words or more, in any written form ("Carter, Sam", "CARTER Sam", "Sam A. Carter"). A name
    /// in the other order with no proof ("Carter Sam") is a link only when that person is in `meeting`. A first
    /// name, a short form, an initial, or a person saved under one word ("Sam") opens nothing.
    public func link(for text: String, in meeting: [String] = []) -> String? {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        switch resolver.resolve(observation(text), in: context(meeting)) {
        case .resolved(let id, let rule, _) where Self.sure.contains(rule): return names[id]
        // Two saved people with one email: the first one, as before there were rules.
        case .ambiguous(let ids, .verifiedEmail): return ids.first.flatMap { names[$0] }
        default: return nil
        }
    }

    // MARK: Matching

    /// The saved person that an invited name or email is. In this order: their email; the one saved person with
    /// that name of two words or more, in any written form; then, only among `meeting` (the speakers and the other
    /// invited people, saved or not), the one person the name can be a form of ("Sam" or "Sam C." for Sam Carter,
    /// "Sam Reed" for Samuel Reed, "Carter Sam" for Sam Carter), when that person is saved. Two who fit, or one who
    /// is not saved, is nobody.
    public func match(_ text: String, among meeting: [String] = []) -> String? {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        switch resolver.resolve(observation(text), in: context(meeting)) {
        case .resolved(let id, _, _): return names[id]
        case .ambiguous(let ids, .verifiedEmail): return ids.first.flatMap { names[$0] }
        default: return nil
        }
    }

    /// The saved person a typed name or a picked email stands for, when a voice is named: a join of the voice to
    /// that person. Only a sure match joins: the email, or the whole name in either order ("Carter, Sam", "Carter
    /// Sam", "Dr. Sam Carter" for Sam Carter). A short first name, a middle name on one side, a name a letter off,
    /// and a name that two saved people fit are guesses: they give nil, and the voice gets the name as typed. A
    /// part in brackets ("Sam Carter (Acme)") is the owner's way to name another person, so it is never read away.
    /// Two saved people with one email, or with one name in another case, are the first one, as before.
    public static func existing(name: String, email: String?, among people: [Person]) -> String? {
        if let email = email.map(EmailIdentity.normalized), !email.isEmpty,
           let hit = people.first(where: { $0.email.map(EmailIdentity.normalized) == email }) { return hit.name }
        let key = PersonNames.key(name)
        guard !key.isEmpty else { return nil }
        if let hit = people.first(where: { PersonNames.key($0.name) == key }) { return hit.name }
        guard !name.contains(where: { "(<[".contains($0) }) else { return nil }
        let typed = PersonNames.parse(name)
        guard typed.isName, typed.words.count >= 2 else { return nil }
        let words = typed.words.sorted()
        let hits = people.filter { p in
            let saved = PersonNames.parse(p.name)
            return saved.isName && saved.words.sorted() == words
        }
        return hits.count == 1 ? hits[0].name : nil
    }

    public func existing(name: String, email: String?) -> String? { Self.existing(name: name, email: email, among: people) }
}
