import Foundation

/// What a source showed: a name, an address, or both of one participant.
public struct Observation: Sendable, Equatable {
    public var source: SourceKind
    public var account: String?
    public var name: String?
    public var email: String?
    public var identity: SourceIdentity?

    public init(name: String? = nil, email: String? = nil, source: SourceKind = .call, account: String? = nil, identity: SourceIdentity? = nil) {
        self.name = name
        self.email = email
        self.source = source
        self.account = account
        self.identity = identity
    }

    /// One written entry of today's lists: an address, a name, or "Name <address>".
    public init(text: String, source: SourceKind = .call) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let inner = PersonNames.email(in: text) {
            self.init(name: text, email: inner, source: source)
        } else if text.contains("@") {
            self.init(email: text, source: source)
        } else {
            self.init(name: text, source: source)
        }
    }
}

/// The closed world of one meeting: a short name can mean only someone who is there.
public struct ResolutionContext: Sendable, Equatable {
    /// The saved people known to be there.
    public var roster: [PersonID]
    /// The names there that are not saved people.
    public var otherNames: [String]

    public init(roster: [PersonID] = [], otherNames: [String] = []) {
        self.roster = roster
        self.otherNames = otherNames
    }
}

public enum Resolution: Equatable, Sendable {
    /// The rules, in their order. The raw value is the number in the design.
    public enum Rule: String, Sendable, Codable, CaseIterable {
        case ownerLink = "0"
        case verifiedEmail = "1"
        case seenEmail = "1b"
        case externalID = "2"
        case nameForm = "3a"
        case provedOrder = "3b"
        case sameName = "3c"
        case swappedName = "3d"
        case nickname = "4"
        case shortName = "4b"
        case similar = "5"

        /// In plain words, for the report.
        public var words: String {
            switch self {
            case .ownerLink: "the owner's own link"
            case .verifiedEmail: "email"
            case .seenEmail: "an email seen with this person"
            case .externalID: "the id of the source"
            case .nameForm: "a known written form"
            case .provedOrder: "last name first"
            case .sameName: "the same first and last name"
            case .swappedName: "the two names in the other order"
            case .nickname: "a short first name"
            case .shortName: "a first name in this meeting"
            case .similar: "a name that is almost the same"
            }
        }
    }

    public enum Confidence: Int, Sendable, Comparable {
        case weak, probable, strong, certain
        public static func < (a: Confidence, b: Confidence) -> Bool { a.rawValue < b.rawValue }
    }

    /// One person fits.
    case resolved(PersonID, rule: Rule, confidence: Confidence)
    /// Two or more fit: nobody.
    case ambiguous([PersonID], rule: Rule)
    /// Probable or weak: something to show the owner, never a link.
    case suggestion(PersonID, rule: Rule, evidence: [String])
    case unknown

    public var person: PersonID? {
        if case .resolved(let id, _, _) = self { return id }
        return nil
    }

    public var rule: Rule? {
        switch self {
        case .resolved(_, let rule, _), .ambiguous(_, let rule), .suggestion(_, let rule, _): rule
        case .unknown: nil
        }
    }
}

/// Two saved people who are probably one.
public struct PersonSuggestion: Equatable, Sendable, Identifiable {
    public var first: PersonID
    public var second: PersonID
    public var rule: Resolution.Rule
    /// The same for both orders, so a rename does not open it again.
    public var id: String { [first.rawValue, second.rawValue].sorted().joined(separator: "|") }
}

/// Says which saved person an observation is. Pure: built from a copy of the people, with no file and no clock.
/// It links an observed name to a person. It never joins two person records.
public struct PersonResolver: Sendable {
    private struct Entry: Sendable {
        let person: Person
        let names: [ParsedName]
        let keys: Set<String>
        let confirmedKeys: Set<String>
    }

    private let entries: [Entry]
    private let index: [PersonID: Int]

