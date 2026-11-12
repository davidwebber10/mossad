import Foundation

/// A recurring meeting: the recorded meetings (and Gemini notes-only meetings) of one series, and its next
/// occurrences from the calendar. Built by `SeriesCatalog`, pure.
public struct MeetingSeries: Sendable, Equatable, Identifiable, Hashable {
    /// One meeting of the series that happened.
    public struct Occurrence: Sendable, Equatable, Hashable, Identifiable {
        public var id: String
        public var title: String
        public var start: Date
        public var end: Date
        public var notesOnly: Bool
    }

    /// Stable while the series lives: "cal:<calendar series id>" when the calendar ever named one, else
    /// "call:<the id of its first meeting>". A point saved for a series also keeps `keys`, so it finds its series
    /// again when the id moves (Google gives a new series id for "this and following events").
    public var id: String
    /// The id, every calendar series id ("cal:"), and every meeting ("call:").
    public var keys: Set<String>
    /// The title of the newest meeting or invite.
    public var title: String
    /// Newest first.
    public var meetings: [Occurrence]
    /// The invites still to come that belong to it, soonest first.
    public var upcoming: [UpcomingMeeting]
    public var cadence: SeriesCadence?
    /// True when the calendar says that it repeats.
    public var recurringInCalendar: Bool
    /// The people (without the owner) who came to at least half of the last meetings, most often first.
    public var usualPeople: [String]

    public var next: UpcomingMeeting? { upcoming.first }
    public var last: Occurrence? { meetings.first }

    public static func == (a: MeetingSeries, b: MeetingSeries) -> Bool {
        a.id == b.id && a.keys == b.keys && a.title == b.title && a.meetings == b.meetings && a.upcoming.map(\.id) == b.upcoming.map(\.id)
            && a.cadence == b.cadence && a.usualPeople == b.usualPeople
    }

    public func hash(into h: inout Hasher) { h.combine(id) }

    /// Whether a saved series id or key list is this series.
    public func matches(id other: String?, keys more: [String]?) -> Bool {
        if let other, keys.contains(other) { return true }
        return !(more ?? []).allSatisfy { !keys.contains($0) }
    }

    /// The keys to save with a point: the id, the calendar ids, and the last meetings.
    public var savedKeys: [String] {
        let cal = keys.filter { $0.hasPrefix("cal:") }.sorted()
        return Array(Set([id] + cal + meetings.prefix(Self.savedMeetings).map { "call:\($0.id)" })).sorted()
    }

    static let savedMeetings = 8
}

/// How often a series meets, from its dates: "Every Tuesday 10:00".
public struct SeriesCadence: Sendable, Equatable, Hashable {
    public enum Rhythm: Sendable, Equatable, Hashable {
        case weekdays
        case daily
        /// 1 is Sunday, as `Calendar` counts.
        case weekly(weekday: Int)
        case everyOtherWeek(weekday: Int)
        case monthly
        case everyDays(Int)
    }

    public var rhythm: Rhythm
    /// The usual start as hour and minute, when the meetings agree.
    public var hour: Int?
    public var minute: Int?
    /// The days from one meeting to the next.
    public var interval: Double

    /// "Every Tuesday 10:00", "Every other Monday", "Every weekday 9:30", "Monthly", "About every 10 days".
    public var text: String {
        let days = Self.weekdays
        let words: String = switch rhythm {
        case .weekdays: "Every weekday"
        case .daily: "Every day"
        case .weekly(let d): "Every \(days[(d - 1) % 7])"
        case .everyOtherWeek(let d): "Every other \(days[(d - 1) % 7])"
        case .monthly: "Monthly"
        case .everyDays(let n): "About every \(n) days"
        }
        guard let hour, let minute else { return words }
        return words + String(format: " %d:%02d", hour, minute)
    }

    static let weekdays = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"]

    /// Nil with fewer than two dates on two different days.
    public static func from(_ dates: [Date], calendar: Calendar = .current) -> SeriesCadence? {
        var byDay: [Date: Date] = [:]
        for d in dates { byDay[calendar.startOfDay(for: d)] = min(byDay[calendar.startOfDay(for: d)] ?? d, d) }
        let sorted = byDay.values.sorted()
        guard sorted.count >= 2 else { return nil }
        let gaps = zip(sorted, sorted.dropFirst()).map { $1.timeIntervalSince($0) / 86_400 }.sorted()
        let interval = gaps[gaps.count / 2]
        let weekdays = sorted.map { calendar.component(.weekday, from: $0) }
        let usualDay = Dictionary(grouping: weekdays, by: { $0 }).max { ($0.value.count, -$0.key) < ($1.value.count, -$1.key) }!.key
        let rhythm: Rhythm
        switch interval {
        case ..<1.5: rhythm = weekdays.allSatisfy { (2...6).contains($0) } ? .weekdays : .daily
        case 5.5..<8.5: rhythm = .weekly(weekday: usualDay)
        case 12.5..<16: rhythm = .everyOtherWeek(weekday: usualDay)
        case 25..<35: rhythm = .monthly
        default: rhythm = .everyDays(max(1, Int(interval.rounded())))
        }
        // The time only when most of the meetings start at it (to five minutes).
        let times = sorted.map { d -> Int in
            let c = calendar.dateComponents([.hour, .minute], from: d)
            return ((c.hour ?? 0) * 60 + (c.minute ?? 0) + 2) / 5 * 5
        }
        let usual = Dictionary(grouping: times, by: { $0 }).max { ($0.value.count, -$0.key) < ($1.value.count, -$1.key) }!
        let agreed = Double(usual.value.count) / Double(times.count) > 0.5
        return SeriesCadence(rhythm: rhythm, hour: agreed ? usual.key / 60 : nil, minute: agreed ? usual.key % 60 : nil, interval: interval)
    }
}

