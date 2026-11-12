import Foundation

/// The series a filter leaves, and the choices of each group with their counts, from one pass over the rows, by
/// the rules of `MeetingFacets`. The search text comes in as `within`: the series it matches. Pure; make it off the
/// main thread.
public struct SeriesFacets: Sendable, Equatable {
    /// The series looked at: every one, or the ones the search text matches.
    public var total = 0
    /// The series that match the filter and the search text.
    public var matches: Set<String> = []
    /// The series that match the filter, whatever the search text.
    public var filterMatches: Set<String> = []
    /// Everyone in the series looked at, the one in the most series first.
    public var people: [MeetingFacets.Person] = []
    public var cadences = MeetingTally<SeriesFilter.Cadence>()
    public var next = MeetingTally<SeriesFilter.Next>()
    public var lastMet = MeetingTally<SeriesFilter.LastMet>()
    public var lengths = MeetingTally<MeetingFilter.Length>()
    public var sizes = MeetingTally<MeetingFilter.Size>()
    public var values = MeetingTally<MeetingFilter.Value>()
    public var platforms = MeetingTally<Platform>()
    /// Under `true`: the series with open items.
    public var openItems = MeetingTally<Bool>()

    public init() {}

    private struct Group: OptionSet {
        let rawValue: UInt16
        static let people = Group(rawValue: 1 << 0), cadence = Group(rawValue: 1 << 1), next = Group(rawValue: 1 << 2)
        static let lastMet = Group(rawValue: 1 << 3), length = Group(rawValue: 1 << 4), size = Group(rawValue: 1 << 5)
        static let value = Group(rawValue: 1 << 6), platform = Group(rawValue: 1 << 7), openItems = Group(rawValue: 1 << 8)
    }

    public init(rows: [SeriesFilterRow], filter: SeriesFilter, within: Set<String>? = nil, now: Date = Date(), calendar: Calendar = .current) {
        let chosenPeople = Set(filter.people.map(\.key))
        var people: [String: (who: MeetingFilter.Who, count: Int, overall: Int)] = [:]
        // The date rules once, not for each row.
        let nextDays = Dictionary(uniqueKeysWithValues: SeriesFilter.Next.allCases.map { ($0, $0.rule(now: now, calendar: calendar)) })
        let lastDays = Dictionary(uniqueKeysWithValues: SeriesFilter.LastMet.allCases.map { ($0, $0.rule(now: now, calendar: calendar)) })

        for row in rows {
            // What this series has, group by group. An unknown value gives no choice.
            let rowPeople = Set(row.people.map(\.key))
            let length = row.seconds.flatMap { s in MeetingFilter.Length.allCases.first { $0.contains(seconds: s) } }
            let nexts = SeriesFilter.Next.allCases.filter { nextDays[$0]?.contains(row.next) ?? false }
            let lasts = row.last.map { d in SeriesFilter.LastMet.allCases.filter { lastDays[$0]?.contains(d) ?? false } } ?? []

            var failed: Group = []
            if !chosenPeople.isEmpty {
                let ok = filter.peopleMode == .all ? chosenPeople.isSubset(of: rowPeople) : !chosenPeople.isDisjoint(with: rowPeople)
                if !ok { failed.insert(.people) }
            }
            if !filter.cadences.isEmpty, !(row.cadence.map(filter.cadences.contains) ?? false) { failed.insert(.cadence) }
            if let n = filter.next, !nexts.contains(n) { failed.insert(.next) }
            if let l = filter.lastMet, !lasts.contains(l) { failed.insert(.lastMet) }
            if !filter.lengths.isEmpty, !(length.map(filter.lengths.contains) ?? false) { failed.insert(.length) }
            if !filter.sizes.isEmpty, !filter.sizes.contains(row.size) { failed.insert(.size) }
            if !filter.values.isEmpty, !filter.values.contains(row.value) { failed.insert(.value) }
            if !filter.platforms.isEmpty, !(row.platform.map(filter.platforms.contains) ?? false) { failed.insert(.platform) }
            if filter.openItems, row.openItems != true { failed.insert(.openItems) }

            if failed.isEmpty { filterMatches.insert(row.id) }
            guard within?.contains(row.id) ?? true else { continue }
            total += 1
            if failed.isEmpty { matches.insert(row.id) }
            func counts(_ group: Group) -> Bool { failed.isEmpty || failed == group }

            let countsPeople = filter.peopleMode == .all ? failed.isEmpty : counts(.people)
            for who in row.people {
                var entry = people[who.key] ?? (who, 0, 0)
                entry.overall += 1
                if countsPeople { entry.count += 1 }
                people[who.key] = entry
            }
            if let c = row.cadence { cadences.add(c, counted: counts(.cadence)) }
            for n in nexts { next.add(n, counted: counts(.next)) }
            for l in lasts { lastMet.add(l, counted: counts(.lastMet)) }
            if let length { lengths.add(length, counted: counts(.length)) }
            sizes.add(row.size, counted: counts(.size))
            values.add(row.value, counted: counts(.value))
            if let p = row.platform { platforms.add(p, counted: counts(.platform)) }
            if row.openItems == true { openItems.add(true, counted: counts(.openItems)) }
        }

        // A chosen person stays in the list when no series looked at has them.
        for who in filter.people where people[who.key] == nil { people[who.key] = (who, 0, 0) }
        self.people = people.values
            .sorted { $0.overall != $1.overall ? $0.overall > $1.overall : $0.who.name.localizedStandardCompare($1.who.name) == .orderedAscending }
            .map { MeetingFacets.Person(who: $0.who, count: $0.count) }
    }

    /// Equal, and each person under the same name (see `MeetingFilterRow.same`).
    public func isSame(as other: SeriesFacets) -> Bool { self == other && people.map(\.who.name) == other.people.map(\.who.name) }
}
