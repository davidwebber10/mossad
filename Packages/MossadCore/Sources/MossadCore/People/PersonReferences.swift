import Foundation

/// The references to people in records and commitments: an id of `people.json` next to the name, which stays as
/// a label. Pure: built from a copy of the people, with no file and no clock.
///
/// `refresh` is the one step for three jobs. It is the migration (it gives ids to old records), the repair (it
/// finds the ids again that an older build dropped when it saved), and "refresh labels" (after a rename or a
/// merge, a label becomes the person's name of now). It writes an id only on a sure match, and it compares before
/// it changes anything, so it can run again at any time, also after a stop in the middle.
public struct PersonReferences: Sendable {
    /// The rules that say who a name is: an address, the id of a source, a written form of the person, or the whole
    /// name in either order with proof. Never a short name, a nickname, or a name that is almost right.
    static let sure: Set<Resolution.Rule> = [.ownerLink, .verifiedEmail, .seenEmail, .companyEmail, .externalID, .nameForm, .provedOrder, .sameName]
    /// Inside the people of one call, a short name or a nickname is sure too when one person there fits it.
    static let inCall: Set<Resolution.Rule> = sure.union([.swappedName, .nickname, .shortName])

    private let all: [String: Person]
    /// Live people by display name.
    private let byDisplay: [String: [Person]]
    /// Live people by the key of a former name: a name they had before a rename.
    private let byFormer: [String: [PersonID]]
    /// The resolver with no former names: a name a person had before can be another person's name now.
    private let resolver: PersonResolver
    /// With every name, for "does this label still fit the person of its id".
    private let everyName: PersonResolver
    private let owner: Person?
    /// The owner's names, without one that is another live person's display name.
    private let ownerKeys: Set<String>

    public init(people: [Person]) {
        all = Dictionary(people.map { ($0.id.rawValue, $0) }, uniquingKeysWith: { a, _ in a })
        let live = people.filter(\.isLive)
        byDisplay = Dictionary(grouping: live, by: \.displayName)
        var former: [String: [PersonID]] = [:]
        for p in live {
            for key in Set(p.forms.filter { $0.kind == .former }.map(\.key)) where !key.isEmpty { former[key, default: []].append(p.id) }
        }
        byFormer = former
        resolver = PersonResolver(people: people.map { p in
            var p = p
            p.forms.removeAll { $0.kind == .former }
            return p
        })
        everyName = PersonResolver(people: people)
        let owner = live.first(where: \.isOwner)
        self.owner = owner
        let others = Set(live.filter { !$0.isOwner }.map { PersonNames.key($0.displayName) })
        ownerKeys = Set((owner?.forms.map(\.text) ?? []).map(PersonNames.key).filter { !$0.isEmpty && !others.contains($0) })
    }

    public var isEmpty: Bool { all.isEmpty }

    /// An id of a person in this store, also one that another record took in.
    public func knows(_ id: String) -> Bool { all[id] != nil }

    /// The person an id stands for now: a merged record points to the one that took it in.
    public func canonical(_ id: String) -> String {
        var current = id
        var seen: Set<String> = [id]
        while let next = all[current]?.mergedInto?.rawValue, seen.insert(next).inserted { current = next }
        return current
    }

    /// The live person an id stands for now. Nil for an unknown id and for a deleted person.
    public func person(_ id: String) -> Person? {
        all[canonical(id)].flatMap { $0.isLive ? $0 : nil }
    }

    /// The display name of the person an id stands for now.
    public func name(of id: String) -> String? { person(id)?.displayName.nonBlank }

    // MARK: Who a label is

    private static func isLabel(_ text: String) -> Bool { text.hasPrefix("Speaker ") }

    /// The saved person a label surely is, alone or among the people of a call. `former`: a name a person had before
    /// a rename counts, when no live person has it now. Only for speakers: the voice library wrote those labels, and
    /// a stop during a rename can leave the old one.
    func resolve(_ label: String, email: String? = nil, in context: ResolutionContext? = nil, former: Bool = false) -> String? {
        let label = label.trimmingCharacters(in: .whitespacesAndNewlines)
        if email == nil {
            guard !label.isEmpty, !Self.isLabel(label) else { return nil }
            // The name a person has now comes first. Two live people with one name: nobody.
            if let same = byDisplay[label] { return same.count == 1 ? same[0].id.rawValue : nil }
            if let owner, ownerKeys.contains(PersonNames.key(label)) { return owner.id.rawValue }
        }
        let answer = resolver.resolve(PersonObservation(name: label.nonBlank, email: email), in: context)
        if case .resolved(let id, let rule, _) = answer, (context == nil ? Self.sure : Self.inCall).contains(rule) { return id.rawValue }
        if case .ambiguous = answer { return nil }
        guard former, email == nil, answer == .unknown || answer.rule == .similar else { return nil }
        let key = PersonNames.nameKey(label)
        guard let ids = byFormer[key], ids.count == 1, !byDisplay.values.joined().contains(where: { PersonNames.nameKey($0.displayName) == key }) else { return nil }
        return ids[0].rawValue
    }

