import Foundation

/// What the owner chose in the Meetings filter. Pure: the app holds one, and `MeetingFacets` says which meetings
/// it leaves. An empty filter leaves every meeting. The groups combine with "and"; the choices inside one group
/// combine with "or", except the people when the owner asks for all of them, and the three "has" switches.
///
/// A choice is about something Mossad knows of a meeting. A meeting that cannot say (no transcript, so no number
/// of people; no summary, so no action items) matches none of that group's choices.
public struct MeetingFilter: Equatable, Sendable {
    /// A person in the filter: by the durable id where the meeting's name is surely a saved person, otherwise by
    /// the name as the meeting shows it. Two with one id are the same person under any name.
    public struct Who: Hashable, Sendable {
        /// The `PersonID` of the saved person, when there is one.
        public var id: String?
        public var name: String

        public init(id: String? = nil, name: String) {
            self.id = id
            self.name = name
        }

        /// What decides "the same person": the id, or the name in one spelling. A name never equals an id.
        public var key: String { id.map { "id:" + $0 } ?? "name:" + PersonNames.key(name) }

        public static func == (a: Who, b: Who) -> Bool { a.key == b.key }
        public func hash(into hasher: inout Hasher) { hasher.combine(key) }
    }

    public enum PeopleMode: Sendable { case any, all }

    /// The length ranges. Each takes its lower edge: a meeting of 30 minutes is in "30–60".
    public enum Length: Int, CaseIterable, Sendable {
        case under15, to30, to60, over60

        public func contains(seconds: TimeInterval) -> Bool {
            switch self {
            case .under15: seconds < 900
            case .to30: seconds >= 900 && seconds < 1800
            case .to60: seconds >= 1800 && seconds < 3600
            case .over60: seconds >= 3600
            }
        }
    }

    /// Whole minutes as the list shows them, both ends in; no `max` is "or more".
    public struct MinuteRange: Hashable, Sendable {
        public var min: Int
        public var max: Int?

        public init(min: Int, max: Int?) {
            self.min = Swift.max(0, min)
            self.max = max.map { Swift.max($0, Swift.max(0, min)) }
        }

        public func contains(seconds: TimeInterval) -> Bool {
            let minutes = Int(seconds / 60)
            return minutes >= min && (max.map { minutes <= $0 } ?? true)
        }
    }

    public enum Period: Hashable, Sendable {
        case today, thisWeek, last7, last30, last90
        /// Whole days, both in, in either order.
        case custom(from: Date, to: Date)

        public static let presets: [Period] = [.today, .thisWeek, .last7, .last30, .last90]

        /// The days the period covers. "Last 7 days" is today and the six days before, as in Analytics.
        public func interval(now: Date, calendar: Calendar) -> DateInterval {
            let today = calendar.startOfDay(for: now)
            let tomorrow = calendar.date(byAdding: .day, value: 1, to: today) ?? today.addingTimeInterval(86400)
            func back(_ days: Int) -> DateInterval {
                DateInterval(start: calendar.date(byAdding: .day, value: -(days - 1), to: today) ?? today, end: tomorrow)
            }
            switch self {
            case .today: return back(1)
            case .thisWeek: return calendar.dateInterval(of: .weekOfYear, for: now) ?? back(7)
            case .last7: return back(7)
            case .last30: return back(30)
            case .last90: return back(90)
            case .custom(let a, let b):
                let first = calendar.startOfDay(for: min(a, b)), last = calendar.startOfDay(for: max(a, b))
                return DateInterval(start: first, end: calendar.date(byAdding: .day, value: 1, to: last) ?? last.addingTimeInterval(86400))
            }
        }

        public var isCustom: Bool { if case .custom = self { true } else { false } }
    }

    /// How many people, by the voices that count (`MeetingFacts.mainVoices`).
    public enum Size: Int, CaseIterable, Sendable {
        case alone, oneOnOne, small, large

        public init(voices: Int) {
            self = voices <= 1 ? .alone : voices == 2 ? .oneOnOne : voices <= 5 ? .small : .large
        }
    }

