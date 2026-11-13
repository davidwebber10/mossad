import Foundation

/// What the owner chose in the Recurring filter. Pure, as `MeetingFilter`, whose people, lengths, sizes, ratings,
/// and platforms it uses: an empty filter leaves every series, the groups combine with "and", and the choices inside
/// one group with "or", except the people when the owner asks for all of them. A series that cannot say (no meeting
/// recorded, so no length; no rating) matches none of that group's choices; "None known" and "Not rated" are choices
/// of their own.
public struct SeriesFilter: Equatable, Codable, Sendable {
    /// How often it meets, in the groups the owner thinks in. A series whose dates say nothing has no cadence.
    public enum Cadence: Int, CaseIterable, Codable, Sendable {
        case weekly, everyTwoWeeks, monthly, other

        /// The group of the series' schedule, the rule that its day groups use: a series on several weekdays each
        /// week is weekly.
        public init?(_ schedule: SeriesSchedule) {
            switch schedule.rhythm {
            case .weekly?: self = .weekly
            case .weeks(2)?: self = .everyTwoWeeks
            case .monthly?: self = .monthly
            case .weeks?, .days?: self = .other
            case nil: return nil
            }
        }

        public init?(_ cadence: SeriesCadence?) {
            guard let cadence else { return nil }
            switch cadence.rhythm {
            case .weekly: self = .weekly
            case .everyOtherWeek: self = .everyTwoWeeks
            case .monthly: self = .monthly
            case .weekdays, .daily, .everyDays: self = .other
            }
        }
    }

    /// The days a date choice holds: from `start` (in) to `end` (out); an open end has no limit. `none` holds only
    /// a missing date.
    public struct DateRule: Sendable {
        var start: Date?
        var end: Date?
        var none = false

        public func contains(_ date: Date?) -> Bool {
            guard let date else { return none }
            return !none && (start.map { date >= $0 } ?? true) && (end.map { date < $0 } ?? true)
        }
    }

    /// When the next meeting is, from the calendar. One at a time: "this week" is also in "next 2 weeks".
    public enum Next: Int, CaseIterable, Codable, Sendable {
        case thisWeek, twoWeeks, noneKnown

        public func rule(now: Date, calendar: Calendar) -> DateRule {
            let today = calendar.startOfDay(for: now)
            switch self {
            case .noneKnown: return DateRule(none: true)
            case .thisWeek: return DateRule(start: today, end: calendar.dateInterval(of: .weekOfYear, for: now)?.end ?? today)
            case .twoWeeks: return DateRule(start: today, end: calendar.date(byAdding: .day, value: 14, to: today) ?? today.addingTimeInterval(14 * 86400))
            }
        }

        public func contains(_ next: Date?, now: Date, calendar: Calendar) -> Bool { rule(now: now, calendar: calendar).contains(next) }
    }

    /// When the owner last met in the series. One at a time, as the date of the Meetings filter.
    public enum LastMet: Int, CaseIterable, Codable, Sendable {
        case last7, last30, last90, earlier

        public func rule(now: Date, calendar: Calendar) -> DateRule {
            let period: MeetingFilter.Period = switch self {
            case .last7: .last7
            case .last30: .last30
            case .last90, .earlier: .last90
            }
            let days = period.interval(now: now, calendar: calendar)
            return self == .earlier ? DateRule(end: days.start) : DateRule(start: days.start, end: days.end)
        }

        public func contains(_ last: Date, now: Date, calendar: Calendar) -> Bool { rule(now: now, calendar: calendar).contains(last) }
    }

    public var people: [MeetingFilter.Who] = []
    public var peopleMode = MeetingFilter.PeopleMode.any
    public var cadences: Set<Cadence> = []
    public var next: Next?
    public var lastMet: LastMet?
    /// The usual length of its meetings.
    public var lengths: Set<MeetingFilter.Length> = []
    /// The usual number of people, by the size rule of the Meetings filter.
    public var sizes: Set<MeetingFilter.Size> = []
    /// The coach's usual rating of its meetings.
    public var values: Set<MeetingFilter.Value> = []
    public var platforms: Set<Platform> = []
    public var openItems = false

    public init() {}

    public var isEmpty: Bool { active.isEmpty }