    /// The saved person a name or an id that someone typed is, on a sure match: an id of the store, the name of
    /// now, a whole name in another written form, an address, or a name the person had before a rename.
    public func id(for query: String) -> String? {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if knows(query) { return person(query)?.id.rawValue }
        if query.contains("@"), !query.contains(" ") { return resolve("", email: query) }
        return resolve(query, former: true)
    }

    /// The ids of the people of a record: the voices and the invited people, as the record has them now.
    public static func ids(in r: CallRecord) -> Set<String> {
        Set((r.speakerPeople ?? [:]).values).union((r.invitees ?? []).compactMap(\.personID))
    }

    /// Whether a label (or an address) still fits the person an id stands for: one of the person's names, the name
    /// of the record that was taken in, or a name that resolves to that person.
    private func fits(_ label: String?, email: String? = nil, id: String, in context: ResolutionContext?, former: Bool) -> Bool {
        guard let person = person(id) else { return false }
        if let email = email.map(EmailIdentity.normalized), person.emails.contains(where: { $0.address == email && $0.state != .rejected }) { return true }
        guard let label = label?.nonBlank, !Self.isLabel(label) else { return false }
        // The name another live person has now is that person.
        if let same = byDisplay[label], !same.contains(where: { $0.id == person.id }) { return false }
        let key = PersonNames.nameKey(label)
        if key == PersonNames.nameKey(person.displayName) || renamedKeys(id).contains(key) { return true }
        if person.isOwner, ownerKeys.contains(PersonNames.key(label)) { return true }
        if resolve(label, in: context, former: former) == person.id.rawValue { return true }
        // A name the person had before, in another written form ("Carter, Sam" after a rename of Sam Carter).
        if case .resolved(let hit, let rule, _) = everyName.resolve(PersonObservation(name: label), in: context),
           (context == nil ? Self.sure : Self.inCall).contains(rule), canonical(hit.rawValue) == person.id.rawValue { return true }
        return false
    }

    /// The names that a rename or a merge took from the person of this id: its former names, and the names of the
    /// record that was taken in. A label with one of them becomes the name of now.
    private func renamedKeys(_ id: String) -> Set<String> {
        var keys: Set<String> = []
        let now = canonical(id)
        for ref in Set([id, now] + (all[now]?.mergedFrom.map(\.rawValue) ?? [])) {
            guard let p = all[ref] else { continue }
            keys.formUnion(p.forms.filter { $0.kind == .former }.map(\.key))
            if ref != now { keys.insert(PersonNames.nameKey(p.displayName)) }
        }
        // A name that another live person has now is that person's.
        let taken = Set(byDisplay.keys.map(PersonNames.nameKey)).subtracting([PersonNames.nameKey(all[now]?.displayName ?? "")])
        return keys.subtracting(taken).filter { !$0.isEmpty }
    }

    /// The id a reference keeps: its own when the label still fits that person, else the one the label surely is.
    /// An id of a merged record becomes the id of the record that took it in.
    private func reference(_ id: String?, label: String?, email: String? = nil, in context: ResolutionContext?, former: Bool) -> String? {
        if let id, fits(label, email: email, id: id, in: context, former: former) { return canonical(id) }
        if let email, let hit = resolve("", email: email) { return hit }
        // A name a person had before counts only for a reference that has that person's id already: a new label
        // with an old name can be another person, and the owner's correction must stay.
        return label.flatMap { resolve($0, in: context) }
    }

    /// The label after a rename or a merge: the person's name of now, where the label is a name the person had. A
    /// short name ("Sam") and another written form stay as they are.
    private func label(_ label: String, id: String?, was old: String? = nil) -> String {
        guard let id, let person = person(id), let now = person.displayName.nonBlank, label != now,
              // A name of now that another live person has too would make two people one label.
              byDisplay[now]?.count == 1 else { return label }
        let key = PersonNames.nameKey(label)
        guard key != PersonNames.nameKey(now), renamedKeys(id).union(old.map(renamedKeys) ?? []).contains(key) else { return label }
        return now
    }

    // MARK: Records

    /// The people of a call, as the resolver wants them: who spoke and who was invited, with the ids they have.
    public func context(of r: CallRecord) -> ResolutionContext {
        var context = ResolutionContext()
        for (key, name) in r.speakerNames.sorted(by: { $0.key < $1.key }) {
            if let id = r.speakerPeople?[key].map(canonical), person(id) != nil {
                if !context.roster.contains(PersonID(rawValue: id)) { context.roster.append(PersonID(rawValue: id)) }
            } else if !Self.isLabel(name), !name.contains("@") {
                context.otherNames.append(name)
            }
        }
        for i in r.invitees ?? [] {
            if let id = i.personID.map(canonical), person(id) != nil {
                if !context.roster.contains(PersonID(rawValue: id)) { context.roster.append(PersonID(rawValue: id)) }
            } else if let name = i.name?.nonBlank {
                context.otherNames.append(PersonNames.plain(name))
            }
        }
        // A record with no pairs: each invited name by itself.
        if r.invitees == nil {
            for text in r.attendees {
                let o = PersonObservation(text: text)
                // An address, alone or next to a name, says who it is; a bare address is no other name of the call.
                if let email = o.email, let id = resolve("", email: email) {
                    if !context.roster.contains(PersonID(rawValue: id)) { context.roster.append(PersonID(rawValue: id)) }
                    continue
                }
                guard !text.contains("@") else { continue }
                if let id = resolve(text) {
                    if !context.roster.contains(PersonID(rawValue: id)) { context.roster.append(PersonID(rawValue: id)) }
                } else {
                    context.otherNames.append(text)
                }
            }
        }
        return context
    }

