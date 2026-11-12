import Foundation

/// How many meetings each choice of one group has.
public struct MeetingTally<Key: Hashable & Sendable>: Sendable, Equatable {
    var counts: [Key: Int] = [:]
    var overall: [Key: Int] = [:]

    /// The meetings with this choice that the other groups' choices leave: what the list shows with it chosen
    /// (alone in its group, or added to the group's other choices).
    public func count(_ key: Key) -> Int { counts[key, default: 0] }
    /// Whether any meeting has this choice at all, so a choice of no meeting is not offered.
    public func exists(_ key: Key) -> Bool { overall[key, default: 0] > 0 }
}

/// The meetings a filter leaves, and the choices of each group with their counts, from one pass over the rows.
/// The search text comes in as `within`: the meetings the text matches. Pure; make it off the main thread.
public struct MeetingFacets: Sendable, Equatable {
    public struct Person: Sendable, Equatable, Identifiable {
        public var who: MeetingFilter.Who
        public var count: Int
        public var id: String { who.key }
    }

    public struct Named: Sendable, Equatable, Identifiable {
        public var name: String
        public var count: Int
        public var id: String { name.lowercased() }
    }

    /// The meetings looked at: every one, or the ones the search text matches.
    public var total = 0
    /// The meetings that match the filter and the search text.
    public var matches: Set<String> = []
    /// The meetings that match the filter, whatever the search text. The list meets these with the newest search
    /// text, so a wider text never shows the older, narrower set while the count runs.
    public var filterMatches: Set<String> = []
    /// Everyone in the meetings looked at, the one in the most meetings first. The order does not change with
    /// the filter, so a row stays where it is while the owner chooses.
    public var people: [Person] = []
    public var tags: [Named] = []
    public var kinds: [Named] = []
    public var lengths = MeetingTally<MeetingFilter.Length>()
    public var periods = MeetingTally<MeetingFilter.Period>()
    public var weekdays = MeetingTally<Int>()
    public var sizes = MeetingTally<MeetingFilter.Size>()
    public var values = MeetingTally<MeetingFilter.Value>()
    public var platforms = MeetingTally<Platform>()
    public var flags = MeetingTally<MeetingFilter.Flag>()

    public init() {}

    private struct Group: OptionSet {
        let rawValue: UInt16
        static let people = Group(rawValue: 1 << 0), length = Group(rawValue: 1 << 1), period = Group(rawValue: 1 << 2)
        static let weekday = Group(rawValue: 1 << 3), tags = Group(rawValue: 1 << 4), kinds = Group(rawValue: 1 << 5)
        static let size = Group(rawValue: 1 << 6), value = Group(rawValue: 1 << 7), platform = Group(rawValue: 1 << 8)
        static let actionItems = Group(rawValue: 1 << 9), decisions = Group(rawValue: 1 << 10), screens = Group(rawValue: 1 << 11)

        static func flag(_ f: MeetingFilter.Flag) -> Group {
            switch f {
            case .actionItems: .actionItems
            case .decisions: .decisions
            case .screens: .screens
            }
        }
    }