    /// One choice, as one chip under the list's title.
    public enum Active: Hashable, Sendable {
        case person(MeetingFilter.Who), cadence(Cadence), next(Next), lastMet(LastMet), length(MeetingFilter.Length)
        case size(MeetingFilter.Size), value(MeetingFilter.Value), platform(Platform), openItems
    }

    /// Every choice in the order of the groups; their number is the button's badge.
    public var active: [Active] {
        var out: [Active] = people.map(Active.person)
        out += Cadence.allCases.filter(cadences.contains).map(Active.cadence)
        if let next { out.append(.next(next)) }
        if let lastMet { out.append(.lastMet(lastMet)) }
        out += MeetingFilter.Length.allCases.filter(lengths.contains).map(Active.length)
        out += MeetingFilter.Size.allCases.filter(sizes.contains).map(Active.size)
        out += MeetingFilter.Value.allCases.filter(values.contains).map(Active.value)
        out += Platform.allCases.filter(platforms.contains).map(Active.platform)
        if openItems { out.append(.openItems) }
        return out
    }

    public func contains(_ choice: Active) -> Bool {
        switch choice {
        case .person(let who): people.contains(who)
        case .cadence(let c): cadences.contains(c)
        case .next(let n): next == n
        case .lastMet(let l): lastMet == l
        case .length(let l): lengths.contains(l)
        case .size(let s): sizes.contains(s)
        case .value(let v): values.contains(v)
        case .platform(let p): platforms.contains(p)
        case .openItems: openItems
        }
    }

    public mutating func remove(_ choice: Active) {
        switch choice {
        case .person(let who):
            people.removeAll { $0 == who }
            if people.count < 2 { peopleMode = .any }
        case .cadence(let c): cadences.remove(c)
        case .next: next = nil
        case .lastMet: lastMet = nil
        case .length(let l): lengths.remove(l)
        case .size(let s): sizes.remove(s)
        case .value(let v): values.remove(v)
        case .platform(let p): platforms.remove(p)
        case .openItems: openItems = false
        }
    }

    /// Turns a choice on or off. One next date and one last date at a time.
    public mutating func toggle(_ choice: Active) {
        if contains(choice) { return remove(choice) }
        switch choice {
        case .person(let who): people.append(who)
        case .cadence(let c): cadences.insert(c)
        case .next(let n): next = n
        case .lastMet(let l): lastMet = l
        case .length(let l): lengths.insert(l)
        case .size(let s): sizes.insert(s)
        case .value(let v): values.insert(v)
        case .platform(let p): platforms.insert(p)
        case .openItems: openItems = true
        }
    }
}

// MARK: Words

extension SeriesFilter.Cadence {
    public var option: String {
        switch self {
        case .weekly: "Weekly"
        case .everyTwoWeeks: "Every 2 weeks"
        case .monthly: "Monthly"
        case .other: "Other"
        }
    }

    public var label: String { self == .other ? "Other cadence" : option }
}

extension SeriesFilter.Next {
    public var option: String {
        switch self {
        case .thisWeek: "This week"
        case .twoWeeks: "Next 2 weeks"
        case .noneKnown: "None known"
        }
    }

    public var label: String {
        switch self {
        case .thisWeek: "Next: this week"
        case .twoWeeks: "Next: in 2 weeks"
        case .noneKnown: "No next meeting known"
        }
    }
}

extension SeriesFilter.LastMet {
    public var option: String {
        switch self {
        case .last7: "Last 7 days"
        case .last30: "Last 30 days"
        case .last90: "Last 90 days"
        case .earlier: "Earlier"
        }
    }

    public var label: String {
        switch self {
        case .last7: "Met in the last 7 days"
        case .last30: "Met in the last 30 days"
        case .last90: "Met in the last 90 days"
        case .earlier: "Last met over 90 days ago"
        }
    }
}

extension SeriesFilter.Active {
    /// The chip's words.
    public var label: String {
        switch self {
        case .person(let who): who.name
        case .cadence(let c): c.label
        case .next(let n): n.label
        case .lastMet(let l): l.label
        case .length(let l): "Usually " + l.label.prefix(1).lowercased() + l.label.dropFirst()
        case .size(let s): s.label
        case .value(let v): v.label
        case .platform(let p): p.filterName
        case .openItems: "Has open items"
        }
    }
}
