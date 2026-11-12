import Foundation

/// How Google's directory and contacts fill the saved people. Pure: a copy of the people in, the changed people
/// and the log lines out.
///
/// - The key is the address: a profile fills a person only when one live person has that address (not rejected,
///   not a team address) and all of that person's addresses lead to one profile. Anything less is nobody.
/// - A name the owner typed is never replaced. Only a person still shown as an address, never named by anyone,
///   gets the directory's name as their name; for everyone else the directory's name is one more form, so it
///   resolves to them.
/// - The job title, the department, and the photo are the directory's own facts, so a new read replaces them. The
///   directory wins over the contacts for one address.
public enum DirectoryMerge {
    public struct Result: Equatable, Sendable {
        public var people: [Person]
        public var log: [PeopleLogEntry]
        /// The people who changed.
        public var changed: [PersonID]
    }

    /// The directory first, then the contacts, each in the order read.
    static func ordered(_ profiles: [GoogleProfile]) -> [GoogleProfile] {
        profiles.filter { $0.source == .directory } + profiles.filter { $0.source == .contacts }
    }

    /// One profile for each address: the directory's, with the contact's facts where the directory has none.
    static func byEmail(_ profiles: [GoogleProfile]) -> [String: GoogleProfile] {
        var out: [String: GoogleProfile] = [:]
        var twoInOneSource: Set<String> = []
        for p in ordered(profiles) {
            for e in p.emails {
                guard var known = out[e] else {
                    out[e] = p
                    continue
                }
                // Two profiles of one source with one address are two people that share it: nobody.
                if known.source == p.source, known != p { twoInOneSource.insert(e); continue }
                known.name = known.name ?? p.name
                known.jobTitle = known.jobTitle ?? p.jobTitle
                known.department = known.department ?? p.department
                known.photoURL = known.photoURL ?? p.photoURL
                out[e] = known
            }
        }
        for e in twoInOneSource { out[e] = nil }
        return out
    }

    public static func apply(_ profiles: [GoogleProfile], to people: [Person], at date: Date) -> Result {
        let index = byEmail(profiles)
        // Who holds each address, among the live people.
        var holders: [String: Set<PersonID>] = [:]
        for p in people where p.isLive {
            for e in p.emails where e.state != .rejected && !e.shared { holders[e.address, default: []].insert(p.id) }
        }
        var out = people, log: [PeopleLogEntry] = [], changed: [PersonID] = []
        for i in out.indices where out[i].isLive {
            let addresses = out[i].emails.filter { $0.state != .rejected && !$0.shared }.map(\.address)
            let found = addresses.compactMap { a in index[a].map { (a, $0) } }
            // Every address of this person leads to one profile, and nobody else has that address.
            guard let (address, profile) = found.first, found.allSatisfy({ $0.1 == profile }),
                  found.allSatisfy({ holders[$0.0] == [out[i].id] }) else { continue }
            let before = out[i]
            let source: SourceKind = profile.source == .directory ? .googleDirectory : .googleContacts
            if let name = profile.name, PersonNames.nameKey(name) != PersonNames.nameKey(out[i].displayName) {
                // Another live person with this name would make two of one name, and then neither resolves.
                let taken = out.contains { $0.id != out[i].id && $0.isLive && PersonNames.nameKey($0.displayName) == PersonNames.nameKey(name) }
                if canTakeName(out[i]), !taken {
                    setDisplay(&out[i], name, source: source, at: date)
                    log.append(PeopleLogEntry(at: date, kind: "rename", actor: "google", subject: out[i].id, before: before.displayName, after: name))
                } else {
                    out[i].addForm(name, kind: .seen, source: source, confirmed: false, at: date)
                }
            }
            let details = DirectoryDetails(jobTitle: profile.jobTitle, department: profile.department, photoURL: profile.photoURL, source: source, updated: date)
            let hasFacts = profile.jobTitle != nil || profile.department != nil || profile.photoURL != nil
            if hasFacts, !details.sameFacts(as: out[i].directory) {
                out[i].directory = details
                out[i].updated = date
                log.append(PeopleLogEntry(at: date, kind: "directory", actor: "google", subject: out[i].id, before: address,
                                          after: [profile.jobTitle, profile.department].compactMap { $0 }.joined(separator: ", ")))
            }
            if out[i] != before { changed.append(out[i].id) }
        }
        return Result(people: out, log: log, changed: changed)
    }

    /// Only a person still shown as their address, and not the owner: every other name came from a voice that the
    /// owner named, the owner's own typing, a calendar, or the org chart.
    static func canTakeName(_ p: Person) -> Bool {
        let shown = p.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !p.isOwner else { return false }
        if shown.isEmpty { return true }
        guard shown.contains("@"), !shown.contains(" ") else { return false }
        return !p.forms.contains { $0.kind == .display && ($0.source == .owner || $0.source == .voiceNaming || $0.confirmed && $0.source != .calendar) }
    }

    /// The new name as the display form, not confirmed: a source showed it, the owner did not type it. The address
    /// stays as a former form, so it continues to resolve.
    static func setDisplay(_ p: inout Person, _ name: String, source: SourceKind, at date: Date) {
        for i in p.forms.indices where p.forms[i].kind == .display { p.forms[i].kind = .former }
        if let i = p.forms.firstIndex(where: { $0.text == name }) {
            p.forms[i].kind = .display
            p.forms[i].lastSeen = date
        } else {
            p.forms.append(NameForm(text: name, kind: .display, source: source, confirmed: false, at: date))
        }
        p.displayName = name
        p.name = NameParts(PersonNames.parse(name))
        p.updated = date
    }

    /// The people without what the directory or the contacts gave (`sources`): after a sign-out, or with that part
    /// turned off. The names stay: a name is the person's now.
    public static func clear(_ sources: Set<GoogleProfile.Source>, from people: [Person], at date: Date) -> [Person] {
        people.map { p in
            guard let d = p.directory, sources.contains(d.source == .googleDirectory ? .directory : .contacts) else { return p }
            var p = p
            p.directory = nil
            p.updated = date
            return p
        }
    }

    /// "Name, Title" for the names that the org chart did not give, from the directory's job titles: the same lines
    /// that go to the AI provider with the org chart today. Only a name that one live person has.
    public static func contextLines(for names: [String], people: [Person], except given: [String]) -> [String] {
        let done = Set(given.compactMap { $0.split(separator: ",").first.map(String.init) })
        var seen: Set<String> = []
        return names.compactMap { name in
            guard !done.contains(name), seen.insert(name).inserted else { return nil }
            let hits = people.filter { $0.isLive && $0.displayName == name }
            guard hits.count == 1, let title = hits[0].directory?.jobTitle else { return nil }
            return "\(name), \(title)"
        }
    }

    /// The invitees with a name from the directory where the calendar gave only an address.
    public static func fillNames(_ invitees: [Invitee], names: [String: String]) -> [Invitee] {
        invitees.map { i in
            guard i.name == nil, let email = i.email, let name = names[email] else { return i }
            var i = i
            i.name = name
            return i
        }
    }
}
