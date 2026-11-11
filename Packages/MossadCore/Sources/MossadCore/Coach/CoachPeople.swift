import Foundation

/// The saved people as the coach reads them: which person a name in a call is, on a sure match only. What the
/// coach learns about a person is kept with that person's id (`PersonID` in `people.json`), so it stays with
/// the person through a new name, a name written the other way, and a merge of two records. A name that is not
/// one saved person is no person here: unknown is not a guess.
public struct CoachPeople: Sendable {
    /// No people store: no name gets an id, and the coach's memory is read by the name, as before the ids.
    public static let none = CoachPeople(people: [])

    /// The rules of `PersonResolver` that say who a name is: an address, the id of a source, a written form of
    /// the person, or the whole name in either order. A short name, a nickname, and a name that is almost
    /// right only suggest, and make no link.
    static let sure: Set<Resolution.Rule> = [.ownerLink, .verifiedEmail, .seenEmail, .externalID, .nameForm, .provedOrder, .sameName]

    private let resolver: PersonResolver
    private let all: [PersonID: Person]
    private let byName: [String: [Person]]

    public init(people: [Person]) {
        resolver = PersonResolver(people: people)
        all = Dictionary(people.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        byName = Dictionary(grouping: people.filter(\.isLive), by: \.displayName)
    }

    /// The people on disk. It only reads: with no file, or a file that does not decode, there are no people.
    public static func read(paths: Paths) -> CoachPeople { CoachPeople(people: PeopleStore.peek(in: paths.people) ?? []) }

    public var isEmpty: Bool { all.isEmpty }

    /// The person an id stands for now: a merged record points to the one that took it in.
    public func canonical(_ id: String) -> String {
        var current = PersonID(rawValue: id)
        var seen: Set<PersonID> = [current]
        while let next = all[current]?.mergedInto, seen.insert(next).inserted { current = next }
        return current.rawValue
    }

    /// The name of a person now. Nil for an id that is no live person here.
    public func name(of id: String) -> String? {
        all[PersonID(rawValue: canonical(id))].flatMap { $0.isLive ? $0.displayName.nonBlank : nil }
    }

    /// The saved person a name is, on a sure match. Nil for the owner (the coach's memory of the owner is the
    /// profile itself), for a label such as "Speaker B", and when no person or more than one fits.
    public func id(of name: String, email: String? = nil) -> String? {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !name.hasPrefix("Speaker ") else { return nil }
        func other(_ p: Person?) -> String? { p.flatMap { $0.isOwner || !$0.isLive ? nil : $0.id.rawValue } }
        // The name a person has now comes before a name that another person had before.
        if email == nil, let same = byName[name] { return same.count == 1 ? other(same[0]) : nil }
        guard case .resolved(let id, let rule, let confidence) = resolver.resolve(PersonObservation(name: name, email: email)),
              Self.sure.contains(rule), confidence >= .strong else { return nil }
        return other(all[id])
    }

    /// The names of the people of a call: who spoke, and who was invited, with the invite's address.
    private func names(in r: CallRecord) -> [(name: String, email: String?)] {
        var out: [(String, String?)] = r.speakerNames.sorted { $0.key < $1.key }.map { ($0.value, nil) }
        for i in r.invitees ?? [] { if let name = i.name?.nonBlank { out.append((PersonNames.plain(name), i.email)) } }
        return out
    }

    /// The one saved person a conclusion of the coach is about. `about` is the name the model gave: it counts
    /// only as the whole name of someone in the call. With none, the claim itself must hold the whole name of
    /// exactly one person of the call. A first name alone is a guess, and gives nobody.
    public func subject(of statement: String, about: String?, in r: CallRecord) -> (id: String, name: String)? {
        let people = names(in: r)
        var hits: [(name: String, email: String?)] = []
        if let about = about?.nonBlank {
            let key = PersonNames.nameKey(about)
            hits = people.filter { PersonNames.nameKey($0.name) == key }
        } else {
            let plain = " " + AdviceRules.key(statement) + " "
            hits = people.filter { p in
                let words = AdviceRules.key(p.name)
                return words.split(separator: " ").count >= 2 && plain.contains(" \(words) ")
            }
        }
        let ids = Set(hits.compactMap { id(of: $0.name, email: $0.email) })
        guard ids.count == 1, let id = ids.first, let name = name(of: id) else { return nil }
        return (id, name)
    }

    /// The one saved person whose whole name a text holds, among all saved people. For a fact that the owner
    /// typed ("Sam Carter is my direct report"). Two names in the text are about no one person.
    func onlyPerson(namedIn text: String) -> String? {
        let plain = " " + AdviceRules.key(text) + " "
        let hits = Set(byName.keys.filter { name in
            let words = AdviceRules.key(name)
            return words.split(separator: " ").count >= 2 && plain.contains(" \(words) ")
        }.compactMap { id(of: $0) })
        return hits.count == 1 ? hits.first : nil
    }
}

extension CoachProfile {
    /// The coach's note on a person: by the person's id when the memory has it, under whatever name it was
    /// written, else by the name.
    public func note(on name: String, people: CoachPeople = .none) -> (key: String, value: CoachPerson)? {
        if let id = people.id(of: name),
           let hit = self.people.filter({ $0.value.person.map(people.canonical) == id }).max(by: { ($0.value.lastSeen, $0.key) < ($1.value.lastSeen, $1.key) }) {
            return (hit.key, hit.value)
        }
        return self.people[name].map { (name, $0) }
    }