    public init(people: [Person]) {
        // Sorted, so the answer never depends on the order of the people.
        entries = people.filter(\.isLive).sorted { $0.id < $1.id }.map { p in
            let texts = p.forms.isEmpty ? [p.displayName] : p.forms.map(\.text)
            return Entry(person: p, names: texts.map(PersonNames.parse).filter(\.isName), keys: Set(texts.map(PersonNames.nameKey).filter { !$0.isEmpty }),
                         confirmedKeys: Set(p.forms.filter { $0.confirmed && ($0.kind == .alias || $0.kind == .nickname) }.map(\.key)))
        }
        index = Dictionary(entries.enumerated().map { ($1.person.id, $0) }, uniquingKeysWith: { a, _ in a })
    }

    public func person(_ id: PersonID) -> Person? { index[id].map { entries[$0].person } }

    /// The best relation of a written name to any form of a person. A conflict with one form blocks the others.
    private func fit(_ written: ParsedName, _ entry: Entry) -> NameFit {
        let all = entry.names.map { PersonNames.fit(written, $0) }
        if all.contains(.conflict) { return .conflict }
        return [NameFit.same, .sameWithMiddle, .nickname, .swapped, .short].first(where: all.contains) ?? .none
    }

    private static func one(_ hits: [Entry], rule: Resolution.Rule, confidence: Resolution.Confidence) -> Resolution? {
        switch hits.count {
        case 0: nil
        case 1: .resolved(hits[0].person.id, rule: rule, confidence: confidence)
        default: .ambiguous(hits.map(\.person.id), rule: rule)
        }
    }

