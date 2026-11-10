import Foundation

/// What the owner needs before an upcoming meeting: who is invited and what Mossad knows about them, what was
/// left open the last time, what the owner still owes these people, and the series in numbers. Pure: the page
/// only shows it.
///
/// A person is known only on a sure match (`PersonDirectory.link`): a wrong person's history before a meeting
/// is worse than none. A number that the history cannot give is nil, never 0.
public struct MeetingPrep: Sendable, Equatable {
    /// One entry of the invite, without the owner.
    public struct Invited: Sendable, Equatable, Identifiable {
        public var id: String { written }
        /// The calendar's entry: a name or an email.
        public var written: String
        /// The saved person's name for an entry that is surely theirs, else the entry.
        public var name: String
        /// The saved person, whose profile the name opens.
        public var person: String?
    }

    /// An earlier meeting to open.
    public struct Earlier: Sendable, Equatable, Identifiable {
        public var id: String
        public var title: String
        public var start: Date

        init(_ r: CallRecord) {
            id = r.id
            title = r.title
            start = r.start
        }
    }

    /// One line about the owner and a person, with how many meetings it comes from.
    public struct Fact: Sendable, Equatable {
        public var text: String
        /// "from 6 meetings".
        public var basis: String
    }

    /// An invited person Mossad knows.
    public struct Person: Sendable, Equatable, Identifiable {
        public var id: String { name }
        public var name: String
        /// Nil for a saved person who never spoke in a recorded meeting.
        public var lastMet: Earlier?
        /// Meetings together in the last `recentDays` days.
        public var recent: Int
        /// Meetings together in all.
        public var meetings: Int
        public var fact: Fact?
    }

    /// An action item of the last meeting that is not known to be closed.
    public struct Item: Sendable, Equatable, Identifiable {
        public var id: String
        public var task: String
        /// The owner as the meeting wrote it; nil for an item with no owner.
        public var owner: String?
        /// The saved person the written owner surely is. Nil for the note's owner, whose items read "You".
        public var person: String?
        /// True for an item of the note's owner.
        public var isOwners: Bool
        public var callID: String
        /// The second of the call to play from: the task's own moment, or the line that says the item. Nil when
        /// no line does.
        public var at: TimeInterval?
        /// The owner's open task that is this item, which the page can mark done.
        public var commitment: UUID?
    }

    public struct LastTime: Sendable, Equatable {
        public var meeting: Earlier
        /// False when the invite has no series and this is the last meeting with its people.
        public var inSeries: Bool
        public var headline: String?
        public var decisions: [Decision]
        public var moreDecisions: Int
        public var items: [Item]
        public var moreItems: Int
    }

    /// The earlier meetings with this invite's title, in numbers.
    public struct Series: Sendable, Equatable {
        public var meetings: Int
        /// The first meeting of the series that Mossad recorded.
        public var since: Date
        /// Nil with fewer than `MeetingAnalytics.Usual.minimumSamples` meetings.
        public var length: MeetingAnalytics.Usual?
        public var ownerShare: MeetingAnalytics.Usual?
        /// How many of the meetings have the invite's planned times, and how many of those ran past the planned
        /// end or began (for the owner) after the planned start. See `MeetingAnalytics.Schedule`.
        public var planned: Int
        public var ranOver: Int
        public var joinedLate: Int
        /// The lengths and the owner's talk shares of the last meetings, oldest first.
        public var lengths: [Double]
        public var shares: [Double]
    }

    public var invited: [Invited]
    public var people: [Person]
    public var lastTime: LastTime?
    /// The owner's open tasks for these people from any meeting, oldest first.
    public var promises: [Commitment]
    public var morePromises: Int
    public var series: Series?
    public var coach: PrepCoach

    /// At most this many decisions, items, and promises; the rest is a number and a link.
    public static let shown = 5
    public static let recentDays = 90.0
    /// One earlier meeting is a last time, not yet a series.
    static let seriesMinimum = 2
    static let trendPoints = 12