    /// What the owner confirmed about a person, by the person's id.
    public func learnings(about id: String, people: CoachPeople = .none) -> [CoachFact] {
        let id = people.canonical(id)
        return facts.filter { $0.person.map(people.canonical) == id }
    }

    /// What the owner told the coach about its cards on a person, by the person's id.
    public func guidance(about id: String, people: CoachPeople = .none) -> [CoachGuidance] {
        let id = people.canonical(id)
        return guidance.filter { $0.person.map(people.canonical) == id }
    }

    /// Saves the coach's read on a person with that person: under the name of now, with the note and the calls
    /// an earlier name had.
    public mutating func setBrief(_ brief: PersonBrief, for name: String, people saved: CoachPeople = .none) {
        let id = saved.id(of: name)
        var person = self.people[name] ?? CoachPerson(note: "", calls: 0, lastSeen: brief.updated)
        if let old = note(on: name, people: saved), old.key != name {
            self.people[old.key] = nil
            if self.people[name] == nil { person = old.value }
        }
        person.brief = brief
        person.person = id ?? person.person
        self.people[name] = person
    }

    /// Gives the coach's notes on people, its conclusions, and the facts the id of their person, where the name
    /// is one saved person on a sure match. The rest stays as it is, untouched. An id of a record that another
    /// one took in becomes that one's id, and two notes of one person become one: the newer words, the calls of
    /// both. A note with an id has the person's name of now as its label, so a device with no people store
    /// still finds it by the name. Running it again changes nothing. Returns how many entries it changed.
    @discardableResult
    public mutating func linkPeople(_ saved: CoachPeople, records: [CallRecord]) -> Int {
        guard !saved.isEmpty else { return 0 }
        var changed = 0
        let calls = Dictionary(records.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })

        // The notes on people.
        var notes: [String: CoachPerson] = [:]
        for (key, note) in people.sorted(by: { ($0.value.lastSeen, $0.key) < ($1.value.lastSeen, $1.key) }) {
            let id = note.person.map(saved.canonical) ?? saved.id(of: key)
            guard let id, let name = saved.name(of: id) else { notes[key] = note; continue }
            var note = note
            note.person = id
            if var old = notes[name], old.person == id {
                // The same person under two names: the newer words (this one, by the order), the calls of both.
                old.calls += note.calls
                old.lastSeen = max(old.lastSeen, note.lastSeen)
                if let words = note.note.nonBlank { old.note = words }
                if let brief = note.brief, (old.brief?.updated ?? .distantPast) <= brief.updated { old.brief = brief }
                notes[name] = old
            } else if notes[name] == nil {
                notes[name] = note
            } else {
                // Another entry holds that name and is not this person: this note keeps its own label.
                notes[key] = note
            }
        }
        if notes != people {
            changed += Set(people.keys).symmetricDifference(notes.keys).count / 2 + people.filter { notes[$0.key] != nil && notes[$0.key] != $0.value }.count
            people = notes
        }

        // The conclusions: who each is about, from the people of its call.
        for i in questions.indices {
            let before = questions[i]
            if let id = before.person {
                questions[i].person = saved.canonical(id)
            } else if let call = before.callID.flatMap({ calls[$0] }), let subject = saved.subject(of: before.statement, about: before.about, in: call) {
                questions[i].person = subject.id
                questions[i].personName = subject.name
            }
            if questions[i] != before { changed += 1 }
        }

        // The facts: a confirmed conclusion's person, or the one saved person whose whole name the fact holds.
        for i in facts.indices {
            let before = facts[i]
            if let id = before.person {
                facts[i].person = saved.canonical(id)
            } else if before.kind != .role, before.kind != .goal, before.kind != .responsibility {
                let asked = questions.first { q in
                    (q.status == .confirmed && q.statement.caseInsensitiveCompare(before.text) == .orderedSame)
                        || (q.status == .corrected && q.note?.caseInsensitiveCompare(before.text) == .orderedSame)
                }
                facts[i].person = asked.map(\.person) ?? saved.onlyPerson(namedIn: before.text)
            }
            if facts[i] != before { changed += 1 }
        }
        for i in guidance.indices {
            guard let id = guidance[i].person, saved.canonical(id) != id else { continue }
            guidance[i].person = saved.canonical(id)
            changed += 1
        }
        return changed
    }
}