    public func resolve(_ o: Observation, in context: ResolutionContext? = nil) -> Resolution {
        let written = o.name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let email = (o.email ?? PersonNames.email(in: written) ?? (written.contains("@") && !written.contains(" ") ? written : nil)).map(EmailIdentity.normalized)
        // Rule 0: what the owner rejected is obeyed by each rule.
        var open = entries
        if let email {
            open.removeAll { e in e.person.emails.contains { $0.address == email && $0.state == .rejected } }
        }
        if let identity = o.identity {
            open.removeAll { e in e.person.identities.contains { $0.isSame(identity) && $0.state == .rejected } }
        }
        // Rules 1 and 1b: the email beats the name.
        if let email, !email.isEmpty {
            func having(_ state: IdentityState) -> [Entry] {
                open.filter { e in e.person.emails.contains { $0.address == email && $0.state == state && !$0.shared } }
            }
            if let r = Self.one(having(.verified), rule: .verifiedEmail, confidence: .certain) { return r }
            if let r = Self.one(having(.seen), rule: .seenEmail, confidence: .strong) { return r }
        }
        // Rule 2.
        if let identity = o.identity,
           let r = Self.one(open.filter { e in e.person.identities.contains { $0.isSame(identity) } }, rule: .externalID, confidence: .certain) { return r }

        let name = PersonNames.parse(written)
        guard name.isName else { return .unknown }
        let key = PersonNames.nameKey(written), words = name.words
        if words.count >= 2 {
            // Rule 0: a form the owner gave for one person.
            if let r = Self.one(open.filter { $0.confirmedKeys.contains(key) }, rule: .ownerLink, confidence: .certain) { return r }
            // Rule 3a.
            if let r = Self.one(open.filter { $0.keys.contains(key) }, rule: .nameForm, confidence: .strong) { return r }
        }
        let fits = open.map { (entry: $0, fit: fit(name, $0)) }
        func having(_ wanted: NameFit...) -> [Entry] { fits.filter { wanted.contains($0.fit) }.map(\.entry) }
        if name.family != nil {
            // Rules 3b and 3c.
            if let r = Self.one(having(.same, .sameWithMiddle), rule: name.order == .none ? .sameName : .provedOrder, confidence: .strong) { return r }
            // Rule 3d: a link only when that person is known to be there.
            let swapped = having(.swapped)
            if swapped.count == 1 {
                let id = swapped[0].person.id
                if context?.roster.contains(id) == true { return .resolved(id, rule: .swappedName, confidence: .probable) }
                return .suggestion(id, rule: .swappedName, evidence: ["\"\(written)\" is \"\(swapped[0].person.displayName)\" in the other order."])
            }
            if swapped.count > 1 { return .ambiguous(swapped.map(\.person.id), rule: .swappedName) }
        }
        // Rules 4 and 4b: a short form, only among the people who are there.
        if let context {
            let roster = Set(context.roster)
            let there = fits.filter { roster.contains($0.entry.person.id) && ($0.fit == .nickname || $0.fit == .short) }
            var seen: Set<String> = [key]
            let others = context.otherNames.filter { other in
                guard seen.insert(PersonNames.key(other)).inserted else { return false }
                return [NameFit.same, .sameWithMiddle, .nickname, .short].contains(PersonNames.fit(name, PersonNames.parse(other)))
            }
            if there.count == 1, others.isEmpty {
                return .resolved(there[0].entry.person.id, rule: there[0].fit == .nickname ? .nickname : .shortName, confidence: .probable)
            }
            if there.count + others.count > 1 { return there.isEmpty ? .unknown : .ambiguous(there.map(\.entry.person.id), rule: .shortName) }
            // A person saved under one word, in a meeting where nobody else can be meant.
            if there.isEmpty, others.isEmpty, words.count == 1, let r = Self.one(open.filter { $0.keys.contains(key) }, rule: .shortName, confidence: .probable) { return r }
            if !others.isEmpty { return .unknown }
        }
        let nick = having(.nickname)
        if nick.count == 1 {
            return .suggestion(nick[0].person.id, rule: .nickname, evidence: ["\"\(written)\" can be a short form of \"\(nick[0].person.displayName)\"."])
        }
        if nick.count > 1 { return .ambiguous(nick.map(\.person.id), rule: .nickname) }
        // Rule 5: never a link.
        guard words.count >= 2 else { return .unknown }
        let near = fits.filter { $0.fit != .conflict && $0.entry.keys.contains { PeopleDuplicates.similar(key, $0) } }
        if near.count == 1 {
            return .suggestion(near[0].entry.person.id, rule: .similar, evidence: ["\"\(written)\" is almost \"\(near[0].entry.person.displayName)\"."])
        }
        return .unknown
    }

    /// Pairs of saved people who are probably one, for the owner to check. A pair the owner called different
    /// people does not come back.
    public func suggestions() -> [PersonSuggestion] {
        var out: [PersonSuggestion] = []
        for (i, a) in entries.enumerated() {
            for b in entries[(i + 1)...] where !a.person.distinctFrom.contains(b.person.id) && !b.person.distinctFrom.contains(a.person.id) {
                if let rule = Self.reason(a, b) { out.append(PersonSuggestion(first: a.person.id, second: b.person.id, rule: rule)) }
            }
        }
        return out
    }

    private static func reason(_ a: Entry, _ b: Entry) -> Resolution.Rule? {
        let mine = Set(a.person.emails.filter { $0.state == .verified && !$0.shared }.map(\.address))
        if b.person.emails.contains(where: { $0.state == .verified && !$0.shared && mine.contains($0.address) }) { return .verifiedEmail }
        if !a.keys.isDisjoint(with: b.keys) { return .nameForm }
        let fits = a.names.flatMap { x in b.names.map { PersonNames.fit(x, $0) } }
        guard !fits.contains(.conflict) else { return nil }
        if fits.contains(.same) || fits.contains(.sameWithMiddle) { return .sameName }
        if fits.contains(.swapped) { return .swappedName }
        if fits.contains(.nickname) { return .nickname }
        if a.keys.contains(where: { x in b.keys.contains { PeopleDuplicates.similar(x, $0) } }) { return .similar }
        return nil
    }
}