    /// The coach's rating. A meeting with no rating is its own choice and never a low one.
    public enum Value: Hashable, CaseIterable, Sendable {
        case high, medium, low, notRated

        public init(_ rating: MeetingValue.Rating?) {
            switch rating {
            case .high: self = .high
            case .medium: self = .medium
            case .low: self = .low
            case nil: self = .notRated
            }
        }
    }

    public enum Flag: Hashable, CaseIterable, Sendable { case actionItems, decisions, screens }

    public var people: [Who] = []
    public var peopleMode = PeopleMode.any
    public var lengths: Set<Length> = []
    /// Used in place of the ranges.
    public var customLength: MinuteRange?
    public var period: Period?
    /// `Calendar` weekday numbers: 1 is Sunday.
    public var weekdays: Set<Int> = []
    /// Each in the spelling it was chosen in; they match in any case.
    public var tags: [String] = []
    public var kinds: [String] = []
    public var sizes: Set<Size> = []
    public var values: Set<Value> = []
    public var platforms: Set<Platform> = []
    public var flags: Set<Flag> = []

    public init() {}

    public var isEmpty: Bool { active.isEmpty }

    // MARK: Choices

    /// One choice, as one chip under the list's title.
    public enum Active: Hashable, Sendable {
        case person(Who), period(Period), weekday(Int), length(Length), customLength(MinuteRange), size(Size)
        case tag(String), kind(String), value(Value), platform(Platform), flag(Flag)
    }

    /// Every choice in the order of the groups; their number is the button's badge.
    public var active: [Active] {
        var out: [Active] = people.map(Active.person)
        if let period { out.append(.period(period)) }
        out += weekdays.sorted().map(Active.weekday)
        out += lengths.sorted { $0.rawValue < $1.rawValue }.map(Active.length)
        if let customLength { out.append(.customLength(customLength)) }
        out += sizes.sorted { $0.rawValue < $1.rawValue }.map(Active.size)
        out += tags.map(Active.tag)
        out += kinds.map(Active.kind)
        out += Value.allCases.filter(values.contains).map(Active.value)
        out += Platform.allCases.filter(platforms.contains).map(Active.platform)
        out += Flag.allCases.filter(flags.contains).map(Active.flag)
        return out
    }

    private static func same(_ a: String, _ b: String) -> Bool { a.caseInsensitiveCompare(b) == .orderedSame }

    public func contains(_ choice: Active) -> Bool {
        switch choice {
        case .person(let who): people.contains(who)
        case .period(let p): period == p
        case .weekday(let d): weekdays.contains(d)
        case .length(let l): lengths.contains(l)
        case .customLength(let r): customLength == r
        case .size(let s): sizes.contains(s)
        case .tag(let t): tags.contains { Self.same($0, t) }
        case .kind(let k): kinds.contains { Self.same($0, k) }
        case .value(let v): values.contains(v)
        case .platform(let p): platforms.contains(p)
        case .flag(let f): flags.contains(f)
        }
    }

    public mutating func remove(_ choice: Active) {
        switch choice {
        case .person(let who):
            people.removeAll { $0 == who }
            // "All of them" says nothing about one person.
            if people.count < 2 { peopleMode = .any }
        case .period: period = nil
        case .weekday(let d): weekdays.remove(d)
        case .length(let l): lengths.remove(l)
        case .customLength: customLength = nil
        case .size(let s): sizes.remove(s)
        case .tag(let t): tags.removeAll { Self.same($0, t) }
        case .kind(let k): kinds.removeAll { Self.same($0, k) }
        case .value(let v): values.remove(v)
        case .platform(let p): platforms.remove(p)
        case .flag(let f): flags.remove(f)
        }
    }

