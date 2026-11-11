import XCTest
@testable import MossadCore

final class MeetingFilterTests: XCTestCase {
    let calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/New_York")!
        c.locale = Locale(identifier: "en_US")
        c.firstWeekday = 2
        return c
    }()

    /// Wednesday, November 11, 2026, 3 PM.
    var now: Date { at(11, 11, 15) }

    func at(_ month: Int, _ day: Int, _ hour: Int, minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: month, day: day, hour: hour, minute: minute))!
    }

    /// A written meeting. `voices` maps a speaker key to the seconds it talks; a key in `names` is a named voice.
    func record(_ id: String, start: Date? = nil, minutes: Double = 30, platform: Platform = .meet, voices: [(String, Double)] = [],
                names: [String: String] = [:], attendees: [String] = [], tags: [String] = [], kind: String? = nil, summary: Bool = true,
                items: Int = 0, decisions: Int = 0, screens: Int? = nil, status: CallStatus = .written) -> CallRecord {
        let start = start ?? at(11, 10, 10)
        var r = CallRecord(id: id, platform: platform, bundleID: "com.google.Chrome", start: start, end: start.addingTimeInterval(minutes * 60), status: status)
        var t = 0.0
        for (key, seconds) in voices {
            let parts = key.split(separator: ":")
            r.utterances.append(Utterance(track: parts[0] == "me" ? .me : .them, speakerLabel: String(parts[1]), start: t, end: t + seconds, text: "We look at the plan."))
            t += seconds + 1
        }
        r.speakerNames = names
        r.attendees = attendees
        r.tags = tags
        r.kind = kind
        if summary { r.summary = "A summary." }
        r.actionItems = (0..<items).map { ActionItem(owner: nil, task: "Task \($0)") }
        r.decisions = (0..<decisions).map { Decision(text: "Decision \($0)") }
        r.screens = screens.map { n in (0..<n).map { SharedScreen(offset: Double($0), file: "\($0).heic", text: "") } }
        return r
    }

    func rows(_ records: [CallRecord], people: MeetingFilterPeople = MeetingFilterPeople(owner: "Dana Lee"),
              ratings: [String: MeetingValue.Rating] = [:]) -> [MeetingFilterRow] {
        records.compactMap { MeetingFilterRow(record: $0, people: people, rating: ratings[$0.id]) }
    }

    func facets(_ rows: [MeetingFilterRow], _ filter: MeetingFilter = MeetingFilter(), within: Set<String>? = nil) -> MeetingFacets {
        MeetingFacets(rows: rows, filter: filter, within: within, now: now, calendar: calendar)
    }

    func ids(_ rows: [MeetingFilterRow], _ filter: MeetingFilter, within: Set<String>? = nil) -> [String] {
        facets(rows, filter, within: within).matches.sorted()
    }

    // MARK: The empty filter

    func testAnEmptyFilterMatchesEveryMeeting() {
        let all = rows([record("a"), record("b", summary: false, status: .failed)])
        let filter = MeetingFilter()
        XCTAssertTrue(filter.isEmpty)
        XCTAssertTrue(filter.active.isEmpty)
        let f = facets(all)
        XCTAssertEqual(f.matches, ["a", "b"])
        XCTAssertEqual(f.total, 2)
    }

    func testACallThatRecordsNowIsNotARow() {
        XCTAssertNil(MeetingFilterRow(record: record("live", status: .recording), people: MeetingFilterPeople(), rating: nil))
    }

    // MARK: Length

    func testLengthRangesTakeTheLowerEdgeAndLeaveTheUpperOne() {
        let all = rows([record("14", minutes: 14.9), record("15", minutes: 15), record("29", minutes: 29.9), record("30", minutes: 30),
                        record("59", minutes: 59.9), record("60", minutes: 60), record("95", minutes: 95)])
        var f = MeetingFilter()
        f.lengths = [.under15]
        XCTAssertEqual(ids(all, f), ["14"])
        f.lengths = [.to30]
        XCTAssertEqual(ids(all, f), ["15", "29"])
        f.lengths = [.to60]
        XCTAssertEqual(ids(all, f), ["30", "59"])
        f.lengths = [.over60]
        XCTAssertEqual(ids(all, f), ["60", "95"])
        f.lengths = [.under15, .over60]
        XCTAssertEqual(ids(all, f), ["14", "60", "95"])
    }

    func testACustomLengthRangeHasBothEndsAndAnOpenEnd() {
        let all = rows([record("10", minutes: 10), record("20", minutes: 20), record("45", minutes: 45.5), record("46", minutes: 46), record("120", minutes: 120)])
        var f = MeetingFilter()
        f.customLength = .init(min: 20, max: 45)
        XCTAssertEqual(ids(all, f), ["20", "45"], "45 min 30 s shows as 45 min")
        f.customLength = .init(min: 46, max: nil)
        XCTAssertEqual(ids(all, f), ["120", "46"])
        f.customLength = .init(min: 0, max: 10)
        XCTAssertEqual(ids(all, f), ["10"])
    }

    func testAJoinedMeetingHasTheLengthOfItsAudio() {
        // Two recordings of 10 minutes, three hours apart.
        var r = record("joined", start: at(11, 10, 9), minutes: 190)
        r.parts = [CallPart(start: at(11, 10, 9), end: at(11, 10, 9, minute: 10), offset: 0),
                   CallPart(start: at(11, 10, 12), end: at(11, 10, 12, minute: 10), offset: 600)]
        XCTAssertEqual(rows([r])[0].seconds, 1200)
    }

    // MARK: Date

    func testDatePresetsCountWholeDaysBackFromToday() {
        let all = rows([record("today", start: at(11, 11, 9)), record("monday", start: at(11, 9, 9)), record("sunday", start: at(11, 8, 9)),
                        record("six", start: at(11, 5, 0)), record("seven", start: at(11, 4, 23)), record("29", start: at(10, 13, 9)),
                        record("30", start: at(10, 12, 9)), record("89", start: at(8, 14, 9)), record("90", start: at(8, 13, 9))])
        func with(_ p: MeetingFilter.Period) -> [String] {
            var f = MeetingFilter()
            f.period = p
            return ids(all, f)
        }
        XCTAssertEqual(with(.today), ["today"])
        XCTAssertEqual(with(.thisWeek), ["monday", "today"], "the week starts on Monday in this calendar")
        XCTAssertEqual(with(.last7), ["monday", "six", "sunday", "today"])
        XCTAssertEqual(with(.last30), ["29", "monday", "seven", "six", "sunday", "today"])
        XCTAssertEqual(with(.last90), ["29", "30", "89", "monday", "seven", "six", "sunday", "today"])
    }

    func testACustomDateRangeHasBothDaysAndReadsEitherOrder() {
        let all = rows([record("before", start: at(11, 2, 23)), record("first", start: at(11, 3, 0)), record("last", start: at(11, 5, 23)),
                        record("after", start: at(11, 6, 0))])
        var f = MeetingFilter()
        f.period = .custom(from: at(11, 3, 14), to: at(11, 5, 8))
        XCTAssertEqual(ids(all, f), ["first", "last"])
        f.period = .custom(from: at(11, 5, 8), to: at(11, 3, 14))
        XCTAssertEqual(ids(all, f), ["first", "last"])
    }

    func testWeekdaysCombineWithThePeriod() {
        let all = rows([record("mon", start: at(11, 9, 9)), record("tue", start: at(11, 10, 9)), record("oldMon", start: at(10, 5, 9))])
        var f = MeetingFilter()
        f.weekdays = [2]
        XCTAssertEqual(ids(all, f), ["mon", "oldMon"])
        f.period = .last7
        XCTAssertEqual(ids(all, f), ["mon"])
        f.weekdays = [2, 3]
        XCTAssertEqual(ids(all, f), ["mon", "tue"])
    }

    // MARK: Tags, kind, platform

    func testTagsMatchAnyOfTheChosenOnesInAnyCase() {
        let all = rows([record("a", tags: ["Budget", "Hiring"]), record("b", tags: ["budget"]), record("c", tags: ["Roadmap"]), record("d")])
        var f = MeetingFilter()
        f.tags = ["Budget"]
        XCTAssertEqual(ids(all, f), ["a", "b"])
        f.tags = ["Budget", "roadmap"]
        XCTAssertEqual(ids(all, f), ["a", "b", "c"])
        let tags = facets(all).tags
        XCTAssertEqual(tags.map(\.name), ["Budget", "Hiring", "Roadmap"], "one option per tag, in its first spelling, the most used first")
        XCTAssertEqual(tags.map(\.count), [2, 1, 1])
    }

    func testKindAndPlatform() {
        let all = rows([record("a", platform: .zoom, kind: "Monthly update"), record("b", platform: .inPerson, kind: "1:1"), record("c", platform: .zoom)])
        var f = MeetingFilter()
        f.kinds = ["monthly update"]
        XCTAssertEqual(ids(all, f), ["a"])
        f = MeetingFilter()
        f.platforms = [.zoom]
        XCTAssertEqual(ids(all, f), ["a", "c"])
        f.platforms = [.zoom, .inPerson]
        XCTAssertEqual(ids(all, f), ["a", "b", "c"])
        let seen = facets(all)
        XCTAssertEqual(seen.kinds.map(\.name), ["1:1", "Monthly update"])
        XCTAssertFalse(seen.platforms.exists(.teams), "a platform with no meeting is not offered")
    }

    // MARK: Number of people

    func testTheNumberOfPeopleIsTheVoicesThatCount() {
        let two = record("two", voices: [("me:A", 300), ("them:A", 280)])
        // A third voice of three seconds does not turn a 1:1 into a group.
        let twoAndANoise = record("noise", voices: [("me:A", 300), ("them:A", 280), ("them:B", 3)])
        let four = record("four", voices: [("me:A", 200), ("them:A", 200), ("them:B", 200), ("them:C", 200)])
        let seven = record("seven", voices: (0..<7).map { ("them:\($0)", 100.0) })
        let alone = record("alone", voices: [("me:A", 200)])
        let all = rows([two, twoAndANoise, four, seven, alone])
        XCTAssertEqual(all.map(\.voices), [2, 2, 4, 7, 1])
        for r in [two, twoAndANoise, four, seven] {
            XCTAssertEqual(MeetingFilterRow(record: r, people: MeetingFilterPeople(owner: "Dana Lee"), rating: nil)?.voices,
                           MeetingFacts(record: r, owner: "Dana Lee").mainVoices, "the same number as the Analytics tab")
        }
        var f = MeetingFilter()
        f.sizes = [.oneOnOne]
        XCTAssertEqual(ids(all, f), ["noise", "two"])
        f.sizes = [.small]
        XCTAssertEqual(ids(all, f), ["four"])
        f.sizes = [.large, .alone]
        XCTAssertEqual(ids(all, f), ["alone", "seven"])
    }

    func testAMeetingWithNoTranscriptHasNoNumberOfPeople() {
        let all = rows([record("spoken", voices: [("me:A", 300), ("them:A", 280)]), record("silent", summary: false, status: .failed)])
        XCTAssertNil(all[1].voices)
        let f = facets(all)
        XCTAssertEqual(MeetingFilter.Size.allCases.map { f.sizes.count($0) }.reduce(0, +), 1, "the unknown one is in no count")
        for size in MeetingFilter.Size.allCases {
            var filter = MeetingFilter()
            filter.sizes = [size]
            XCTAssertFalse(ids(all, filter).contains("silent"))
        }
    }

    // MARK: Value

    func testAMeetingWithNoRatingIsItsOwnOptionAndNeverLow() {
        let all = rows([record("h"), record("m"), record("l"), record("none")], ratings: ["h": .high, "m": .medium, "l": .low])
        var f = MeetingFilter()
        f.values = [.low]
        XCTAssertEqual(ids(all, f), ["l"])
        f.values = [.notRated]
        XCTAssertEqual(ids(all, f), ["none"])
        f.values = [.high, .medium]
        XCTAssertEqual(ids(all, f), ["h", "m"])
        let seen = facets(all)
        XCTAssertEqual(MeetingFilter.Value.allCases.map { seen.values.count($0) }, [1, 1, 1, 1])
    }

    // MARK: Has

    func testHasActionItemsNeedsASummaryThatSaysSo() {
        let all = rows([record("with", items: 2, decisions: 1), record("without"), record("noSummary", summary: false), record("screens", screens: 3),
                        record("captureNoScreens", screens: 0)])
        XCTAssertNil(all[2].actionItems)
        var f = MeetingFilter()
        f.flags = [.actionItems]
        XCTAssertEqual(ids(all, f), ["with"])
        f.flags = [.decisions]
        XCTAssertEqual(ids(all, f), ["with"])
        f.flags = [.screens]
        XCTAssertEqual(ids(all, f), ["screens"])
        f.flags = [.actionItems, .screens]
        XCTAssertEqual(ids(all, f), [])
        let seen = facets(all)
        XCTAssertEqual(seen.flags.count(.actionItems), 1)
        XCTAssertEqual(seen.flags.count(.screens), 1)
    }

    // MARK: People

    var people: MeetingFilterPeople {
        MeetingFilterPeople(directory: PersonDirectory([.init(name: "Sam Carter", email: "sam@example.com"), .init(name: "Riley Park", email: nil),
                                                        .init(name: "Dana Lee", email: "dana@example.com")]),
                            ids: ["Sam Carter": "id-sam", "Riley Park": "id-riley", "Dana Lee": "id-dana"], owner: "Dana Lee")
    }

    func testASavedPersonIsFoundByIdAndTheOwnerIsNoOption() {
        let r = record("a", voices: [("me:A", 100), ("them:A", 100), ("them:B", 100)], names: ["me:A": "Dana Lee", "them:A": "Sam Carter"],
                       attendees: ["Dana Lee", "Carter, Sam", "riley.park@example.com", "Jo Quinn", "someone@example.com"])
        let row = MeetingFilterRow(record: r, people: people, rating: nil)!
        XCTAssertEqual(row.people.map(\.id), ["id-sam", nil], "the email of nobody saved is no person; Riley has no saved email, so that address is nobody")
        XCTAssertEqual(row.people.map(\.name), ["Sam Carter", "Jo Quinn"])
    }

    func testAnInvitedPersonWithASavedEmailIsThatPerson() {
        let r = record("a", attendees: ["sam@example.com"])
        XCTAssertEqual(MeetingFilterRow(record: r, people: people, rating: nil)?.people, [MeetingFilter.Who(id: "id-sam", name: "Sam Carter")])
    }

    func testAPersonFilterFollowsTheIdThroughANewName() {
        let all = rows([record("a", voices: [("them:A", 100)], names: ["them:A": "Sam Carter"]), record("b", voices: [("them:A", 100)], names: ["them:A": "Jo Quinn"])],
                       people: people)
        var f = MeetingFilter()
        // Chosen under an older name.
        f.people = [.init(id: "id-sam", name: "Samuel Carter")]
        XCTAssertEqual(ids(all, f), ["a"])
        // With no id the name as shown decides, in any case.
        f.people = [.init(name: "jo quinn")]
        XCTAssertEqual(ids(all, f), ["b"])
        // A name alone never stands for a saved person with an id.
        f.people = [.init(name: "Sam Carter")]
        XCTAssertEqual(ids(all, f), [])
    }

    func testWithNoIdsASavedPersonIsFoundByTheSavedName() {
        let noIDs = MeetingFilterPeople(directory: people.directory, ids: [:], owner: "Dana Lee")
        let all = rows([record("a", attendees: ["Carter, Sam"]), record("b", voices: [("them:A", 100)], names: ["them:A": "Sam Carter"])], people: noIDs)
        XCTAssertEqual(all.map { $0.people.map(\.name) }, [["Sam Carter"], ["Sam Carter"]])
        var f = MeetingFilter()
        f.people = [.init(name: "Sam Carter")]
        XCTAssertEqual(ids(all, f), ["a", "b"])
    }

    func testTheVoiceLibrarysPeopleGetTheirIdsFromThePeopleStore() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("filter-people-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = PeopleStore(directory: dir)
        let sam = try store.ensure(voiceName: "Sam Carter", isOwner: false, origin: .voiceNaming)
        let profiles = [VoiceProfile(name: "Sam Carter", isOwner: false, embeddings: []), VoiceProfile(name: "Jo Quinn", isOwner: false, embeddings: [])]
        let known = MeetingFilterPeople(profiles: profiles, store: store, owner: "Dana Lee")
        XCTAssertEqual(known.ids, ["Sam Carter": sam.rawValue])
        let r = record("a", voices: [("them:A", 100), ("them:B", 100)], names: ["them:A": "Sam Carter", "them:B": "Jo Quinn"])
        XCTAssertEqual(MeetingFilterRow(record: r, people: known, rating: nil)?.people.map(\.id), [sam.rawValue, nil])
        XCTAssertEqual(MeetingFilterPeople(profiles: profiles, store: nil, owner: "Dana Lee").ids, [:])
    }

    func testPeopleAnyAndAll() {
        let sam = MeetingFilter.Who(id: "id-sam", name: "Sam Carter"), riley = MeetingFilter.Who(id: "id-riley", name: "Riley Park")
        let all = rows([record("both", voices: [("them:A", 100), ("them:B", 100)], names: ["them:A": "Sam Carter", "them:B": "Riley Park"]),
                        record("sam", voices: [("them:A", 100)], names: ["them:A": "Sam Carter"]),
                        record("riley", voices: [("them:A", 100)], names: ["them:A": "Riley Park"]),
                        record("nobody", voices: [("them:A", 100)])], people: people)
        var f = MeetingFilter()
        f.people = [sam, riley]
        XCTAssertEqual(ids(all, f), ["both", "riley", "sam"])
        f.peopleMode = .all
        XCTAssertEqual(ids(all, f), ["both"])
        // With everyone chosen, a person's count is the meetings that have that person too.
        let jo = MeetingFilter.Who(name: "Jo Quinn")
        let more = all + rows([record("three", voices: [("them:A", 100), ("them:B", 100), ("them:C", 100)],
                                      names: ["them:A": "Sam Carter", "them:B": "Riley Park", "them:C": "Jo Quinn"])], people: people)
        let seen = facets(more, f)
        XCTAssertEqual(seen.people.first { $0.who == jo }?.count, 1)
        XCTAssertEqual(seen.people.first { $0.who == sam }?.count, 2)
    }

    func testAnUnnamedVoiceIsNoPerson() {
        let all = rows([record("a", voices: [("them:A", 100), ("them:B", 50)], names: ["them:A": "Sam Carter"])], people: people)
        XCTAssertEqual(all[0].people.map(\.name), ["Sam Carter"])
    }

    // MARK: Counts

    func testAnOptionCountsTheMeetingsTheOtherChoicesLeave() {
        let all = rows([record("zoomBudget", platform: .zoom, tags: ["Budget"]), record("zoomHiring", platform: .zoom, tags: ["Hiring"]),
                        record("meetBudget", platform: .meet, tags: ["Budget"]), record("teamsRoadmap", platform: .teams, tags: ["Roadmap"])])
        var f = MeetingFilter()
        f.platforms = [.zoom]
        let seen = facets(all, f)
        XCTAssertEqual(seen.matches, ["zoomBudget", "zoomHiring"])
        // The platform's own choice does not narrow the platform counts: a second platform adds its meetings.
        XCTAssertEqual(seen.platforms.count(.zoom), 2)
        XCTAssertEqual(seen.platforms.count(.meet), 1)
        XCTAssertEqual(seen.platforms.count(.teams), 1)
        // Every other group is counted inside the choice.
        XCTAssertEqual(seen.tags.map(\.name), ["Budget", "Hiring", "Roadmap"], "every tag stays in the list, in the order of all meetings")
        XCTAssertEqual(seen.tags.map(\.count), [1, 1, 0])
        XCTAssertEqual(seen.total, 4)

        f.tags = ["Budget"]
        let both = facets(all, f)
        XCTAssertEqual(both.matches, ["zoomBudget"])
        XCTAssertEqual(both.platforms.count(.meet), 1, "Meet would add the Budget meeting on Meet")
        XCTAssertEqual(both.platforms.count(.teams), 0)
        XCTAssertEqual(both.tags.map(\.count), [1, 1, 0], "Hiring would add the Hiring meeting on Zoom")
    }

    func testTheSearchTextNarrowsTheMeetingsAndTheCounts() {
        let all = rows([record("a", platform: .zoom, tags: ["Budget"]), record("b", platform: .zoom), record("c", platform: .meet, tags: ["Budget"])])
        var f = MeetingFilter()
        f.tags = ["Budget"]
        let seen = facets(all, f, within: ["a", "b"])
        XCTAssertEqual(seen.matches, ["a"])
        XCTAssertEqual(seen.total, 2)
        XCTAssertEqual(seen.platforms.count(.zoom), 1)
        XCTAssertFalse(seen.platforms.exists(.meet))
        XCTAssertEqual(seen.tags.map(\.count), [1])
    }

    func testAChosenOptionStaysInTheListWithNoMeeting() {
        let all = rows([record("a", tags: ["Budget"])], people: people)
        var f = MeetingFilter()
        f.tags = ["Gone"]
        f.kinds = ["Old kind"]
        f.people = [.init(id: "id-sam", name: "Sam Carter")]
        let seen = facets(all, f)
        XCTAssertEqual(seen.tags.map(\.name), ["Budget", "Gone"])
        XCTAssertEqual(seen.kinds.map(\.name), ["Old kind"])
        XCTAssertEqual(seen.people.map(\.who.name), ["Sam Carter"])
        XCTAssertEqual(seen.people.map(\.count), [0])
    }

    func testPeopleAreListedByMeetingsThenByName() {
        let all = rows([record("a", voices: [("them:A", 100), ("them:B", 100)], names: ["them:A": "Sam Carter", "them:B": "Riley Park"]),
                        record("b", voices: [("them:A", 100)], names: ["them:A": "Riley Park"]),
                        record("c", attendees: ["Avery Stone", "Jo Quinn"])], people: people)
        XCTAssertEqual(facets(all).people.map(\.who.name), ["Riley Park", "Avery Stone", "Jo Quinn", "Sam Carter"])
    }

    // MARK: Chips

    func testEachChoiceIsOneChipAndAChipCanGo() {
        var f = MeetingFilter()
        let sam = MeetingFilter.Who(id: "id-sam", name: "Sam Carter")
        f.toggle(.person(sam))
        f.toggle(.length(.under15))
        f.toggle(.period(.last7))
        f.toggle(.weekday(2))
        f.toggle(.tag("Budget"))
        f.toggle(.kind("Monthly update"))
        f.toggle(.size(.oneOnOne))
        f.toggle(.value(.notRated))
        f.toggle(.platform(.zoom))
        f.toggle(.flag(.decisions))
        XCTAssertEqual(f.active.count, 10)
        XCTAssertFalse(f.isEmpty)
        XCTAssertEqual(f.active.map { $0.label(calendar: calendar, now: now) },
                       ["Sam Carter", "Last 7 days", "Mon", "Under 15 min", "1:1", "Budget", "Monthly update", "Not rated", "Zoom", "Has decisions"])
        for chip in f.active { XCTAssertTrue(f.contains(chip)) }
        f.remove(.tag("budget"))
        XCTAssertEqual(f.tags, [])
        f.toggle(.person(sam))
        XCTAssertEqual(f.people, [])
        for chip in f.active { f.remove(chip) }
        XCTAssertTrue(f.isEmpty)
    }

    func testOnePeriodAtATimeAndACustomLengthInPlaceOfTheRanges() {
        var f = MeetingFilter()
        f.toggle(.period(.today))
        f.toggle(.period(.last30))
        XCTAssertEqual(f.period, .last30)
        f.toggle(.period(.last30))
        XCTAssertNil(f.period)

        f.toggle(.length(.to30))
        f.toggle(.customLength(.init(min: 20, max: 45)))
        XCTAssertEqual(f.lengths, [])
        XCTAssertEqual(f.customLength, .init(min: 20, max: 45))
        f.toggle(.length(.over60))
        XCTAssertNil(f.customLength)
        XCTAssertEqual(f.lengths, [.over60])
    }

    func testTheModeGoesBackToAnyWithFewerThanTwoPeople() {
        var f = MeetingFilter()
        f.toggle(.person(.init(name: "Sam Carter")))
        f.toggle(.person(.init(name: "Jo Quinn")))
        f.peopleMode = .all
        f.remove(.person(.init(name: "Jo Quinn")))
        XCTAssertEqual(f.peopleMode, .any)
    }

    func testChipWords() {
        func label(_ a: MeetingFilter.Active) -> String { a.label(calendar: calendar, now: now) }
        XCTAssertEqual(label(.customLength(.init(min: 20, max: 45))), "20–45 min")
        XCTAssertEqual(label(.customLength(.init(min: 45, max: nil))), "45 min or more")
        XCTAssertEqual(label(.customLength(.init(min: 0, max: 10))), "Up to 10 min")
        XCTAssertEqual(label(.period(.custom(from: at(11, 3, 9), to: at(11, 5, 9)))), "Nov 3 – Nov 5")
        XCTAssertEqual(label(.period(.custom(from: at(11, 3, 9), to: at(11, 3, 12)))), "Nov 3")
        XCTAssertEqual(label(.size(.small)), "3–5 people")
        XCTAssertEqual(label(.size(.large)), "6+ people")
        XCTAssertEqual(label(.value(.high)), "High value")
        XCTAssertEqual(label(.flag(.screens)), "Has screens")
        XCTAssertEqual(label(.platform(.inPerson)), "In person")
    }

    // MARK: The kept rows

    func testOnlyAChangedMeetingIsReadAgain() {
        let cache = MeetingFilterRows()
        var a = record("a", tags: ["Budget"]), b = record("b")
        _ = cache.rows(for: [a, b], people: people, ratings: [:])
        XCTAssertEqual(cache.readCount, 2)
        _ = cache.rows(for: [a, b], people: people, ratings: [:])
        XCTAssertEqual(cache.readCount, 2)
        a.tags = ["Hiring"]
        let again = cache.rows(for: [a, b], people: people, ratings: ["b": .high])
        XCTAssertEqual(cache.readCount, 3, "a new rating needs no read of the meeting")
        XCTAssertEqual(again.map(\.tags), [["Hiring"], []])
        XCTAssertEqual(again.map(\.value), [nil, .high])
        // Other saved people can change who a name is.
        b.attendees = ["Carter, Sam"]
        _ = cache.rows(for: [a, b], people: people, ratings: [:])
        let other = MeetingFilterPeople(directory: PersonDirectory(), ids: [:], owner: "Dana Lee")
        let renamed = cache.rows(for: [a, b], people: other, ratings: [:])
        XCTAssertEqual(renamed[1].people.map(\.name), ["Carter, Sam"])
        XCTAssertEqual(cache.rows(for: [a, record("live", status: .recording)], people: other, ratings: [:]).map(\.id), ["a"])
    }

    func testRatingsAreReadFromTheReviewFilesAndOnlyWhenTheyChange() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ratings-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        func dir(_ id: String) -> URL { root.appendingPathComponent(id) }
        for id in ["a", "b", "c"] { try FileManager.default.createDirectory(at: dir(id), withIntermediateDirectories: true) }
        func review(_ rating: MeetingValue.Rating?) -> CoachReview {
            CoachReview(headline: "h", overview: "o", strengths: [], improvements: [], focusProgress: nil,
                        value: rating.map { MeetingValue(rating: $0, reason: "r", action: .keep, suggestion: "s") })
        }
        try review(.low).save(in: dir("a"))
        try review(nil).save(in: dir("b"))
        let cache = MeetingRatings()
        XCTAssertEqual(cache.read(ids: ["a", "b", "c"], directory: dir), ["a": .low], "a review with no rating, and no review, are both no rating")
        XCTAssertEqual(cache.decodeCount, 2)
        XCTAssertEqual(cache.read(ids: ["a", "b", "c"], directory: dir), ["a": .low])
        XCTAssertEqual(cache.decodeCount, 2)
        try review(.high).save(in: dir("c"))
        XCTAssertEqual(cache.read(ids: ["a", "b", "c"], directory: dir), ["a": .low, "c": .high])
        XCTAssertEqual(cache.decodeCount, 3)
    }
}
