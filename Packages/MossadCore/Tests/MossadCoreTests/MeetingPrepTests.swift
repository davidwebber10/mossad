import XCTest
@testable import MossadCore

/// What the page of an upcoming meeting shows: the invited people, what is known about them, the last meeting's
/// action items with the state that is known, the owner's open promises, and the series in numbers.
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
                      lines: [(Int, Double, String)] = [], attendees: [String] = [], meetingID: String? = nil) -> CallRecord {
        let start = now.addingTimeInterval(-daysAgo * 86_400)
        var r = CallRecord(id: id, platform: .meet, bundleID: "", start: start, end: start.addingTimeInterval(minutes * 60), status: .written)
        r.calendarTitle = title
        r.attendees = attendees
        r.meetingID = meetingID
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

    private func prep(_ meeting: UpcomingMeeting? = nil, records: [CallRecord] = [], facts: [MeetingFacts]? = [], commitments: [Commitment]? = [],
                      coach: [String: CoachPerson] = [:], people: PersonDirectory? = nil, keep: Set<UUID> = []) -> MeetingPrep {
        MeetingPrep(meeting: meeting ?? upcoming(), owner: owner, records: records, facts: facts, commitments: commitments, people: people ?? directory,
                    coach: coach, keep: keep, now: now)
    }

    // MARK: Invited

    func testTheInvitedPeopleLeaveTheOwnerOutAndKnowOnlyASureMatch() {
        let p = prep(upcoming(attendees: ["dana@example.com", "sam.carter@example.com", "Jo Park", "Riley", "morgan@example.com"]))
        XCTAssertEqual(p.invited.map(\.name), ["Sam Carter", "Jo Park", "Riley", "morgan@example.com"])
        // A first name is not a sure match, and nobody is saved with the last address.
        XCTAssertEqual(p.invited.map(\.person), ["Sam Carter", "Jo Park", nil, nil])
        XCTAssertEqual(p.people.map(\.name), ["Sam Carter", "Jo Park"])
    }

    func testOnePersonInvitedByNameAndByEmailIsOneEntry() {
        let p = prep(upcoming(attendees: ["Sam Carter", "sam.carter@example.com", "dana@example.com", "Dana Lee"]))
        XCTAssertEqual(p.invited.map(\.name), ["Sam Carter"])
    }

    func testOnlyTheOwnersOwnAddressIsTheOwner() {
        // The owner's address is known: an address that only looks like the owner's is another person.
        let known = prep(upcoming(attendees: ["dana@example.com", "dlee@other.example", "dana@vendor.example"]))
        XCTAssertEqual(known.invited.map(\.name), ["dlee@other.example", "dana@vendor.example"])
        // No address is known: one that fits the whole name is the owner's; a first name alone is not enough.
        let people = PersonDirectory([.init(name: owner, email: nil), .init(name: "Dan Lee", email: "dlee@vendor.example")])
        let guessed = prep(upcoming(attendees: ["dana.lee@example.com", "dana@vendor.example", "dlee@vendor.example"]), people: people)
        // The last address fits the owner's name too, but it is a saved person's.
        XCTAssertEqual(guessed.invited.map(\.name), ["dana@vendor.example", "Dan Lee"])
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
        // Meetings that stopped long ago say nothing about now.
        let old = (1...4).map { call("o\($0)", daysAgo: 300 + Double($0) * 14, title: "Other \($0)", speakers: [owner, sam]) }
        XCTAssertNil(prep(upcoming("A new meeting", attendees: invited), records: old, facts: []).people[0].fact)
    }

    func testWithoutTheHistoryOfTalkThePersonHasNoFactYet() {
        // The page's first step has no facts yet: it must not show a line that the second step replaces.
        let records = (1...4).map { call("m\($0)", daysAgo: Double($0) * 14, speakers: [owner, sam]) }
        let p = prep(upcoming(attendees: ["Sam Carter"]), records: records, facts: nil)
        XCTAssertNil(p.people[0].fact)
        XCTAssertEqual(p.people[0].meetings, 4)
        XCTAssertEqual(p.series?.meetings, 4)
        XCTAssertFalse(p.hasFacts)
        XCTAssertTrue(prep(records: records).hasFacts)
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

    func testWithNoSeriesLastTimeIsTheLastMeetingWithThesePeopleAndNamesThem() {
        let records = [
            call("both", daysAgo: 20, title: "Planning", speakers: [owner, sam, jo, "Riley Chen"]),
            call("sam", daysAgo: 5, title: "Dana / Sam", speakers: [owner, sam]),
            call("none", daysAgo: 2, title: "Hiring", speakers: [owner, "Morgan Diaz"]),
        ]
        let last = prep(upcoming("A new meeting"), records: records).lastTime
        XCTAssertEqual(last?.meeting.id, "both")
        XCTAssertEqual(last?.inSeries, false)
        XCTAssertEqual(last?.with, ["Sam Carter", "Jo Park"])
        // With one known person, their last meeting of any size.
        XCTAssertEqual(prep(upcoming("A new meeting", attendees: ["Sam Carter"]), records: records).lastTime?.meeting.id, "sam")
        // Nobody known: nothing to go on.
        XCTAssertNil(prep(upcoming("A new meeting", attendees: ["morgan@example.com"]), records: records).lastTime)
        // One known person of five is not "these people".
        let five = ["Sam Carter", "a@example.com", "b@example.com", "c@example.com", "d@example.com"]
        XCTAssertNil(prep(upcoming("A new meeting", attendees: five), records: records).lastTime)
    }

    // MARK: The series

    func testTwoSeriesWithOneTitleAreTwoSeries() {
        let withSam = (1...3).map { call("s\($0)", daysAgo: Double($0) * 7, title: "1:1", speakers: [owner, sam], headline: "With Sam.",
                                         attendees: ["dana@example.com", "sam.carter@example.com"]) }
        let withJo = (1...2).map { call("j\($0)", daysAgo: Double($0) * 7 + 1, title: "1:1", speakers: [owner, jo], headline: "With Jo.", attendees: ["Jo Park"]) }
        let forJo = prep(upcoming("1:1", attendees: ["dana@example.com", "Jo Park"]), records: withSam + withJo)
        XCTAssertEqual(forJo.lastTime?.meeting.id, "j1")
        XCTAssertEqual(forJo.lastTime?.headline, "With Jo.")
        XCTAssertEqual(forJo.series?.meetings, 2)
        let forSam = prep(upcoming("1:1", attendees: ["dana@example.com", "sam.carter@example.com"]), records: withSam + withJo)
        XCTAssertEqual(forSam.lastTime?.meeting.id, "s1")
        XCTAssertEqual(forSam.series?.meetings, 3)
        // An invite with this title for a person who was in none of them has no series.
        let forRiley = prep(upcoming("1:1", attendees: ["Riley Chen"]), records: withSam + withJo)
        XCTAssertNil(forRiley.series)
        XCTAssertNil(forRiley.lastTime)
    }

    func testTheSameLinkKeepsAMeetingThatFewOfTheInvitedPeopleSpokeIn() {
        // Five invited, and only Sam spoke: under half. The invite's own link says it is this series.
        let invited = ["Sam Carter", "Jo Park", "Riley Chen", "Casey Brooks", "Pat Ruiz"]
        let linked = call("linked", daysAgo: 7, speakers: [owner, sam], meetingID: "abc-defg-hij")
        let other = call("other", daysAgo: 14, speakers: [owner, sam], meetingID: "zzz-zzzz-zzz")
        let noLink = call("nolink", daysAgo: 21, speakers: [owner, sam])
        // The same room and title with none of these people (a personal room) is another meeting.
        let room = call("room", daysAgo: 3, speakers: [owner, "Morgan Diaz"], meetingID: "abc-defg-hij")
        let p = prep(upcoming(attendees: invited), records: [linked, other, noLink, room, call("second", daysAgo: 28, speakers: [owner, sam, jo, "Riley Chen"])])
        XCTAssertEqual(p.lastTime?.meeting.id, "linked")
        XCTAssertEqual(p.series?.meetings, 2)
    }

    func testAnInviteOfAddressesFindsItsSeriesByTheAddresses() {
        let addresses = ["dana@example.com", "pat@example.com", "kim@example.com"]
        let records = [call("c1", daysAgo: 7, speakers: [owner, "Pat Ruiz"], attendees: addresses),
                       call("c2", daysAgo: 14, speakers: [owner, "Pat Ruiz"], attendees: addresses),
                       call("x", daysAgo: 3, speakers: [owner, "Morgan Diaz"], attendees: ["dana@example.com", "morgan@example.com"])]
        let p = prep(upcoming(attendees: addresses), records: records)
        XCTAssertEqual(p.lastTime?.meeting.id, "c1")
        XCTAssertEqual(p.series?.meetings, 2)
    }

    func testWithNoPeopleToCompareTheTitleMakesTheSeries() {
        let records = [call("c1", daysAgo: 7), call("c2", daysAgo: 14)]
        XCTAssertEqual(prep(upcoming(attendees: []), records: records).series?.meetings, 2)
    }

    // MARK: Action items from last time

    func testActionItemsFromLastTimeShowOnlyTheStateThatIsKnown() {
        let items = [ActionItem(owner: "Sam", task: "Send the revised budget to finance"), ActionItem(owner: "Dana Lee", task: "Send Jo the freeze dates"),
                     ActionItem(owner: "Dana Lee", task: "Book the room for the review"), ActionItem(owner: "Jo Park", task: "Move the review to Thursday"),
                     ActionItem(owner: "Dana Lee", task: "Write the hiring plan for the migration")]
        let open = promise("Write the hiring plan for the migration", to: nil, daysAgo: 7)
        let done = promise("Send Jo the freeze dates", to: nil, daysAgo: 7, done: true)
        // A task with the same words from another call says nothing about this item.
        let elsewhere = promise("Book the room for the review", to: nil, daysAgo: 30, call: "other", done: true)
        let last = prep(records: [call("c1", daysAgo: 7, items: items)], commitments: [open, done, elsewhere]).lastTime
        // The owner's open item first, then the owner's with no known state, then the other people's in the
        // meeting's order, and the owner's done ones last. Nothing is left out.
        XCTAssertEqual(last?.items.map(\.task), ["Write the hiring plan for the migration", "Book the room for the review",
                                                 "Send the revised budget to finance", "Move the review to Thursday", "Send Jo the freeze dates"])
        XCTAssertEqual(last?.items.map(\.state), [.open, nil, nil, nil, .done])
        XCTAssertEqual(last?.items.map(\.isOwners), [true, true, false, false, true])
        // "Sam" is one of the people, but a first name is not a link.
        XCTAssertEqual(last?.items.map(\.owner), ["Dana Lee", "Dana Lee", "Sam", "Jo Park", "Dana Lee"])
        XCTAssertEqual(last?.items.map(\.person), [nil, nil, nil, "Jo Park", nil])
        XCTAssertEqual(last?.total, 5)
        XCTAssertEqual(last?.ownersOpen, 1)
        XCTAssertEqual(last?.absent, 0)
    }

    func testAnItemWhoseOwnerCannotBeMatchedStillShows() {
        // An invite of addresses, two of them of nobody Mossad saved: it cannot say who is absent.
        let addresses = ["dana@example.com", "sam.carter@example.com", "pat@example.com", "kim@example.com"]
        let items = [ActionItem(owner: "Pat Ruiz", task: "Send the contract"), ActionItem(owner: "Sam and Jo", task: "Agree on the date"),
                     ActionItem(owner: "Speaker B", task: "Check the numbers"), ActionItem(owner: "Kim", task: "Book the room"),
                     ActionItem(owner: nil, task: "Find a room for the planning day")]
        let last = prep(upcoming(attendees: addresses), records: [call("c1", daysAgo: 7, speakers: [owner, sam, "Pat Ruiz", "Kim Ito"], items: items)]).lastTime
        XCTAssertEqual(last?.items.map(\.owner), ["Pat Ruiz", "Sam and Jo", "Speaker B", "Kim", nil])
        XCTAssertEqual(last?.items.map(\.state), [nil, nil, nil, nil, nil])
        XCTAssertEqual(last?.absent, 0)
    }

    func testOnlyAnOwnerWhoIsSurelyNotInvitedIsLeftOffAndCounted() {
        // Every entry of this invite is a person with a name, and Morgan, who spoke last time, is none of them.
        let items = [ActionItem(owner: "Morgan Diaz", task: "Check the freeze dates"), ActionItem(owner: "Morgan", task: "Call support"),
                     ActionItem(owner: "Team", task: "Clean the backlog"), ActionItem(owner: "Jo Park", task: "Move the review")]
        let last = prep(records: [call("c1", daysAgo: 7, speakers: [owner, sam, jo, "Morgan Diaz"], items: items)]).lastTime
        XCTAssertEqual(last?.items.map(\.task), ["Clean the backlog", "Move the review"])
        XCTAssertEqual(last?.absent, 2)
        XCTAssertEqual(last?.total, 2)
    }

    func testAFirstNameIsReadAmongThePeopleOfItsOwnMeeting() {
        // Two Danas spoke: "Dana" is not surely the owner, so the item has no state and is not "yours".
        let task = promise("Write the hiring plan", to: nil, daysAgo: 7)
        let twoDanas = prep(records: [call("c1", daysAgo: 7, speakers: [owner, sam, jo, "Dana Park"], items: [ActionItem(owner: "Dana", task: "Write the hiring plan")])],
                            commitments: [task]).lastTime
        XCTAssertEqual(twoDanas?.items.map(\.isOwners), [false])
        XCTAssertEqual(twoDanas?.items.map(\.state), [nil])
        // With one Dana in the meeting it is the owner's.
        let oneDana = prep(records: [call("c1", daysAgo: 7, items: [ActionItem(owner: "Dana", task: "Write the hiring plan")])], commitments: [task]).lastTime
        XCTAssertEqual(oneDana?.items.map(\.isOwners), [true])
        XCTAssertEqual(oneDana?.items.map(\.state), [.open])
    }

    func testOneTaskSaysTheStateOfOneItemAndADeletedTaskSaysNothing() {
        let items = [ActionItem(owner: "Dana Lee", task: "Review the contract renewal terms with legal"), ActionItem(owner: "Dana Lee", task: "Review the contract"),
                     ActionItem(owner: "Dana Lee", task: "Send the notes")]
        let done = promise("Review the contract", to: nil, daysAgo: 7, done: true)
        var deleted = promise("Send the notes", to: nil, daysAgo: 7)
        deleted.deleted = true
        let last = prep(records: [call("c1", daysAgo: 7, items: items)], commitments: [done, deleted]).lastTime
        XCTAssertEqual(last?.items.map(\.task), ["Review the contract renewal terms with legal", "Send the notes", "Review the contract"])
        XCTAssertEqual(last?.items.map(\.state), [nil, nil, .done])
    }

    func testWithNoSummaryLastTimeThePageSaysSo() {
        var bare = call("c1", daysAgo: 7)
        bare.summary = nil
        let p = prep(records: [bare])
        XCTAssertEqual(p.lastTime?.hasSummary, false)
        XCTAssertEqual(p.inOneLine, "Last time has no summary.")
    }

    func testWhenTheTasksCannotBeReadNothingIsSaidAboutThem() {
        let record = call("c1", daysAgo: 7, items: [ActionItem(owner: "Dana Lee", task: "Write the hiring plan")])
        let p = prep(records: [record], commitments: nil)
        XCTAssertFalse(p.tasksKnown)
        XCTAssertEqual(p.lastTime?.items.map(\.state), [nil])
        XCTAssertTrue(p.promises.isEmpty)
        XCTAssertEqual(p.inOneLine, "Last time: 1 action item, yours.")
        XCTAssertTrue(prep(records: [record]).tasksKnown)
    }

    func testAnItemWithAnOpenTaskCarriesTheTasksMomentAndIsNotAPromiseAsWell() {
        let task = promise("Write the hiring plan for the migration", to: "Sam", daysAgo: 7, at: 2415)
        let other = promise("Send Sam the forecast", to: "Sam Carter", daysAgo: 30, call: "older", at: 12)
        let p = prep(records: [call("c1", daysAgo: 7, items: [ActionItem(owner: "Dana", task: "Write the hiring plan for the migration")])],
                     commitments: [task, other])
        XCTAssertEqual(p.lastTime?.items.map(\.at), [2415])
        XCTAssertEqual(p.lastTime?.items.map(\.atIsExact), [true])
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
        // A line that only has the words is not surely the moment: the page says "about".
        XCTAssertEqual(last?.items.map(\.atIsExact), [false, false])
    }

    func testOfTwoLinesWithTheWordsTheLaterOneIsTheMoment() {
        // The topic comes up early; the promise is the later line.
        let lines: [(Int, Double, String)] = [
            (2, 300, "Finance sent the revised budget back last week."),
            (1, 2400, "OK, I will get the revised budget over to finance."),
        ]
        let last = prep(records: [call("c1", daysAgo: 7, items: [ActionItem(owner: "Sam Carter", task: "Send the revised budget to finance")], lines: lines)]).lastTime
        XCTAssertEqual(last?.items.map(\.at), [2400])
    }

    func testInALongTurnTheMomentIsWhereTheItemsWordsBegin() {
        // Two minutes of one turn; the item is said 90 s into it.
        var r = call("c1", daysAgo: 7, items: [ActionItem(owner: "Sam Carter", task: "Send the revised budget to finance")])
        // The turn opens with the topic's words, one at a time and far apart: the item is not said there.
        let opening: [Word] = (0..<30).map { i in
            let text = i == 1 ? "budget" : i == 9 ? "finance" : "so"
            return Word(text: text, start: 100 + Double(i) * 3, end: 101 + Double(i) * 3)
        }
        let said = ["I", "will", "send", "the", "revised", "budget", "to", "finance."].enumerated().map { i, w in
            Word(text: w, start: 190 + Double(i), end: 190.5 + Double(i))
        }
        r.utterances = [Utterance(track: .them, speakerLabel: "1", start: 100, end: 220, text: (opening + said).map(\.text).joined(separator: " "), words: opening + said)]
        // A little before the shortest stretch that holds its words, so the sentence is heard from its start.
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

    func testATaskThatIsAnItemAfterTheFifthIsNotAPromiseAsWell() {
        var items = (1...5).map { ActionItem(owner: "Sam Carter", task: "Task number \($0)") }
        items.append(ActionItem(owner: "Jo Park", task: "Check the numbers"))
        items.append(ActionItem(owner: nil, task: "Write the hiring plan"))
        items.append(ActionItem(owner: "Dana Lee", task: "Send the notes"))
        // Both tasks are items: the open one is among the first five, and the done one is the last of the eight.
        let tasks = [promise("Send the notes", to: "Sam Carter", daysAgo: 7, done: true), promise("Write the hiring plan", to: "Sam Carter", daysAgo: 7)]
        let p = prep(records: [call("c1", daysAgo: 7, items: items)], commitments: tasks, keep: [tasks[0].id])
        XCTAssertEqual(p.lastTime?.items.first?.task, "Write the hiring plan")
        XCTAssertEqual(p.lastTime?.moreItems, 3)
        XCTAssertTrue(p.promises.isEmpty)
    }

    // MARK: In one line

    func testThePageOpensWithWhatIsKnownInOneLine() {
        let items = [ActionItem(owner: "Dana Lee", task: "Write the hiring plan"), ActionItem(owner: "Sam Carter", task: "Update the roadmap"),
                     ActionItem(owner: "Jo Park", task: "Check the numbers"), ActionItem(owner: nil, task: "Find a room")]
        let mine = promise("Write the hiring plan", to: nil, daysAgo: 7)
        let promises = (1...3).map { promise("Promise \($0)", to: "Jo Park", daysAgo: Double($0), call: "p\($0)") }
        // The other people's items are counted, never called open: nothing says whether they are done.
        XCTAssertEqual(prep(records: [call("c1", daysAgo: 7, items: items)], commitments: [mine] + promises).inOneLine,
                       "Last time: 4 action items, 1 of them yours and still open. You have 3 open tasks for these people.")
        // The owner's item has no task: it is the owner's, and its state is not known.
        XCTAssertEqual(prep(records: [call("c1", daysAgo: 7, items: items)]).inOneLine, "Last time: 4 action items, 1 of them yours.")
        var done = mine
        done.done = now
        XCTAssertEqual(prep(records: [call("c1", daysAgo: 7, items: items)], commitments: [done]).inOneLine, "Last time: 4 action items, 1 of them yours and done.")
        // With no series, and one person: say which meeting, and for whom.
        let one = prep(upcoming("A new meeting", attendees: ["Sam Carter"]),
                       records: [call("c1", daysAgo: 7, title: "Dana / Sam", speakers: [owner, sam], items: [ActionItem(owner: "Dana", task: "Write the hiring plan")])],
                       commitments: [mine, promise("Send the forecast", to: "Sam", daysAgo: 9, call: "old")])
        XCTAssertEqual(one.inOneLine, "Your last meeting with Sam: 1 action item, yours and still open. You have 1 open task for Sam.")
        XCTAssertEqual(prep(records: [call("c1", daysAgo: 7)]).inOneLine, "Last time had no action items.")
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
        // Only a task of a meeting that is still there has a moment to play.
        XCTAssertEqual(p.promises.map(\.playable), [false, true, false])
    }

    func testAPromisedNameIsReadAmongThePeopleOfItsOwnMeeting() {
        // "Sam" in a meeting with Sam Reed is not the invited Sam Carter.
        let records = [call("c1", daysAgo: 7), call("x", daysAgo: 10, title: "Hiring", speakers: [owner, "Sam Reed"])]
        let all = [promise("Send Sam the deck", to: "Sam", daysAgo: 10, call: "x"), promise("Send Sam the plan", to: "Sam", daysAgo: 7, call: "c1"),
                   // The meeting is gone: "Jo" is the one saved Jo. Two saved people named Sam would be nobody.
                   promise("Send Jo the notes", to: "Jo", daysAgo: 30, call: "gone")]
        XCTAssertEqual(prep(records: records, commitments: all).promises.map(\.commitment.text), ["Send Jo the notes", "Send Sam the plan"])
        let twoSams = PersonDirectory([.init(name: owner, email: nil), .init(name: sam, email: nil), .init(name: "Sam Reed", email: nil)])
        XCTAssertTrue(prep(commitments: [promise("Send Sam the deck", to: "Sam", daysAgo: 30, call: "gone")], people: twoSams).promises.isEmpty)
    }

    func testATaskMarkedDoneOnThePageStaysOnIt() {
        let done = promise("Send Sam the forecast", to: "Sam Carter", daysAgo: 30, call: "older", done: true)
        XCTAssertTrue(prep(commitments: [done]).promises.isEmpty)
        XCTAssertEqual(prep(commitments: [done], keep: [done.id]).promises.map(\.commitment.id), [done.id])
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

    func testTwoTasksAreTheSameWhenMostOfTheirWordsAre() {
        XCTAssertGreaterThanOrEqual(MeetingPrep.likeness("Write the hiring plan for the migration", "Write hiring plan"), MeetingPrep.sameTask)
        XCTAssertEqual(MeetingPrep.likeness("Send the notes", "send notes."), 1)
        XCTAssertLessThan(MeetingPrep.likeness("Send the notes", "Send Jo the freeze dates"), MeetingPrep.sameTask)
        // A short task is not every longer one that holds its words.
        XCTAssertLessThan(MeetingPrep.likeness("Review the contract", "Review the contract renewal terms with legal"), MeetingPrep.sameTask)
        // "notes" is not "not".
        XCTAssertLessThan(MeetingPrep.likeness("Send the notes", "Do not send"), MeetingPrep.sameTask)
    }

    // MARK: The tasks file

    func testAPeekAtTheTasksNeverMovesTheFile() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("prep-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        // No file yet: an empty book is the truth.
        XCTAssertEqual(CommitmentBook.peek(in: dir), CommitmentBook())
        var book = CommitmentBook()
        book.items = [promise("Send the notes", to: nil, daysAgo: 1)]
        try book.save(to: dir)
        XCTAssertEqual(CommitmentBook.peek(in: dir)?.items.map(\.text), ["Send the notes"])
        // A file that cannot be read is unknown, not empty, and it stays where it is.
        let file = dir.appendingPathComponent(CommitmentBook.fileName)
        try Data("{ not json".utf8).write(to: file)
        XCTAssertNil(CommitmentBook.peek(in: dir))
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        // The code that owns the book sets the damaged file aside. Until the other device's copy is merged in,
        // the tasks are still not known: no file is not "no tasks" then.
        XCTAssertThrowsError(try CommitmentBook.load(from: dir))
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        XCTAssertNil(CommitmentBook.peek(in: dir))
    }
}