    /// `records` and `facts` may hold every meeting: only the written ones that began before this one count.
    public init(meeting: UpcomingMeeting, owner: String, records: [CallRecord], facts: [MeetingFacts], commitments: [Commitment],
                people directory: PersonDirectory, coach: [String: CoachPerson] = [:], now: Date = Date()) {
        let invited = Self.invited(meeting.attendees, owner: owner, directory: directory)
        self.invited = invited
        let known = invited.compactMap(\.person)
        // Everyone of the meeting who has a name, for reading a short name in an item or a promise.
        let names = invited.compactMap { $0.person ?? ($0.written.contains("@") ? nil : $0.written) }
        let past = records.filter { $0.status == .written && $0.start < meeting.start }.sorted { $0.start > $1.start }
        let history = facts.filter { $0.start < meeting.start }.sorted { $0.start > $1.start }

        let size = MeetingFacts.Size(voices: invited.count + 1)
        let since = now.addingTimeInterval(-Self.recentDays * 86_400)
        people = known.map { name in
            let shared = past.filter { $0.speakerNames.values.contains(name) }
            return Person(name: name, lastMet: shared.first.map(Earlier.init), recent: shared.filter { $0.start >= since }.count, meetings: shared.count,
                          fact: Self.fact(about: name, in: history, size: size, met: shared.map(\.start)))
        }

        let key = PeopleDuplicates.normalized(meeting.title)
        // Only a title from the calendar or from the owner makes a series, as in `MeetingFacts.series`.
        let series = past.filter { ($0.titleSource == .calendar || $0.titleSource == .custom) && PeopleDuplicates.normalized($0.title) == key }
        self.series = Self.series(series, facts: history.filter { $0.series == key })

        let last = series.first ?? Self.lastMeeting(with: known, in: past)
        var items: [Item] = []
        if let last {
            let open = Self.openItems(of: last, owner: owner, names: names, directory: directory, commitments: commitments)
            items = Self.withMoments(Array(open.prefix(Self.shown)), in: last)
            lastTime = LastTime(meeting: Earlier(last), inSeries: !series.isEmpty, headline: last.headline?.nonBlank,
                                decisions: Array(last.decisions.prefix(Self.shown)), moreDecisions: max(0, last.decisions.count - Self.shown),
                                items: items, moreItems: max(0, open.count - Self.shown))
        } else {
            lastTime = nil
        }

        let promises = Self.promises(commitments, names: names, series: Set(series.map(\.id)), shown: Set(items.compactMap(\.commitment)))
        self.promises = Array(promises.prefix(Self.shown))
        morePromises = max(0, promises.count - Self.shown)
        self.coach = PrepCoach(people: known, coach: coach)
    }

    // MARK: Invited

    /// The invite's entries without the owner, one per person: a person invited by name and by email is one entry.
    static func invited(_ attendees: [String], owner: String, directory: PersonDirectory) -> [Invited] {
        let names = attendees.filter { !$0.contains("@") }
        var seen: Set<String> = []
        var out: [Invited] = []
        for a in attendees {
            let written = a.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !written.isEmpty else { continue }
            let person = directory.link(for: written, in: names)
            let isEmail = written.contains("@")
            let same = { (name: String) in PeopleDuplicates.normalized(name) == PeopleDuplicates.normalized(owner) }
            // The owner's own entry: their saved profile, their name, or an address that fits their name.
            if person.map(same) == true || same(written) || (isEmail && CalendarInfo.isOwnersAddress(written, ownerName: owner)) { continue }
            let name = person ?? written
            guard seen.insert(PeopleDuplicates.normalized(name)).inserted else { continue }
            out.append(Invited(written: written, name: name, person: person))
        }
        return out
    }

    // MARK: The people