    /// The record with the ids of its people filled and its labels current. `relabel: false` only fills ids: for a
    /// save that does not write the note again.
    public func refresh(_ r: CallRecord, relabel: Bool = true) -> CallRecord {
        guard !isEmpty else { return r }
        var r = r
        // Speakers: each named voice, alone. The voice library wrote these labels.
        var speakers: [String: String] = [:]
        for (key, name) in r.speakerNames {
            guard let id = reference(r.speakerPeople?[key], label: name, in: nil, former: true) else { continue }
            speakers[key] = id
            if relabel { r.speakerNames[key] = label(name, id: id, was: r.speakerPeople?[key]) }
        }
        let speakerPeople = speakers.isEmpty ? nil : speakers
        if r.speakerPeople != speakerPeople, !(r.speakerPeople?.isEmpty == true && speakerPeople == nil) { r.speakerPeople = speakerPeople }

        // Invited people: the address first, then the name, among the voices of the call.
        if let invitees = r.invitees {
            let voices = ResolutionContext(roster: Array(Set(speakers.values)).sorted().map(PersonID.init(rawValue:)),
                                           otherNames: r.speakerNames.filter { speakers[$0.key] == nil && !Self.isLabel($0.value) }.map(\.value).sorted())
            r.invitees = invitees.map { i in
                var i = i
                let name = i.name.map(PersonNames.plain)
                i.personID = reference(i.personID, label: name, email: i.email, in: name == nil ? nil : voices, former: false)
                return i
            }
        }

        // Action items: inside the people of this call only.
        let context = context(of: r)
        r.actionItems = r.actionItems.map { item in
            var item = item
            guard let owner = item.owner?.nonBlank else {
                item.ownerID = nil
                return item
            }
            let old = item.ownerID
            item.ownerID = reference(old, label: owner, in: context, former: false)
            if relabel { item.owner = label(owner, id: item.ownerID, was: old) }
            return item
        }
        return r
    }

    /// A commitment with the id of the person it was promised to. Inside the people of its call; one made by hand,
    /// or one whose call is gone, only on a sure match of the whole name.
    public func refresh(_ c: Commitment, call: CallRecord?) -> Commitment {
        guard !isEmpty else { return c }
        var c = c
        guard let to = c.to?.nonBlank else {
            c.toID = nil
            return c
        }
        let old = c.toID
        c.toID = reference(old, label: to, in: call.map(context(of:)), former: false)
        c.to = label(to, id: c.toID, was: old)
        return c
    }

    /// The book with each commitment refreshed. The time of the last change stays: an id is not a change of the
    /// owner's, so a copy on another device that the owner did change still wins.
    public func refresh(_ book: CommitmentBook, records: [CallRecord]) -> CommitmentBook {
        guard !isEmpty else { return book }
        let calls = Dictionary(records.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var book = book
        book.items = book.items.map { c in c.deleted ? c : refresh(c, call: c.callID.flatMap { calls[$0] }) }
        return book
    }

    // MARK: Checks

    /// The record with each reference taken away: no ids. For the check that a refresh changed nothing else, and
    /// for `revert`.
    public static func withoutIDs(_ r: CallRecord) -> CallRecord {
        var r = r
        r.speakerPeople = nil
        r.invitees = r.invitees?.map { var i = $0; i.personID = nil; return i }
        r.actionItems = r.actionItems.map { var a = $0; a.ownerID = nil; return a }
        return r
    }

    /// Whether `after` differs from `before` only in what a refresh may change: the ids, and a label that became the
    /// name of now of the person its id stands for.
    public func changesOnlyReferences(from before: CallRecord, to after: CallRecord) -> Bool {
        var a = Self.withoutIDs(before), b = Self.withoutIDs(after)
        guard a.speakerNames.keys.sorted() == b.speakerNames.keys.sorted(), a.actionItems.count == b.actionItems.count else { return false }
        for (key, name) in b.speakerNames where name != a.speakerNames[key] {
            guard let id = after.speakerPeople?[key], name == self.name(of: id) else { return false }
            a.speakerNames[key] = name
        }
        for i in b.actionItems.indices where b.actionItems[i].owner != a.actionItems[i].owner {
            guard let id = after.actionItems[i].ownerID, b.actionItems[i].owner == name(of: id) else { return false }
            a.actionItems[i].owner = b.actionItems[i].owner
        }
        return a == b
    }
}
