import Foundation

/// What the owner needs before an upcoming meeting: who is invited and what Mossad knows about them, the action
/// items of the last time, what the owner still owes these people, and the series in numbers. Pure: the page
/// only shows it.
///
/// The page says nothing that Mossad does not know. A person is known only on a sure match
/// (`PersonDirectory.link`): a wrong person's history before a meeting is worse than none. An action item has
/// no state of its own, so only the owner's own tasks say "open" or "done"; another person's item has no state.
/// A number that the history cannot give is nil, never 0.
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

    /// An invited person Mossad knows. The meetings are the recorded ones in which their voice has their name:
    /// a meeting where they were silent, or a voice with no name, is not counted.
    public struct Person: Sendable, Equatable, Identifiable {
        public var id: String { name }
        public var name: String
        /// Nil for a saved person who never spoke in a recorded meeting.
        public var lastMet: Earlier?
        /// Such meetings in the last `recentDays` days.
        public var recent: Int
        /// Such meetings in all.
        public var meetings: Int
        public var fact: Fact?
    }

    /// An action item of the last meeting.
    public struct Item: Sendable, Equatable, Identifiable {
        public enum State: Sendable, Equatable { case open, done }

        public var id: String
        public var task: String
        /// The owner as the meeting wrote it; nil for an item with no owner.
        public var owner: String?
        /// The saved person the written owner surely is. Nil for the note's owner, whose items read "You".
        public var person: String?
        /// True for an item of the note's owner.
        public var isOwners: Bool
        /// Known only for an item that is one of the owner's tasks from the same call. Nil says "not known",
        /// which is every other person's item.
        public var state: State?
        public var callID: String
        /// The second of the call to play from. Nil when the task has no moment and no line says the item.
        public var at: TimeInterval?
        /// True for the moment of the owner's task. False for a line that holds the item's words, which the page
        /// calls "about".
        public var atIsExact: Bool
        /// The owner's task that is this item, which the page can mark done.
        public var commitment: Commitment?
    }

    /// One of the owner's open tasks for the people of this meeting.
    public struct Promise: Sendable, Equatable, Identifiable {
        public var id: UUID { commitment.id }
        public var commitment: Commitment
        /// The saved person it was promised to, when the written name is surely theirs.
        public var person: String?
        /// True when the task's meeting is still there and the task has a moment in it to play.
        public var playable: Bool
    }

    public struct LastTime: Sendable, Equatable {
        public var meeting: Earlier
        /// False when the invite has no series and this is the last meeting with its people.
        public var inSeries: Bool
        /// With no series: the invited people who spoke in it.
        public var with: [String]
        /// False for a meeting with no summary: its decisions and action items are not known, not none.
        public var hasSummary: Bool
        public var headline: String?
        public var decisions: [Decision]
        public var moreDecisions: Int
        public var items: [Item]
        public var moreItems: Int
        /// The items on the page and behind "and N more".
        public var total: Int { items.count + moreItems }
        /// Every action item of the meeting: those and the ones left off.
        public var all: Int { total + absent }
        /// Of all of them: the note owner's, the ones known to be open, and the ones known to be done.
        public var owners: Int
        public var ownersOpen: Int
        public var ownersDone: Int
        /// Items left off because their owner is one person, named by the meeting, who is surely not invited. The
        /// page says how many.
        public var absent: Int
    }

    /// An earlier meeting of the series in one line.
    public struct Recap: Sendable, Equatable, Identifiable {
        public var id: String
        public var start: Date
        /// The meeting's headline, or its title when it has none.
        public var line: String
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
        /// The meetings before the last one, newest first, and how many more there are.
        public var earlier: [Recap]
        public var moreEarlier: Int
    }

    public var invited: [Invited]
    public var people: [Person]
    public var lastTime: LastTime?
    /// The owner's open tasks for these people from any meeting, oldest first.
    public var promises: [Promise]
    public var morePromises: Int
    /// How many of all of them are open: a task marked done on the page stays as a row and is not counted.
    public var openPromises: Int
    /// False when the tasks could not be read: then no item has a state and there are no promises, and the page
    /// says so instead of "no tasks".
    public var tasksKnown: Bool
    /// False for the page's first step, made before the history of talk was read: no person has a fact and the
    /// series has no usual numbers yet.
    public var hasFacts: Bool
    public var series: Series?
    /// The kind of the series, such as "Weekly sync": its last meeting's.
    public var kind: String?
    public var coach: PrepCoach

    /// At most this many decisions, items, and promises; the rest is a number and a link.
    public static let shown = 5
    public static let recentDays = 90.0
    /// One earlier meeting is a last time, not yet a series.
    static let seriesMinimum = 2
    static let trendPoints = 12
    /// An interval between meetings is said in the present only while the last meeting is this many intervals old
    /// at most.
    static let staleIntervals = 3.0

    /// `records` and `facts` may hold every meeting: only the written ones that began before this one count.
    /// `facts` is nil before the history of talk is read, and `commitments` is nil when the tasks cannot be read.
    /// `keep` are tasks that were marked done on the page, which stay on it. `ownerEmails` are the owner's own
    /// addresses, when known.
    public init(meeting: UpcomingMeeting, owner: String, records: [CallRecord], facts: [MeetingFacts]?, commitments: [Commitment]?,
                people directory: PersonDirectory, coach: [String: CoachPerson] = [:], ownerEmails: [String] = [], keep: Set<UUID> = [],
                now: Date = Date()) {
        let invited = Self.invited(meeting.attendees, owner: owner, directory: directory, ownerEmails: ownerEmails)
        self.invited = invited
        tasksKnown = commitments != nil
        hasFacts = facts != nil
        let known = invited.compactMap(\.person)
        let past = records.filter { $0.status == .written && $0.start < meeting.start }.sorted { $0.start > $1.start }
        let history = facts?.filter { $0.start < meeting.start }.sorted { $0.start > $1.start }

        let series = Self.series(of: meeting, invited: invited, in: past, owner: owner, directory: directory, ownerEmails: ownerEmails)
        let seriesIDs = Set(series.map(\.id))
        self.series = Self.series(series, facts: history?.filter { seriesIDs.contains($0.id) } ?? [])
        kind = series.first?.kind?.nonBlank

        let size = MeetingFacts.Size(voices: invited.count + 1)
        let since = now.addingTimeInterval(-Self.recentDays * 86_400)
        self.people = known.map { name in
            let shared = past.filter { $0.speakerNames.values.contains(name) }
            return Person(name: name, lastMet: shared.first.map(Earlier.init), recent: shared.filter { $0.start >= since }.count, meetings: shared.count,
                          fact: history.flatMap { Self.fact(about: name, in: $0, series: seriesIDs, size: size, met: shared.map(\.start), now: now) })
        }

        let people = Invite(invited)
        let last = series.first.map { ($0, [String]()) } ?? Self.lastMeeting(with: known, of: invited.count, in: past)
        var used: Set<UUID> = []
        if let (record, with) = last {
            let all = Self.items(of: record, owner: owner, invite: people, directory: directory, commitments: commitments ?? [])
            used = Set(all.items.compactMap(\.commitment?.id))
            lastTime = LastTime(meeting: Earlier(record), inSeries: !series.isEmpty, with: with, hasSummary: record.summary != nil,
                                headline: record.headline?.nonBlank,
                                decisions: Array(record.decisions.prefix(Self.shown)), moreDecisions: max(0, record.decisions.count - Self.shown),
                                items: Self.withMoments(Array(all.items.prefix(Self.shown)), in: record), moreItems: max(0, all.items.count - Self.shown),
                                owners: all.items.filter(\.isOwners).count, ownersOpen: all.items.filter { $0.state == .open }.count,
                                ownersDone: all.items.filter { $0.state == .done }.count, absent: all.absent)
        } else {
            lastTime = nil
        }

        let byID = Dictionary(past.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let promises = Self.promises(commitments ?? [], invite: people, calls: byID, series: seriesIDs, used: used, keep: keep, owner: owner, directory: directory)
        self.promises = promises.prefix(Self.shown).map { c in
            Promise(commitment: c, person: c.to.flatMap { directory.link(for: $0) }, playable: c.at != nil && c.callID.map { byID[$0] != nil } == true)
        }
        morePromises = max(0, promises.count - Self.shown)
        openPromises = promises.filter { $0.done == nil }.count
        self.coach = PrepCoach(people: known, coach: coach)
    }

    // MARK: In one line

    /// What is known before this meeting, in one or two sentences: how many action items the last time had and
    /// which of the owner's are open, and the owner's open tasks for these people. Another person's item is
    /// counted and never called open, and an item that is not on the page is counted as "not for this meeting".
    /// Nil with no earlier meeting and nothing owed.
    public var inOneLine: String? {
        let one = invited.count == 1 ? invited[0].name : nil
        let who = one.map { $0.contains("@") ? "this person" : String($0.split(separator: " ").first ?? Substring($0)) } ?? "these people"
        let owed = openPromises
        let tasks = owed == 0 ? nil : "You have \(owed) open \(owed == 1 ? "task" : "tasks") for \(who)."
        guard let last = lastTime else { return tasks }
        let from = last.inSeries ? "Last time" : "Your last meeting with \(who)"
        func joined(_ sentence: String) -> String { tasks.map { "\(sentence) \($0)" } ?? sentence }
        guard last.hasSummary else { return joined("\(from) has no summary.") }
        // Every item of the meeting is counted, also the ones that are not on the page.
        let n = last.all
        guard n > 0 else { return joined("\(from) had no action items.") }
        let away = last.absent > 0 ? ", \(last.absent) not for this meeting" : ""
        var yours = ""
        if last.owners > 0 {
            // The state is said only when every one of the owner's items has the same known state.
            let state = last.ownersOpen == last.owners ? " and still open" : last.ownersDone == last.owners ? " and done" : ""
            let mixed = state.isEmpty && last.ownersOpen > 0 ? ", \(last.ownersOpen) still open" : ""
            yours = last.owners == n ? (n == 1 ? ", yours\(state)" : ", all yours\(state)\(mixed)") : ", \(last.owners) of them yours\(state)\(mixed)"
        }
        return joined("\(from): \(n) action \(n == 1 ? "item" : "items")\(yours)\(away).")
    }

    // MARK: Invited

    /// The invite's entries without the owner, one per person: a person invited by name and by email is one entry.
    ///
    /// The owner's own entry is their saved profile, their name, or one of their addresses. With no address of
    /// theirs known, an address of nobody saved that fits their whole name is theirs; a first name alone is not
    /// enough, and an address that fits is never theirs when it is a saved person's.
    public static func invited(_ attendees: [String], owner: String, directory: PersonDirectory, ownerEmails: [String] = []) -> [Invited] {
        let names = attendees.filter { !$0.contains("@") }
        let same = { (name: String) in PeopleDuplicates.normalized(name) == PeopleDuplicates.normalized(owner) }
        let own = Set((ownerEmails + directory.people.filter { same($0.name) }.compactMap(\.email)).map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty })
        var seen: Set<String> = []
        var out: [Invited] = []
        for a in attendees {
            let written = a.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !written.isEmpty else { continue }
            let person = directory.link(for: written, in: names)
            if person.map(same) == true || same(written) { continue }
            if written.contains("@"), person == nil, own.isEmpty ? fitsWholeName(written, of: owner) : own.contains(written.lowercased()) { continue }
            let name = person ?? written
            guard seen.insert(PeopleDuplicates.normalized(name)).inserted else { continue }
            out.append(Invited(written: written, name: name, person: person))
        }
        return out
    }

    /// `CalendarInfo.isOwnersAddress` without the form that is the first name alone: "dana@" is many people.
    static func fitsWholeName(_ address: String, of owner: String) -> Bool {
        let first = owner.lowercased().split(separator: " ").first.map(String.init) ?? ""
        let local = address.lowercased().split(separator: "@").first.map { $0.replacingOccurrences(of: ".", with: "").replacingOccurrences(of: "_", with: "") } ?? ""
        return local != first && CalendarInfo.isOwnersAddress(address, ownerName: owner)
    }

    // MARK: The people

    /// One line about the owner and `name`, from the meetings before this one (`history`, newest first).
    ///
    /// Before a 1:1: the owner's usual part of the talk in their 1:1s. Before a group: the person's usual part in
    /// this series (the meetings `series`), then in meetings of this size, then the 1:1s. A talk share follows the size of a meeting, so
    /// meetings of other sizes say nothing about it. With too few of each: how often the two meet, while they
    /// still do (the last meeting is not older than `staleIntervals` of their usual interval).
    static func fact(about name: String, in history: [MeetingFacts], series: Set<String>, size: MeetingFacts.Size, met: [Date], now: Date) -> Fact? {
        typealias A = MeetingAnalytics
        func usual(_ values: [Double]) -> A.Usual? { A.Usual(Array(values.prefix(A.History.limit))) }
        /// "Usually talks 30 to 40% of the time in this series", or, from fewer than five meetings, "Talked 30
        /// to 40% of the time in this series, 3 meetings so far".
        func fact(_ u: A.Usual, usually: String, did: String, _ place: String) -> Fact {
            let range = MeetingFindings.range(.talkShare, u)
            return Fact(text: u.isFirm ? "\(usually) \(range) of the time \(place)" : "\(did) \(range) of the time \(place), \(u.samples) meetings so far",
                        basis: MeetingFindings.basis(u))
        }

        let oneOnOne = usual(history.filter { $0.partner?.name == name }.compactMap { $0.owner?.values[.talkShare] })
            .map { fact($0, usually: "You usually talk", did: "You talked", "in your 1:1s") }
        if size == .oneOnOne, let oneOnOne { return oneOnOne }
        if size != .oneOnOne {
            let groups = history.filter { $0.partner == nil && $0.owner != nil }
            if let u = usual(groups.filter { series.contains($0.id) }.compactMap { $0.person(name)?.values[.talkShare] }) {
                return fact(u, usually: "Usually talks", did: "Talked", "in this series")
            }
            if let u = usual(groups.filter { $0.size == size }.compactMap { $0.person(name)?.values[.talkShare] }) {
                return fact(u, usually: "Usually talks", did: "Talked", "in meetings of \(size.words)")
            }
            if let oneOnOne { return oneOnOne }
        }
        // The same number as a person's profile: the average time from one meeting to the next.
        let dates = met.sorted()
        guard dates.count >= A.Usual.minimumSamples, let first = dates.first, let last = dates.last else { return nil }
        let interval = last.timeIntervalSince(first) / Double(dates.count - 1)
        guard now.timeIntervalSince(last) <= max(interval, 86_400) * staleIntervals else { return nil }
        let days = max(1, Int((interval / 86_400).rounded()))
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
                      lengths: lengths.prefix(trendPoints).reversed(), shares: shares.prefix(trendPoints).reversed(),
                      earlier: records.dropFirst().prefix(shown).map { Recap(id: $0.id, start: $0.start, line: $0.headline?.nonBlank ?? $0.title) },
                      moreEarlier: max(0, records.count - 1 - shown))
    }

    /// Two lists of people are "nearly the same" at this overlap: the people on both lists over the people on
    /// either. Five of six pass; one of two does not.
    static let sameSeries = 0.8

    /// The earlier meetings of this invite's series, newest first.
    ///
    /// A title alone is not a series: two invites named "1:1" are two series, and an "Interview" has a new
    /// candidate each time. A meeting belongs when it has this title (from the calendar or the owner, as in
    /// `MeetingFacts.series`) and one of these holds:
    /// - It ran on this invite's link, and at least one of the invited people was invited to it or spoke in it.
    ///   A personal room with other people is another meeting.
    /// - Its people are nearly this invite's people (`sameSeries`), counted both ways: a large meeting is not the
    ///   series of a small invite. Its invite list is compared with this one; a meeting with no list kept has
    ///   only its voices.
    /// With no people to compare on one side, the title decides, unless both links are known and differ.
    static func series(of meeting: UpcomingMeeting, invited: [Invited], in past: [CallRecord], owner: String, directory: PersonDirectory,
                       ownerEmails: [String] = []) -> [CallRecord] {
        let key = PeopleDuplicates.normalized(meeting.title)
        let link = meeting.link.map { ($0.absoluteString.removingPercentEncoding ?? $0.absoluteString).lowercased() }
        return past.filter { r in
            guard r.titleSource == .calendar || r.titleSource == .custom, PeopleDuplicates.normalized(r.title) == key else { return false }
            let listed = Set(Self.invited(r.attendees, owner: owner, directory: directory, ownerEmails: ownerEmails).map { PeopleDuplicates.normalized($0.name) })
            let voices = Set(r.speakerNames.values.filter { !$0.hasPrefix("Speaker ") && PeopleDuplicates.normalized($0) != PeopleDuplicates.normalized(owner) }
                .map(PeopleDuplicates.normalized))
            let there = listed.isEmpty ? voices : listed
            // An address of nobody saved can only be found among the addresses of the other invite.
            let ours = Set(invited.filter { $0.person != nil || !$0.written.contains("@") || !listed.isEmpty }.map { PeopleDuplicates.normalized($0.name) })
            // Nil when one side has no link to compare.
            let sameLink = r.meetingID.flatMap { id in link.map { $0.contains(id.lowercased()) } }
            guard !ours.isEmpty, !there.isEmpty else { return sameLink != false }
            if sameLink == true, !ours.isDisjoint(with: listed.union(voices)) { return true }
            return Double(ours.intersection(there).count) / Double(ours.union(there).count) >= sameSeries
        }
    }

    /// With no series: the last meeting in which the known invited people spoke, and who of them did. They must
    /// be at least half of the invite, and all of them when they are one or two: a meeting with one of five
    /// invited people is not "your last meeting with these people".
    static func lastMeeting(with known: [String], of invited: Int, in past: [CallRecord]) -> (CallRecord, [String])? {
        guard !known.isEmpty else { return nil }
        let needed = max((invited + 1) / 2, known.count <= 2 ? known.count : 0)
        for r in past {
            let spoke = Set(r.speakerNames.values)
            let with = known.filter(spoke.contains)
            if with.count >= needed { return (r, with) }
        }
        return nil
    }
}