    /// Turns a choice on or off. One period at a time; a custom length takes the place of the ranges, and a range
    /// takes the place of a custom length.
    public mutating func toggle(_ choice: Active) {
        if contains(choice) { return remove(choice) }
        switch choice {
        case .person(let who): people.append(who)
        case .period(let p): period = p
        case .weekday(let d): weekdays.insert(d)
        case .length(let l):
            customLength = nil
            lengths.insert(l)
        case .customLength(let r):
            lengths = []
            customLength = r
        case .size(let s): sizes.insert(s)
        case .tag(let t): tags.append(t)
        case .kind(let k): kinds.append(k)
        case .value(let v): values.insert(v)
        case .platform(let p): platforms.insert(p)
        case .flag(let f): flags.insert(f)
        }
    }
}

// MARK: Words

extension MeetingFilter.Length {
    public var label: String {
        switch self {
        case .under15: "Under 15 min"
        case .to30: "15–30 min"
        case .to60: "30–60 min"
        case .over60: "Over 60 min"
        }
    }
}

extension MeetingFilter.MinuteRange {
    public var label: String {
        guard let max else { return "\(min) min or more" }
        return min == 0 ? "Up to \(max) min" : min == max ? "\(min) min" : "\(min)–\(max) min"
    }
}

extension MeetingFilter.Period {
    /// "Last 7 days"; a custom range as its days, with the year when it is not this one.
    public func label(calendar: Calendar = .current, now: Date = Date()) -> String {
        switch self {
        case .today: return "Today"
        case .thisWeek: return "This week"
        case .last7: return "Last 7 days"
        case .last30: return "Last 30 days"
        case .last90: return "Last 90 days"
        case .custom(let a, let b):
            let first = min(a, b), last = max(a, b)
            var style = Date.FormatStyle(locale: calendar.locale ?? .current, calendar: calendar, timeZone: calendar.timeZone).month(.abbreviated).day()
            if !calendar.isDate(last, equalTo: now, toGranularity: .year) || !calendar.isDate(first, equalTo: now, toGranularity: .year) { style = style.year() }
            return calendar.isDate(first, inSameDayAs: last) ? first.formatted(style) : "\(first.formatted(style)) – \(last.formatted(style))"
        }
    }
}

extension MeetingFilter.Size {
    /// Inside the group "People in the meeting".
    public var option: String {
        switch self {
        case .alone: "Just me"
        case .oneOnOne: "1:1"
        case .small: "3–5"
        case .large: "6+"
        }
    }

    public var label: String {
        switch self {
        case .alone, .oneOnOne: option
        case .small, .large: option + " people"
        }
    }
}

extension MeetingFilter.Value {
    /// Inside the group "Meeting value".
    public var option: String {
        switch self {
        case .high: "High"
        case .medium: "Medium"
        case .low: "Low"
        case .notRated: "Not rated"
        }
    }

    public var label: String { self == .notRated ? option : option + " value" }
}

extension MeetingFilter.Flag {
    /// Inside the group "Has".
    public var option: String {
        switch self {
        case .actionItems: "Action items"
        case .decisions: "Decisions"
        case .screens: "Shared screens"
        }
    }

    public var label: String {
        switch self {
        case .actionItems: "Has action items"
        case .decisions: "Has decisions"
        case .screens: "Has screens"
        }
    }
}

extension Platform {
    /// "Meet", "Teams": the short name of the lists and the filter.
    public var filterName: String {
        switch self {
        case .zoom: "Zoom"
        case .meet: "Meet"
        case .teams: "Teams"
        case .inPerson: "In person"
        }
    }
}

extension MeetingFilter.Active {
    /// The chip's words.
    public func label(calendar: Calendar = .current, now: Date = Date()) -> String {
        switch self {
        case .person(let who): who.name
        case .period(let p): p.label(calendar: calendar, now: now)
        case .weekday(let d): calendar.shortWeekdaySymbols.indices.contains(d - 1) ? calendar.shortWeekdaySymbols[d - 1] : "Day \(d)"
        case .length(let l): l.label
        case .customLength(let r): r.label
        case .size(let s): s.label
        case .tag(let t): t
        case .kind(let k): k
        case .value(let v): v.label
        case .platform(let p): p.filterName
        case .flag(let f): f.label
        }
    }
}
