import Foundation
import MossadCore

/// The People list's search: each saved voice by its name, its emails, its job title and team, its company, the
/// owner's note, and its other names. The job comes from the directory, else from the org chart.
@MainActor
enum PeopleSearch {
    static let prompt = "Search names, emails, titles, notes"

    /// The match of each profile that the query keeps, by name. With no words, nil: every row stays, unmarked.
    static func matches(_ query: String, profiles: [VoiceProfile], people: [Person], org: OrgState) -> [String: ListMatch]? {
        let search = ListSearch(query)
        guard !search.isEmpty else { return nil }
        var byName: [String: Person] = [:]
        for p in people where p.isLive { byName[p.displayName] = byName[p.displayName] ?? p }
        var out: [String: ListMatch] = [:]
        for profile in profiles {
            let person = byName[profile.name]
            if let m = search.match(title: profile.name, fields: fields(profile, person, org.match(profile.name)?.person)) {
                out[profile.name] = m
            }
        }
        return out
    }

    private static var peeked: (at: Date, people: [Person])?

    /// The saved people; until the store is attached at launch (and in a preview, which never attaches it), the
    /// file as it is, read at most every half minute.
    static func people(_ controller: AppController) -> [Person] {
        if let people = controller.library.identity?.people.people { return people }
        if let peeked, Date().timeIntervalSince(peeked.at) < 30 { return peeked.people }
        let people = PeopleStore.peek(in: controller.paths.people) ?? []
        peeked = (Date(), people)
        return people
    }

    /// Strongest first: a tie between two fields shows the earlier one.
    private static func fields(_ profile: VoiceProfile, _ person: Person?, _ chart: OrgChart.Person?) -> [ListField] {
        var emails = profile.emails
        for e in person?.emails ?? [] where e.state != .rejected && !emails.contains(where: { $0.caseInsensitiveCompare(e.address) == .orderedSame }) {
            emails.append(e.address)
        }
        var out = emails.map { ListField("Email", $0) }
        if let title = person?.directory?.jobTitle ?? chart?.title, !title.isEmpty { out.append(ListField("Job title", title)) }
        if let team = person?.directory?.department, !team.isEmpty { out.append(ListField("Team", team)) }
        if let company = person?.company, !company.isEmpty { out.append(ListField("Company", company)) }
        if let note = person?.note, !note.isEmpty { out.append(ListField("Note", note)) }
        let others = (person?.forms ?? []).map(\.text).filter { PersonNames.nameKey($0) != PersonNames.nameKey(profile.name) }
        out += others.map { ListField("Also", $0) }
        return out
    }
}