    public init(rows: [MeetingFilterRow], filter: MeetingFilter, within: Set<String>? = nil, now: Date = Date(), calendar: Calendar = .current) {
        let chosenPeople = Set(filter.people.map(\.key))
        let chosenTags = Set(filter.tags.map { $0.lowercased() }), chosenKinds = Set(filter.kinds.map { $0.lowercased() })
        let presets = MeetingFilter.Period.presets.map { ($0, $0.interval(now: now, calendar: calendar)) }
        let chosenPeriod = filter.period?.interval(now: now, calendar: calendar)
        func inside(_ date: Date, _ i: DateInterval) -> Bool { date >= i.start && date < i.end }

        var people: [String: (who: MeetingFilter.Who, count: Int, overall: Int)] = [:]
        var tags: [String: (name: String, count: Int, overall: Int)] = [:]
        var kinds: [String: (name: String, count: Int, overall: Int)] = [:]

        for row in rows {
            // What this meeting has, group by group. An unknown number gives no choice.
            let rowPeople = Set(row.people.map(\.key))
            var rowTags: [String: String] = [:]
            for tag in row.tags where rowTags[tag.lowercased()] == nil { rowTags[tag.lowercased()] = tag }
            let kindKey = row.kind?.lowercased()
            let length = MeetingFilter.Length.allCases.first { $0.contains(seconds: row.seconds) }
            let rowPeriods = presets.filter { inside(row.start, $0.1) }.map(\.0)
            let weekday = calendar.component(.weekday, from: row.start)
            let value = MeetingFilter.Value(row.value)
            var rowFlags: [MeetingFilter.Flag] = []
            if let n = row.actionItems, n > 0 { rowFlags.append(.actionItems) }
            if let n = row.decisions, n > 0 { rowFlags.append(.decisions) }
            if let n = row.screens, n > 0 { rowFlags.append(.screens) }

            // The groups whose choice this meeting does not meet.
            var failed: Group = []
            if !chosenPeople.isEmpty {
                let ok = filter.peopleMode == .all ? chosenPeople.isSubset(of: rowPeople) : !chosenPeople.isDisjoint(with: rowPeople)
                if !ok { failed.insert(.people) }
            }
            if let custom = filter.customLength {
                if !custom.contains(seconds: row.seconds) { failed.insert(.length) }
            } else if !filter.lengths.isEmpty, !(length.map(filter.lengths.contains) ?? false) {
                failed.insert(.length)
            }
            if let chosenPeriod, !inside(row.start, chosenPeriod) { failed.insert(.period) }
            if !filter.weekdays.isEmpty, !filter.weekdays.contains(weekday) { failed.insert(.weekday) }
            if !chosenTags.isEmpty, chosenTags.isDisjoint(with: rowTags.keys) { failed.insert(.tags) }
            if !chosenKinds.isEmpty, !(kindKey.map(chosenKinds.contains) ?? false) { failed.insert(.kinds) }
            if !filter.sizes.isEmpty, !filter.sizes.contains(row.size) { failed.insert(.size) }
            if !filter.values.isEmpty, !filter.values.contains(value) { failed.insert(.value) }
            if !filter.platforms.isEmpty, !filter.platforms.contains(row.platform) { failed.insert(.platform) }
            for flag in filter.flags where !rowFlags.contains(flag) { failed.insert(.flag(flag)) }

            if failed.isEmpty { filterMatches.insert(row.id) }
            guard within?.contains(row.id) ?? true else { continue }
            total += 1
            if failed.isEmpty { matches.insert(row.id) }
            // A choice counts this meeting when every other group lets it through.
            func counts(_ group: Group) -> Bool { failed.isEmpty || failed == group }

            // With "all of them", a person's count is the meetings that have every chosen person and this one.
            let countsPeople = filter.peopleMode == .all ? failed.isEmpty : counts(.people)
            for who in row.people {
                var entry = people[who.key] ?? (who, 0, 0)
                entry.overall += 1
                if countsPeople { entry.count += 1 }
                people[who.key] = entry
            }
            for (key, name) in rowTags {
                var entry = tags[key] ?? (name, 0, 0)
                entry.overall += 1
                if counts(.tags) { entry.count += 1 }
                tags[key] = entry
            }
            if let kindKey, let name = row.kind {
                var entry = kinds[kindKey] ?? (name, 0, 0)
                entry.overall += 1
                if counts(.kinds) { entry.count += 1 }
                kinds[kindKey] = entry
            }
            if let length { lengths.add(length, counted: counts(.length)) }
            for period in rowPeriods { periods.add(period, counted: counts(.period)) }
            weekdays.add(weekday, counted: counts(.weekday))
            sizes.add(row.size, counted: counts(.size))
            values.add(value, counted: counts(.value))
            platforms.add(row.platform, counted: counts(.platform))
            for flag in rowFlags { flags.add(flag, counted: counts(.flag(flag))) }
        }

        // A chosen person, tag, or kind stays in its list when no meeting looked at has it.
        for who in filter.people where people[who.key] == nil { people[who.key] = (who, 0, 0) }
        for tag in filter.tags where tags[tag.lowercased()] == nil { tags[tag.lowercased()] = (tag, 0, 0) }
        for kind in filter.kinds where kinds[kind.lowercased()] == nil { kinds[kind.lowercased()] = (kind, 0, 0) }

        func byName(_ a: String, _ b: String) -> Bool { a.localizedStandardCompare(b) == .orderedAscending }
        self.people = people.values.sorted { $0.overall != $1.overall ? $0.overall > $1.overall : byName($0.who.name, $1.who.name) }
            .map { Person(who: $0.who, count: $0.count) }
        self.tags = tags.values.sorted { $0.overall != $1.overall ? $0.overall > $1.overall : byName($0.name, $1.name) }
            .map { Named(name: $0.name, count: $0.count) }
        self.kinds = kinds.values.sorted { $0.overall != $1.overall ? $0.overall > $1.overall : byName($0.name, $1.name) }
            .map { Named(name: $0.name, count: $0.count) }
    }
}

extension MeetingFacets {
    /// Equal, and each person under the same name (see `MeetingFilterRow.same`).
    public func isSame(as other: MeetingFacets) -> Bool { self == other && people.map(\.who.name) == other.people.map(\.who.name) }

    /// The people list under the search text of the flyout.
    public func people(matching query: String) -> [Person] { Self.people(people, matching: query) }

    public static func people(_ people: [Person], matching query: String) -> [Person] {
        let q = query.trimmingCharacters(in: .whitespaces)
        return q.isEmpty ? people : people.filter { $0.who.name.localizedCaseInsensitiveContains(q) }
    }

    /// Whom Return in the people search turns on or off: the row in the light, else the first that the text
    /// finds. Never a row that the pointer cannot choose either: one with no meeting that is not on.
    public func choiceOnReturn(query: String, highlighted: String?, filter: MeetingFilter) -> MeetingFilter.Who? {
        Self.choiceOnReturn(people, query: query, highlighted: highlighted, chosen: filter.people)
    }

    /// The same for any list of people with counts, such as the Recurring filter's.
    public static func choiceOnReturn(_ people: [Person], query: String, highlighted: String?, chosen: [MeetingFilter.Who]) -> MeetingFilter.Who? {
        let shown = Self.people(people, matching: query)
        let q = query.trimmingCharacters(in: .whitespaces)
        guard let p = shown.first(where: { $0.id == highlighted }) ?? (q.isEmpty ? nil : shown.first) else { return nil }
        return p.count > 0 || chosen.contains(p.who) ? p.who : nil
    }
}

extension MeetingTally {
    mutating func add(_ key: Key, counted: Bool) {
        overall[key, default: 0] += 1
        if counted { counts[key, default: 0] += 1 }
    }
}