/// Finds the recurring meetings among the records and the calendar's invites. Pure.
///
/// The rule is the one of the prep page (`MeetingPrep.series`): two meetings are one series when the calendar gave
/// them the same series id, or when they have the same title (from the calendar or the owner) and either nearly
/// the same people (`MeetingPrep.sameSeries`, counted both ways) or the same call link and one shared person. A
/// chain of such pairs is one series, so a series whose people change slowly stays one. Two meetings make a
/// series; one meeting makes one only when the calendar says that its invite repeats.
public enum SeriesCatalog {
    struct Member {
        let record: CallRecord
        let titleKey: String?
        let listed: Set<String>
        let voices: Set<String>
        var people: Set<String> { listed.isEmpty ? voices : listed }
    }

    /// `records` may hold every meeting: only the written ones count. `upcoming` are the calendar's invites.
    public static func build(records: [CallRecord], upcoming: [UpcomingMeeting], owner: String, directory: PersonDirectory,
                             ownerEmails: [String] = [], calendar: Calendar = .current) -> [MeetingSeries] {
        let past = records.filter { $0.status == .written }.sorted { ($0.start, $0.id) < ($1.start, $1.id) }
        let ownerKey = PeopleDuplicates.normalized(owner)
        let members = past.map { r -> Member in
            let eligible = r.titleSource == .calendar || r.titleSource == .custom
            let listed = Set(MeetingPrep.invited(r.attendees, owner: owner, directory: directory, ownerEmails: ownerEmails).map { PeopleDuplicates.normalized($0.name) })
            let voices = Set(r.speakerNames.values.filter { !$0.hasPrefix("Speaker ") }.map(PeopleDuplicates.normalized).filter { $0 != ownerKey })
            return Member(record: r, titleKey: eligible ? PeopleDuplicates.normalized(r.title) : nil, listed: listed, voices: voices)
        }

        var parent = Array(members.indices)
        func find(_ i: Int) -> Int {
            var i = i
            while parent[i] != i { parent[i] = parent[parent[i]]; i = parent[i] }
            return i
        }
        func union(_ a: Int, _ b: Int) { let x = find(a), y = find(b); if x != y { parent[max(x, y)] = min(x, y) } }

        var bySeriesID: [String: Int] = [:]
        for (i, m) in members.enumerated() {
            guard let id = m.record.calendarSeriesID else { continue }
            if let j = bySeriesID[id] { union(i, j) } else { bySeriesID[id] = i }
        }
        let byTitle = Dictionary(grouping: members.indices.filter { members[$0].titleKey != nil }, by: { members[$0].titleKey! })
        for group in byTitle.values where group.count > 1 {
            for (n, i) in group.enumerated() {
                for j in group[(n + 1)...] where find(i) != find(j) && same(members[i], members[j]) { union(i, j) }
            }
        }

        var clusters: [Int: [Int]] = [:]
        for i in members.indices { clusters[find(i), default: []].append(i) }

        // The invites: each joins the series of its newest meeting by the prep page's rule, or makes one of its own.
        var invites: [Int: [UpcomingMeeting]] = [:]
        var calendarOnly: [String: [UpcomingMeeting]] = [:]
        for u in upcoming.sorted(by: { $0.start < $1.start }) {
            if let id = u.seriesID, let i = bySeriesID[id] {
                invites[find(i), default: []].append(u)
                continue
            }
            let invited = MeetingPrep.invited(u.attendees, owner: owner, directory: directory, ownerEmails: ownerEmails)
            if let newest = MeetingPrep.series(of: u, invited: invited, in: past.filter { $0.start < u.start }.reversed(), owner: owner,
                                               directory: directory, ownerEmails: ownerEmails).first,
               let i = members.firstIndex(where: { $0.record.id == newest.id }) {
                invites[find(i), default: []].append(u)
            } else if u.repeats {
                calendarOnly[u.seriesID ?? "title:" + PeopleDuplicates.normalized(u.title), default: []].append(u)
            }
        }

        var out: [MeetingSeries] = []
        for (root, indices) in clusters {
            let records = indices.map { members[$0].record }
            let upcoming = invites[root] ?? []
            let repeats = upcoming.contains(where: \.repeats)
            guard records.count >= 2 || repeats else { continue }
            out.append(make(records: records, upcoming: upcoming, repeats: repeats, members: indices.map { members[$0] }, directory: directory, calendar: calendar))
        }
        for (_, upcoming) in calendarOnly {
            out.append(make(records: [], upcoming: upcoming, repeats: true, members: [], directory: directory, calendar: calendar))
        }
        // The next meeting first, then the most recent.
        return out.sorted { a, b in
            switch (a.next?.start, b.next?.start) {
            case let (x?, y?): return (x, a.id) < (y, b.id)
            case (.some, nil): return true
            case (nil, .some): return false
            default: return ((a.last?.start ?? .distantPast), b.id) > ((b.last?.start ?? .distantPast), a.id)
            }
        }
    }