    /// One line about the owner and `name`, from the meetings before this one (`history`, newest first).
    ///
    /// Before a 1:1: the owner's usual part of the talk in their 1:1s. Before a group: the person's usual part in
    /// meetings of this size with the owner, then the 1:1s. A talk share follows the size of a meeting, so
    /// meetings of other sizes say nothing about it. With too few of either: how often the two meet.
    static func fact(about name: String, in history: [MeetingFacts], size: MeetingFacts.Size, met: [Date]) -> Fact? {
        typealias A = MeetingAnalytics
        func usual(_ values: [Double]) -> A.Usual? { A.Usual(Array(values.prefix(A.History.limit))) }
        func range(_ u: A.Usual) -> String { MeetingFindings.range(.talkShare, u) }

        var oneOnOne: Fact?
        if let u = usual(history.filter { $0.partner?.name == name }.compactMap { $0.owner?.values[.talkShare] }) {
            oneOnOne = Fact(text: u.isFirm ? "You usually talk \(range(u)) of the time in your 1:1s"
                                : "You talked \(range(u)) of the time in your \(u.samples) 1:1s so far", basis: MeetingFindings.basis(u))
        }
        if size == .oneOnOne, let oneOnOne { return oneOnOne }
        if size != .oneOnOne {
            let together = history.filter { $0.partner == nil && $0.size == size && $0.owner != nil }.compactMap { $0.person(name)?.values[.talkShare] }
            if let u = usual(together) {
                return Fact(text: u.isFirm ? "Usually talks \(range(u)) of the time in meetings of \(size.words) with you"
                                : "Talked \(range(u)) of the time in \(u.samples) meetings of \(size.words) with you so far", basis: MeetingFindings.basis(u))
            }
            if let oneOnOne { return oneOnOne }
        }
        // The same number as a person's profile: the average time from one meeting to the next.
        let dates = met.sorted()
        guard dates.count >= A.Usual.minimumSamples, let first = dates.first, let last = dates.last else { return nil }
        let days = max(1, Int((last.timeIntervalSince(first) / 86_400 / Double(dates.count - 1)).rounded()))
        return Fact(text: days == 1 ? "You meet about every day" : "You meet about every \(days) days",
                    basis: "from \(dates.count) meetings")
    }

    // MARK: The series

    /// `records` are the series' meetings and `facts` their rows of history, both newest first.
    static func series(_ records: [CallRecord], facts: [MeetingFacts]) -> Series? {
        guard records.count >= seriesMinimum, let first = records.last else { return nil }
        typealias A = MeetingAnalytics
        let recent = Array(facts.prefix(A.History.limit))
        let schedules = records.compactMap { r -> A.Schedule? in
            guard let start = r.plannedStart, let end = r.plannedEnd, end > start else { return nil }
            return A.Schedule(plannedStart: start, plannedEnd: end, startDelay: r.start.timeIntervalSince(start), overrun: r.end.timeIntervalSince(end))
        }
        let lengths = recent.compactMap { $0.values[.length] }, shares = recent.compactMap { $0.owner?.values[.talkShare] }
        return Series(meetings: records.count, since: first.start, length: A.Usual(lengths), ownerShare: A.Usual(shares),
                      planned: schedules.count, ranOver: schedules.filter(\.ranOver).count, joinedLate: schedules.filter(\.joinedLate).count,
                      lengths: lengths.prefix(trendPoints).reversed(), shares: shares.prefix(trendPoints).reversed())
    }

    /// With no series: the last meeting in which the known invited people spoke. All of them when they are one
    /// or two; of more, two in three, so one person who was away does not hide the meeting.
    static func lastMeeting(with known: [String], in past: [CallRecord]) -> CallRecord? {
        guard !known.isEmpty else { return nil }
        let needed = known.count <= 2 ? known.count : Int((Double(known.count) * 2 / 3).rounded(.up))
        return past.first { r in
            let spoke = Set(r.speakerNames.values)
            return known.filter(spoke.contains).count >= needed
        }
    }
}
