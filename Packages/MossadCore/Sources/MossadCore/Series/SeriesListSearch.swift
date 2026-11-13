import Foundation

/// What the Recurring list's search reads of one series besides its meetings: the title, the cadence in words, and
/// its people by name and by address.
public struct SeriesSearchRow: Sendable, Equatable {
    public var id: String
    public var title: String
    /// Strongest first: the cadence, the names, the addresses.
    public var fields: [ListField]
    /// Every address, lowercased: a whole address in the search matches only these.
    public var emails: Set<String>
    /// Its meetings, newest first.
    public var meetings: [String]

    /// `records` may hold every meeting. `people` are the series' people on a sure match (`SeriesFilterRow.people`):
    /// only they bring the addresses of a saved person. The invites' own addresses count as they are.
    public init(series: MeetingSeries, records: [String: CallRecord], people: [MeetingFilter.Who], directory: PersonDirectory) {
        id = series.id
        title = series.title
        meetings = series.meetings.map(\.id)
        // The days and the group only, from the schedule that the list's groups use: the time and words such as
        // "every" would match nearly every series.
        var cadenceWords = series.schedule.weekdays.map { SeriesCadence.weekdays[$0 - 1] }
        if let group = SeriesFilter.Cadence(series.schedule), group != .other { cadenceWords.append(group.option) }
        if series.recurringInCalendar { cadenceWords.append("Repeats") }

        var names: [String] = [], nameKeys: Set<String> = []
        var emails: [String] = [], emailKeys: Set<String> = []
        func name(_ text: String) {
            let key = PersonNames.key(text)
            if !key.isEmpty, nameKeys.insert(key).inserted { names.append(text) }
        }
        func email(_ text: String) {
            let e = text.trimmingCharacters(in: .whitespaces).lowercased()
            if e.contains("@"), emailKeys.insert(e).inserted { emails.append(e) }
        }
        let recs = series.meetings.compactMap { records[$0.id] }
        for who in people { name(who.name) }
        for n in series.usualPeople { name(n) }
        for a in recs.flatMap(\.attendees) + series.upcoming.flatMap(\.attendees) {
            if a.contains("@") { email(a) } else { name(a) }
        }
        for i in recs.flatMap({ $0.invitees ?? [] }) {
            if let n = i.name { name(n) }
            if let e = i.email { email(e) }
        }
        // Every address of each sure person: the one saved person of that whole name. Two of one name are nobody.
        let saved = Dictionary(grouping: directory.people, by: \.name)
        for who in people {
            guard let found = saved[who.name], found.count == 1 else { continue }
            found[0].emails.forEach(email)
        }
        self.emails = emailKeys
        fields = [ListField("Cadence", cadenceWords.joined(separator: " · ")), ListField("People", names.joined(separator: ", ")),
                  ListField("Email", emails.joined(separator: ", "))]
    }
}

/// The search of the Recurring list. A series matches when its own words hold every word of the query, or when any
/// of its meetings matches the Meetings list's search (`SearchIndex.listMatches`). Its own words come first; else
/// the newest meeting that matches gives the place, with its time, so a click opens that meeting there.
public enum SeriesListSearch {
    public struct Match: Sendable, Equatable {
        public var match: ListMatch
        /// The meeting the place is in; nil when the series' own words matched.
        public var meetingID: String?

        public init(match: ListMatch, meetingID: String? = nil) {
            self.match = match
            self.meetingID = meetingID
        }
    }

    /// `meetings` are the Meetings search's places by meeting id, for the same query.
    ///
    /// A whole address matches only a series with that address, as the Meetings search reads one. A query with a
    /// `#tag` or an `@person` is about meetings: the series' own words do not count.
    public static func matches(_ rows: [SeriesSearchRow], query: String, meetings: [String: ListMatch]) -> [String: Match] {
        let parsed = ParsedQuery(query)
        let email = parsed.tag == nil && parsed.person.isEmpty ? parsed.email : nil
        let search = parsed.tag == nil && parsed.person.isEmpty && email == nil ? ListSearch(query) : ListSearch("")
        var out: [String: Match] = [:]
        for row in rows {
            if let email, row.emails.contains(email) {
                out[row.id] = Match(match: ListMatch(title: SearchText(row.title), source: .field("Email"),
                                                     context: SearchText(email, matches: [email.startIndex..<email.endIndex])))
            } else if !search.isEmpty, let own = search.match(title: row.title, fields: row.fields) {
                out[row.id] = Match(match: own)
            } else if let id = row.meetings.first(where: { meetings[$0] != nil }), let m = meetings[id] {
                out[row.id] = Match(match: place(m, seriesTitle: row.title), meetingID: id)
            }
        }
        return out
    }

    /// A meeting found by its own title, which is not the series' title now, says which title it was.
    static func place(_ m: ListMatch, seriesTitle: String) -> ListMatch {
        guard m.source == .title, m.title.text.caseInsensitiveCompare(seriesTitle) != .orderedSame else { return m }
        return ListMatch(title: SearchText(seriesTitle), source: .field("Meeting"), context: m.title, time: m.time)
    }
}