    /// The pair rule of `MeetingPrep.series`, for two recorded meetings.
    static func same(_ a: Member, _ b: Member) -> Bool {
        guard let ka = a.titleKey, ka == b.titleKey else { return false }
        let sameLink: Bool? = a.record.meetingID.flatMap { x in b.record.meetingID.map { $0.lowercased() == x.lowercased() } }
        guard !a.people.isEmpty, !b.people.isEmpty else { return sameLink != false }
        if sameLink == true, !a.listed.union(a.voices).isDisjoint(with: b.listed.union(b.voices)) { return true }
        return Double(a.people.intersection(b.people).count) / Double(a.people.union(b.people).count) >= MeetingPrep.sameSeries
    }

    static func make(records: [CallRecord], upcoming: [UpcomingMeeting], repeats: Bool, members: [Member], directory: PersonDirectory,
                     calendar: Calendar) -> MeetingSeries {
        let oldestFirst = records.sorted { ($0.start, $0.id) < ($1.start, $1.id) }
        let calendarIDs = oldestFirst.compactMap(\.calendarSeriesID) + upcoming.compactMap(\.seriesID)
        let id = calendarIDs.first.map { "cal:\($0)" } ?? oldestFirst.first.map { "call:\($0.id)" }
            ?? "title:\(PeopleDuplicates.normalized(upcoming.first?.title ?? ""))"
        var keys = Set(calendarIDs.map { "cal:\($0)" } + oldestFirst.map { "call:\($0.id)" })
        keys.insert(id)
        let meetings = oldestFirst.reversed().map { MeetingSeries.Occurrence(id: $0.id, title: $0.title, start: $0.start, end: $0.end, notesOnly: $0.isNotesOnly) }
        // A planned start says the series' time better than when the recording began.
        let dates = oldestFirst.map { $0.plannedStart ?? $0.start } + upcoming.map(\.start)
        return MeetingSeries(id: id, keys: keys, title: upcoming.last?.title ?? meetings.first?.title ?? "", meetings: meetings, upcoming: upcoming,
                             cadence: SeriesCadence.from(dates, calendar: calendar), recurringInCalendar: repeats,
                             usualPeople: usualPeople(members.sorted { $0.record.start > $1.record.start }, directory: directory, upcoming: upcoming))
    }

    static let usualWindow = 10

    /// The people of at least half of the last meetings, by the name the meetings use most.
    static func usualPeople(_ newestFirst: [Member], directory: PersonDirectory, upcoming: [UpcomingMeeting]) -> [String] {
        let recent = newestFirst.prefix(usualWindow)
        guard !recent.isEmpty else { return [] }
        var counts: [String: Int] = [:]
        var shown: [String: String] = [:]
        for m in recent {
            let names = m.record.speakerNames.values.filter { !$0.hasPrefix("Speaker ") }
                + m.record.attendees.compactMap { directory.link(for: $0) ?? ($0.contains("@") ? nil : $0) }
            for key in m.listed.union(m.voices) {
                counts[key, default: 0] += 1
                if shown[key] == nil { shown[key] = names.first { PeopleDuplicates.normalized($0) == key } ?? key }
            }
        }
        let needed = max(1, Int((Double(recent.count) / 2).rounded(.up)))
        return counts.filter { $0.value >= needed }.sorted { ($0.value, $1.key) > ($1.value, $0.key) }.compactMap { shown[$0.key] }
    }

    /// The series of an invite, when it has one.
    public static func series(of meeting: UpcomingMeeting, in all: [MeetingSeries]) -> MeetingSeries? {
        all.first { s in s.upcoming.contains { $0.id == meeting.id } }
    }

    /// The series of a recorded meeting, when it has one.
    public static func series(ofCall id: String, in all: [MeetingSeries]) -> MeetingSeries? {
        all.first { $0.keys.contains("call:\(id)") }
    }
}

extension UpcomingMeeting {
    /// The calendar says that it repeats.
    var repeats: Bool { isRecurring || seriesID != nil }
}
