import XCTest
@testable import MossadCore

/// What the page of an upcoming meeting shows: the invited people, what is known about them, the last meeting's
/// open items, the owner's open promises, and the series in numbers.
final class MeetingPrepTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let owner = "Dana Lee"
    private let sam = "Sam Carter"
    private let jo = "Jo Park"

    // MARK: Helpers

    private var directory: PersonDirectory {
        PersonDirectory([.init(name: owner, email: "dana@example.com"), .init(name: sam, email: "sam.carter@example.com"),
                         .init(name: jo, email: nil), .init(name: "Riley Chen", email: nil)])
    }

    private func upcoming(_ title: String = "Weekly sync", attendees: [String] = ["dana@example.com", "Sam Carter", "Jo Park"]) -> UpcomingMeeting {
        UpcomingMeeting(title: title, start: now.addingTimeInterval(1800), end: now.addingTimeInterval(3600), attendees: attendees, platform: .meet,
                        link: URL(string: "https://meet.google.com/abc-defg-hij"))
    }

    private func call(_ id: String, daysAgo: Double, title: String? = "Weekly sync", minutes: Double = 30, speakers: [String] = ["Dana Lee", "Sam Carter", "Jo Park"],
                      items: [ActionItem] = [], decisions: [Decision] = [], headline: String? = nil, planned: (late: Double, over: Double)? = nil,
                      lines: [(Int, Double, String)] = []) -> CallRecord {
        let start = now.addingTimeInterval(-daysAgo * 86_400)
        var r = CallRecord(id: id, platform: .meet, bundleID: "", start: start, end: start.addingTimeInterval(minutes * 60), status: .written)
        r.calendarTitle = title
        for (i, name) in speakers.enumerated() { r.speakerNames[i == 0 ? "me:A" : "them:\(i)"] = name }
        r.summary = "A summary."
        r.actionItems = items
        r.decisions = decisions
        r.headline = headline
        if let planned {
            r.plannedStart = start.addingTimeInterval(-planned.late * 60)
            r.plannedEnd = r.end.addingTimeInterval(-planned.over * 60)
        }
        r.utterances = lines.map { speaker, at, text in
            Utterance(track: speaker == 0 ? .me : .them, speakerLabel: speaker == 0 ? "A" : "\(speaker)", start: at, end: at + 10, text: text)
        }
        return r
    }

    private func facts(_ id: String, daysAgo: Double, title: String? = "Weekly sync", minutes: Double = 30, shares: [(String, Double)]) -> MeetingFacts {
        MeetingFacts(id: id, stamp: 0, start: now.addingTimeInterval(-daysAgo * 86_400), title: title ?? "Meet call",
                     series: title.map(PeopleDuplicates.normalized), kind: nil, tags: [], voices: shares.count,
                     people: shares.map { MeetingFacts.Person(name: $0.0, isOwner: $0.0 == owner, values: [.talkShare: $0.1]) },
                     values: [.length: minutes * 60])
    }

    private func promise(_ text: String, to: String?, daysAgo: Double, call: String? = "c1", at: TimeInterval? = 60, done: Bool = false) -> Commitment {
        var c = Commitment(text: text, to: to, callID: call, callTitle: "Weekly sync", madeAt: now.addingTimeInterval(-daysAgo * 86_400), at: at,
                           due: nil, created: now.addingTimeInterval(-daysAgo * 86_400))
        if done { c.done = now }
        return c
    }

    private func prep(_ meeting: UpcomingMeeting? = nil, records: [CallRecord] = [], facts: [MeetingFacts] = [], commitments: [Commitment] = [],
                      coach: [String: CoachPerson] = [:]) -> MeetingPrep {
        MeetingPrep(meeting: meeting ?? upcoming(), owner: owner, records: records, facts: facts, commitments: commitments, people: directory,
                    coach: coach, now: now)
    }

    // MARK: Invited

    func testTheInvitedPeopleLeaveTheOwnerOutAndKnowOnlyASureMatch() {
        let p = prep(upcoming(attendees: ["dana@example.com", "sam.carter@example.com", "Jo Park", "Riley", "morgan@example.com"]))
        XCTAssertEqual(p.invited.map(\.name), ["Sam Carter", "Jo Park", "Riley", "morgan@example.com"])
        // A first name is not a sure match, and nobody is saved with the last address.
        XCTAssertEqual(p.invited.map(\.person), ["Sam Carter", "Jo Park", nil, nil])
        XCTAssertEqual(p.people.map(\.name), ["Sam Carter", "Jo Park"])
    }

    func testOnePersonInvitedByNameAndByEmailIsOneEntryAndTheOwnersAddressIsTheOwner() {
        let p = prep(upcoming(attendees: ["Sam Carter", "sam.carter@example.com", "dlee@other.example", "Dana Lee"]))
        XCTAssertEqual(p.invited.map(\.name), ["Sam Carter"])
    }

    // MARK: The people

    func testAPersonRowSaysWhenYouLastMetAndHowOftenInNinetyDays() {
        var running = call("live", daysAgo: 0.01, speakers: [owner, sam])
        running.status = .recording
        let records = [call("old", daysAgo: 200, speakers: [owner, sam]), call("a", daysAgo: 40, title: "Budget", speakers: [owner, sam, jo]),
                       call("b", daysAgo: 6, title: "Dana / Sam", speakers: [owner, sam]), running]
        let p = prep(records: records)
        let s = p.people[0], j = p.people[1]
        XCTAssertEqual(s.lastMet?.id, "b")
        XCTAssertEqual(s.lastMet?.title, "Dana / Sam")
        XCTAssertEqual(s.recent, 2)
        XCTAssertEqual(s.meetings, 3)
        XCTAssertEqual(j.lastMet?.id, "a")
        XCTAssertEqual(j.recent, 1)
        // A saved person the owner has never met in a recorded call.
        let riley = prep(upcoming(attendees: ["Riley Chen"]), records: records).people[0]
        XCTAssertNil(riley.lastMet)
        XCTAssertEqual(riley.meetings, 0)
        XCTAssertNil(riley.fact)
    }

    func testTheFactOfAOneOnOneIsTheOwnersUsualTalkShareWithThem() {
        let history = [0.67, 0.65, 0.64, 0.66, 0.63, 0.65].enumerated().map { i, share in
            facts("o\(i)", daysAgo: Double(i + 1) * 7, title: "Catch up \(i)", shares: [(owner, share), (sam, 1 - share)])
        }
        let p = prep(upcoming("Dana / Sam", attendees: ["Sam Carter"]), facts: history)
        XCTAssertEqual(p.people[0].fact?.text, "You usually talk 63 to 67% of the time in your 1:1s")
        XCTAssertEqual(p.people[0].fact?.basis, "from 6 meetings")
        // Three meetings give a range, but not "usually".
        let few = prep(upcoming("Dana / Sam", attendees: ["Sam Carter"]), facts: Array(history.prefix(3)))
        XCTAssertEqual(few.people[0].fact?.text, "You talked 64 to 67% of the time in your 1:1s, 3 meetings so far")
        XCTAssertNil(prep(upcoming("Dana / Sam", attendees: ["Sam Carter"]), facts: Array(history.prefix(2))).people[0].fact)
    }

    func testTheFactOfAGroupIsTheirShareInTheSeriesThenInMeetingsOfThisSize() {
        // Three invited people and the owner: meetings of 3 to 4 people. A 1:1 and a large meeting say nothing about it.
        var history = [0.42, 0.45, 0.48, 0.44, 0.46].enumerated().map { i, share in
            facts("g\(i)", daysAgo: Double(i + 1) * 7, title: "Planning", shares: [(owner, 0.3), (sam, share), (jo, 0.7 - share)])
        }
        history.append(facts("one", daysAgo: 3, title: "Dana / Sam", shares: [(owner, 0.2), (sam, 0.8)]))
        history.append(facts("big", daysAgo: 4, title: "All hands", shares: [(owner, 0.1), (sam, 0.1), (jo, 0.1), ("A B", 0.1), ("C D", 0.1), ("E F", 0.1), ("G H", 0.4)]))
        let invited = ["Sam Carter", "Jo Park", "Riley Chen"]
        let p = prep(upcoming("A new meeting", attendees: invited), facts: history)
        XCTAssertEqual(p.people[0].fact?.text, "Usually talks 42 to 48% of the time in meetings of 3 to 4 people")
        // Riley never spoke in a meeting: no fact.
        XCTAssertNil(p.people[2].fact)
        // The series itself says more than the size: its meetings can have fewer voices than the invite has people.
        history += [0.20, 0.22, 0.24].enumerated().map { i, share in
            facts("s\(i)", daysAgo: Double(i + 1) * 5, title: "All hands", shares: [(owner, 0.1), (sam, share), (jo, 0.2), ("A B", 0.1), ("C D", 0.1), ("E F", 0.1)])
        }
        let series = prep(upcoming("All hands", attendees: invited), facts: history)
        XCTAssertEqual(series.people[0].fact?.text, "Talked 10 to 24% of the time in this series, 4 meetings so far")
        // With no meetings of this size or series: the 1:1s, then how often the two meet.
        let records = (1...4).map { call("m\($0)", daysAgo: Double($0) * 14, title: "Other \($0)", speakers: [owner, sam]) }
        let rare = prep(upcoming("A new meeting", attendees: invited), records: records, facts: Array(history.suffix(4).prefix(1)))
        XCTAssertEqual(rare.people[0].fact?.text, "You meet about every 14 days")
        XCTAssertEqual(rare.people[0].fact?.basis, "from 4 meetings")
    }

    // MARK: Last time

    func testLastTimeIsTheLastMeetingOfTheSeriesWithItsHeadlineAndDecisions() {
        let records = [
            call("c1", daysAgo: 14, headline: "Older."),
            call("c2", daysAgo: 7, decisions: [Decision(text: "Keep the vendor", at: 300)], headline: "The checkout ships before the freeze."),
            call("x", daysAgo: 1, title: "Budget review", headline: "Another meeting."),
        ]
        let last = prep(records: records).lastTime
        XCTAssertEqual(last?.meeting.id, "c2")
        XCTAssertEqual(last?.inSeries, true)
        XCTAssertEqual(last?.headline, "The checkout ships before the freeze.")
        XCTAssertEqual(last?.decisions, [Decision(text: "Keep the vendor", at: 300)])
    }

    func testATitleFromTheModelMakesNoSeries() {
        var named = call("g", daysAgo: 3, title: nil, speakers: [owner, "Morgan Diaz"])
        named.generatedTitle = "Weekly sync"
        XCTAssertNil(prep(records: [named]).lastTime)
    }

    func testWithNoSeriesLastTimeIsTheLastMeetingWithThesePeople() {
        let records = [
            call("both", daysAgo: 20, title: "Planning", speakers: [owner, sam, jo, "Riley Chen"]),
            call("sam", daysAgo: 5, title: "Dana / Sam", speakers: [owner, sam]),
            call("none", daysAgo: 2, title: "Hiring", speakers: [owner, "Morgan Diaz"]),
        ]
        let last = prep(upcoming("A new meeting"), records: records).lastTime
        XCTAssertEqual(last?.meeting.id, "both")
        XCTAssertEqual(last?.inSeries, false)
        // With one known person, their last meeting of any size.
        XCTAssertEqual(prep(upcoming("A new meeting", attendees: ["Sam Carter"]), records: records).lastTime?.meeting.id, "sam")
        // Nobody known: nothing to go on.
        XCTAssertNil(prep(upcoming("A new meeting", attendees: ["morgan@example.com"]), records: records).lastTime)
    }

    func testOnlyOpenItemsOfThePeopleInThisMeetingAndOfTheOwner() {
        let items = [ActionItem(owner: "Morgan Diaz", task: "Check the freeze dates with support"), ActionItem(owner: nil, task: "Find a room for the planning day"),
                     ActionItem(owner: "Sam", task: "Send the revised budget to finance"), ActionItem(owner: "Dana Lee", task: "Write the hiring plan for the migration"),
                     ActionItem(owner: "Dana Lee", task: "Send Jo the freeze dates"), ActionItem(owner: "Jo Park", task: "Move the review to Thursday")]
        let done = promise("Send Jo the freeze dates", to: nil, daysAgo: 7, done: true)
        var dropped = promise("Write the plan for hiring", to: nil, daysAgo: 7, call: "other")
        dropped.done = now
        let last = prep(records: [call("c1", daysAgo: 7, items: items)], commitments: [done, dropped]).lastTime
        // The owner's first, then the invited people's in the meeting's order, then the ones with no owner. Morgan
        // is not invited, and the owner's second item is a task that is done.
        XCTAssertEqual(last?.items.map(\.task), ["Write the hiring plan for the migration", "Send the revised budget to finance", "Move the review to Thursday",
                                                 "Find a room for the planning day"])
        XCTAssertEqual(last?.items.map(\.isOwners), [true, false, false, false])
        // "Sam" is one of the people, but a first name is not a link.
        XCTAssertEqual(last?.items.map(\.owner), ["Dana Lee", "Sam", "Jo Park", nil])
        XCTAssertEqual(last?.items.map(\.person), [nil, nil, "Jo Park", nil])
        XCTAssertEqual(last?.ownersOpen, 1)
    }

    func testAnItemWithAnOpenTaskCarriesTheTasksMomentAndIsNotAPromiseAsWell() {
        let task = promise("Write the hiring plan for the migration", to: "Sam", daysAgo: 7, at: 2415)
        let other = promise("Send Sam the forecast", to: "Sam Carter", daysAgo: 30, call: "older", at: 12)
        let p = prep(records: [call("c1", daysAgo: 7, items: [ActionItem(owner: "Dana", task: "Write the hiring plan for the migration")])],
                     commitments: [task, other])
        XCTAssertEqual(p.lastTime?.items.map(\.at), [2415])
        XCTAssertEqual(p.lastTime?.items.map(\.commitment?.id), [task.id])
        XCTAssertEqual(p.promises.map(\.commitment.text), ["Send Sam the forecast"])
        // A whole name is a link; the item's task was promised to "Sam", which is not one.
        XCTAssertEqual(p.promises.map(\.person), ["Sam Carter"])
    }

    func testAnItemsMomentIsTheLineThatSaysIt() {
        let lines: [(Int, Double, String)] = [
            (0, 10, "Let us look at the budget and the dates."),
            (1, 120, "I will send the revised budget over to finance by Friday, that is fine."),
            (2, 200, "The review moves, yes."),
        ]
        let items = [ActionItem(owner: "Sam Carter", task: "Send the revised budget to finance by Friday"), ActionItem(owner: "Jo Park", task: "Check the numbers with the vendor")]
        let last = prep(records: [call("c1", daysAgo: 7, items: items, lines: lines)]).lastTime
        // The second item's words are in no line: no moment, rather than a guess.
        XCTAssertEqual(last?.items.map(\.at), [120, nil])
    }

    func testInALongTurnTheMomentIsWhereTheItemsWordsBegin() {
        // Two minutes of one turn; the item is said 90 s into it.
        var r = call("c1", daysAgo: 7, items: [ActionItem(owner: "Sam Carter", task: "Send the revised budget to finance")])
        let opening = (0..<30).map { Word(text: "so", start: 100 + Double($0) * 3, end: 101 + Double($0) * 3) }
        let said = ["I", "will", "send", "the", "revised", "budget", "to", "finance."].enumerated().map { i, w in
            Word(text: w, start: 190 + Double(i), end: 190.5 + Double(i))
        }
        r.utterances = [Utterance(track: .them, speakerLabel: "1", start: 100, end: 220, text: (opening + said).map(\.text).joined(separator: " "), words: opening + said)]
        // A little before the first of its words, so the sentence is heard from its start.
        XCTAssertEqual(prep(records: [r]).lastTime?.items.map(\.at), [190])
    }

    func testAtMostFiveOfEachAndTheNumberOfTheRest() {
        let items = (1...8).map { ActionItem(owner: "Sam Carter", task: "Task number \($0)") }
        let decisions = (1...7).map { Decision(text: "Decision \($0)", at: Double($0)) }
        let promises = (1...6).map { promise("Promise \($0)", to: "Jo Park", daysAgo: Double($0), call: "p\($0)") }
        let p = prep(records: [call("c1", daysAgo: 7, items: items, decisions: decisions)], commitments: promises)
        XCTAssertEqual(p.lastTime?.items.count, 5)
        XCTAssertEqual(p.lastTime?.moreItems, 3)
        XCTAssertEqual(p.lastTime?.decisions.count, 5)
        XCTAssertEqual(p.lastTime?.moreDecisions, 2)
        XCTAssertEqual(p.promises.count, 5)
        XCTAssertEqual(p.morePromises, 1)
    }

    // MARK: In one line

    func testThePageOpensWithWhatIsOpenInOneLine() {
        let items = [ActionItem(owner: "Dana Lee", task: "Write the hiring plan"), ActionItem(owner: "Sam Carter", task: "Update the roadmap"),
                     ActionItem(owner: "Jo Park", task: "Check the numbers"), ActionItem(owner: nil, task: "Find a room")]
        let promises = (1...3).map { promise("Promise \($0)", to: "Jo Park", daysAgo: Double($0), call: "p\($0)") }
        XCTAssertEqual(prep(records: [call("c1", daysAgo: 7, items: items)], commitments: promises).inOneLine,
                       "4 items are open from last time, 1 of them yours. You have 3 open tasks for these people.")
        // With no series, and one person: say which meeting, and for whom.
        let one = prep(upcoming("A new meeting", attendees: ["Sam Carter"]),
                       records: [call("c1", daysAgo: 7, title: "Dana / Sam", speakers: [owner, sam], items: [ActionItem(owner: "Dana", task: "Write the hiring plan")])],
                       commitments: [promise("Send the forecast", to: "Sam", daysAgo: 9, call: "old")])
        XCTAssertEqual(one.inOneLine, "1 item is open from your last meeting with Sam; it is yours. You have 1 open task for Sam.")
        XCTAssertEqual(prep(records: [call("c1", daysAgo: 7)]).inOneLine, "Nothing is open from last time, and you have no open tasks for these people.")
        XCTAssertEqual(prep(commitments: promises).inOneLine, "You have 3 open tasks for these people.")
        // No earlier meeting and nothing owed: the page has no line to open with.
        XCTAssertNil(prep().inOneLine)
    }

    func testTheKindOfTheSeriesIsItsLastMeetings() {
        var last = call("c2", daysAgo: 7)
        last.kind = "Weekly sync"
        XCTAssertEqual(prep(records: [call("c1", daysAgo: 14), last]).kind, "Weekly sync")
        XCTAssertNil(prep(upcoming("A new meeting"), records: [last]).kind)
    }

    func testTheTimeUntilTheStartInWords() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        // 1_800_000_000 is a Friday at 08:00 UTC.
        func words(_ minutes: Double) -> String {
            var m = upcoming()
            m.start = now.addingTimeInterval(minutes * 60)
            m.end = m.start.addingTimeInterval(1800)
            return m.startsIn(now: now, calendar: calendar)
        }
        XCTAssertEqual(words(-5), "Now")
        XCTAssertEqual(words(0.5), "in 1 min")
        XCTAssertEqual(words(25), "in 25 min")
        XCTAssertEqual(words(200), "in 3 h 20 min")
        // Late tonight is still a number of hours; tomorrow afternoon is tomorrow.
        XCTAssertEqual(words(14 * 60), "in 14 h")
        XCTAssertEqual(words(30 * 60), "Tomorrow")
        XCTAssertEqual(words(3 * 24 * 60), "in 3 days")
    }

    // MARK: Promises

    func testThePromisesAreTheOpenOnesToThesePeopleOldestFirst() {
        var deleted = promise("Deleted", to: "Sam Carter", daysAgo: 50)
        deleted.deleted = true
        let all = [
            promise("Newer, to Jo", to: "Jo", daysAgo: 3, call: "a"), promise("Oldest, to Sam", to: "Sam Carter", daysAgo: 40, call: "b"),
            promise("Done", to: "Sam Carter", daysAgo: 45, call: "c", done: true), deleted,
            promise("To someone else", to: "Morgan Diaz", daysAgo: 60, call: "d"),
            promise("To nobody, in another meeting", to: nil, daysAgo: 20, call: "e"),
            promise("To nobody, in this series", to: nil, daysAgo: 7, call: "c1"),
        ]
        let p = prep(records: [call("c1", daysAgo: 7), call("e", daysAgo: 20, title: "Budget review")], commitments: all)
        XCTAssertEqual(p.promises.map(\.commitment.text), ["Oldest, to Sam", "To nobody, in this series", "Newer, to Jo"])
        XCTAssertEqual(p.promises.map(\.person), ["Sam Carter", nil, nil])
    }

    // MARK: The series

    func testTheSeriesAtAGlance() {
        let records = (1...6).map { i in
            call("c\(i)", daysAgo: Double(i) * 7, planned: (late: i == 2 ? 7 : 1, over: i <= 3 ? 9 : 0))
        } + [call("free", daysAgo: 49), call("other", daysAgo: 2, title: "Budget review")]
        let history = [0.30, 0.34, 0.32, 0.36, 0.31, 0.33].enumerated().map { i, share in
            facts("c\(i + 1)", daysAgo: Double(i + 1) * 7, minutes: 28 + Double(i), shares: [(owner, share), (sam, 0.4), (jo, 0.6 - share)])
        }
        let s = prep(records: records, facts: history).series
        XCTAssertEqual(s?.meetings, 7)
        XCTAssertEqual(s?.since, now.addingTimeInterval(-49 * 86_400))
        // One meeting has no planned times: the counts are out of the six that have them.
        XCTAssertEqual(s?.planned, 6)
        XCTAssertEqual(s?.ranOver, 3)
        XCTAssertEqual(s?.joinedLate, 1)
        XCTAssertEqual(s?.length?.median, 30.5 * 60)
        XCTAssertEqual(s?.ownerShare?.low, 0.30)
        XCTAssertEqual(s?.ownerShare?.high, 0.36)
        // Oldest first, as a line reads.
        XCTAssertEqual(s?.shares, [0.33, 0.31, 0.36, 0.32, 0.34, 0.30])
    }

    func testTheSeriesListsTheMeetingsBeforeTheLastOne() {
        let records = (1...8).map { call("c\($0)", daysAgo: Double($0) * 7, headline: $0 == 3 ? nil : "Headline \($0).") }
        let s = prep(records: records).series
        // "Last time" is c1. The next five follow, newest first; one with no headline shows its title.
        XCTAssertEqual(s?.earlier.map(\.id), ["c2", "c3", "c4", "c5", "c6"])
        XCTAssertEqual(s?.earlier.map(\.line), ["Headline 2.", "Weekly sync", "Headline 4.", "Headline 5.", "Headline 6."])
        XCTAssertEqual(s?.moreEarlier, 2)
    }

    func testOneEarlierMeetingIsNotASeriesYet() {
        XCTAssertNil(prep(records: [call("c1", daysAgo: 7)]).series)
        let two = prep(records: [call("c1", daysAgo: 7), call("c2", daysAgo: 14)]).series
        XCTAssertEqual(two?.meetings, 2)
        // Two meetings have no usual length.
        XCTAssertNil(two?.length)
        XCTAssertNil(two?.ownerShare)
    }

    // MARK: The coach

    func testTheCoachHasSomethingOnlyForInvitedPeopleItKnows() {
        var known = CoachPerson(note: "Likes the numbers first.", calls: 4, lastSeen: now)
        known.brief = PersonBrief(headline: "Lead with the decision, then the detail.", sections: [], calls: 4, updated: now)
        let coach = ["Sam Carter": known, "Morgan Diaz": CoachPerson(note: "Not invited.", calls: 2, lastSeen: now),
                     "Jo Park": CoachPerson(note: "  ", calls: 1, lastSeen: now)]
        let p = prep(coach: coach)
        XCTAssertEqual(p.coach.people.map(\.name), ["Sam Carter"])
        XCTAssertEqual(p.coach.people.first?.headline, "Lead with the decision, then the detail.")
        XCTAssertEqual(p.coach.people.first?.note, "Likes the numbers first.")
        XCTAssertTrue(prep().coach.isEmpty)
    }

    // MARK: Names

    func testAWrittenNameIsAFormOfAFullName() {
        XCTAssertTrue(PersonDirectory.isForm("Sam", of: "Sam Carter"))
        XCTAssertTrue(PersonDirectory.isForm("Sam C.", of: "Sam Carter"))
        XCTAssertTrue(PersonDirectory.isForm("sam carter", of: "Sam Carter"))
        XCTAssertFalse(PersonDirectory.isForm("Sam Reed", of: "Sam Carter"))
        XCTAssertFalse(PersonDirectory.isForm("Speaker A", of: "Sam Carter"))
        XCTAssertFalse(PersonDirectory.isForm("sam@example.com", of: "Sam Carter"))
        XCTAssertFalse(PersonDirectory.isForm("", of: "Sam Carter"))
    }

    func testTwoTasksAreTheSameWhenTheirWordsAre() {
        XCTAssertTrue(MeetingPrep.sameTask("Write the hiring plan for the migration", "Write hiring plan"))
        XCTAssertTrue(MeetingPrep.sameTask("Send the notes", "send notes."))
        XCTAssertFalse(MeetingPrep.sameTask("Send the notes", "Send Jo the freeze dates"))
        XCTAssertFalse(MeetingPrep.sameTask("Send", "Send the notes"))
    }
}
