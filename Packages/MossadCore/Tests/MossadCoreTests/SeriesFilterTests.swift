import XCTest
@testable import MossadCore

/// The Recurring list's filter and search: each series as one row made from its meetings' rows, the choices with
/// their counts in one pass, and a search that finds a series by its own words or by any of its meetings.
final class SeriesFilterTests: XCTestCase {
    let calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/New_York")!
        c.locale = Locale(identifier: "en_US")
        c.firstWeekday = 2
        return c
    }()

    /// Wednesday, November 11, 2026, 3 PM.
    var now: Date { at(11, 11, 15) }

    func at(_ month: Int, _ day: Int, _ hour: Int) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: month, day: day, hour: hour))!
    }

    func meeting(_ id: String, _ start: Date, minutes: Double = 30, platform: Platform = .meet, people: [String] = [],
                 size: MeetingFilter.Size = .unknown, value: MeetingValue.Rating? = nil) -> MeetingFilterRow {
        var r = CallRecord(id: id, platform: platform, bundleID: "com.google.Chrome", start: start, end: start.addingTimeInterval(minutes * 60), status: .written)
        r.summary = "A summary."
        var row = MeetingFilterRow(record: r, people: MeetingFilterPeople(owner: "Dana Lee"), rating: value)!
        row.people = people.map { MeetingFilter.Who(name: $0) }
        row.size = size
        return row
    }

    func series(_ id: String, title: String = "Weekly sync", meetings: [MeetingFilterRow] = [], rhythm: SeriesCadence.Rhythm? = .weekly(weekday: 3),
                next: Date? = nil, notesOnly: Set<String> = []) -> MeetingSeries {
        let occurrences = meetings.sorted { $0.start > $1.start }.map {
            MeetingSeries.Occurrence(id: $0.id, title: title, start: $0.start, end: $0.start.addingTimeInterval($0.seconds), notesOnly: notesOnly.contains($0.id))
        }
        let upcoming = next.map { [UpcomingMeeting(title: title, start: $0, end: $0.addingTimeInterval(1800), attendees: [], platform: .zoom)] } ?? []
        return MeetingSeries(id: id, keys: [id], title: title, meetings: occurrences, upcoming: upcoming,
                             cadence: rhythm.map { SeriesCadence(rhythm: $0, hour: 10, minute: 0, interval: 7) }, recurringInCalendar: next != nil,
                             usualPeople: [])
    }

    func row(_ s: MeetingSeries, _ meetings: [MeetingFilterRow], invited: [String] = [], openItems: Bool? = nil) -> SeriesFilterRow {
        SeriesFilterRow(series: s, meetings: Dictionary(uniqueKeysWithValues: meetings.map { ($0.id, $0) }),
                        invited: invited.map { MeetingFilter.Who(name: $0) }, openItems: openItems)
    }

    func facets(_ rows: [SeriesFilterRow], _ filter: SeriesFilter = SeriesFilter(), within: Set<String>? = nil) -> SeriesFacets {
        SeriesFacets(rows: rows, filter: filter, within: within, now: now, calendar: calendar)
    }

    func ids(_ rows: [SeriesFilterRow], _ filter: SeriesFilter) -> [String] { facets(rows, filter).matches.sorted() }

    // MARK: The row of a series

    func testASeriesReadsItsUsualValuesFromItsMeetings() {
        let m = [meeting("a", at(11, 3, 10), minutes: 30, platform: .zoom, people: ["Sam Carter"], size: .small, value: .high),
                 meeting("b", at(10, 27, 10), minutes: 50, platform: .zoom, people: ["Sam Carter", "Riley Park"], size: .small, value: .low),
                 meeting("c", at(10, 20, 10), minutes: 40, platform: .meet, people: ["Riley Park"], size: .large, value: .high)]
        let r = row(series("s", meetings: m), m, invited: ["Jo Park"])
        XCTAssertEqual(r.cadence, .weekly)
        XCTAssertEqual(r.platform, .zoom)
        XCTAssertEqual(r.seconds, 40 * 60)
        XCTAssertEqual(r.size, .small)
        XCTAssertEqual(r.value, .high)
        XCTAssertEqual(r.last, at(11, 3, 10))
        // Who came most first, then who is invited to the next one.
        XCTAssertEqual(r.people.map(\.name), ["Riley Park", "Sam Carter", "Jo Park"])
    }

    func testASeriesWithNoMeetingKnowsNothingOfThemAndIsNotRated() {
        let r = row(series("s", rhythm: nil, next: at(11, 12, 10)), [])
        XCTAssertNil(r.cadence)
        XCTAssertNil(r.seconds)
        XCTAssertNil(r.last)
        XCTAssertNil(r.openItems)
        XCTAssertEqual(r.platform, .zoom, "the invite's link says it")
        XCTAssertEqual(r.size, .unknown)
        XCTAssertEqual(r.value, .notRated)
    }

    func testAUsualValueNeedsHalfOfTheMeetings() {
        let m = [meeting("a", at(11, 3, 10), size: .small, value: .high), meeting("b", at(10, 27, 10)), meeting("c", at(10, 20, 10))]
        let r = row(series("s", meetings: m), m)
        XCTAssertEqual(r.size, .unknown)
        XCTAssertEqual(r.value, .notRated)
        let two = [meeting("a", at(11, 3, 10), size: .small, value: .high), meeting("b", at(10, 27, 10))]
        XCTAssertEqual(row(series("s", meetings: two), two).size, .small)
    }

    func testLastMetIsTheNewestMeetingTheOwnerWasIn() {
        var missed = meeting("new", at(11, 9, 10))
        missed.ownerPresent = nil
        let m = [missed, meeting("old", at(10, 20, 10))]
        XCTAssertEqual(row(series("s", meetings: m), m).last, at(10, 20, 10))
    }

    func testTheNextInvitesPeopleAreSureMatchesOnly() {
        let directory = PersonDirectory([.init(name: "Sam Carter", email: "sam@example.com")])
        let people = MeetingFilterPeople(directory: directory, owner: "Dana Lee")
        var s = series("s", next: at(11, 13, 10))
        s.upcoming[0].attendees = ["sam@example.com", "stranger@example.org", "Dana Lee"]
        XCTAssertEqual(SeriesFilterRow.rows([s], meetings: [], people: people, openItems: [:]).first?.people.map(\.name), ["Sam Carter"])
    }

    func testAnUnknownPlatformOrSizeMatchesNoChoice() {
        let rows = [row(series("blank"), [])]
        var filter = SeriesFilter()
        filter.toggle(.platform(.zoom))
        XCTAssertTrue(ids(rows, filter).isEmpty)
        filter = SeriesFilter()
        filter.toggle(.size(.small))
        XCTAssertTrue(ids(rows, filter).isEmpty)
        XCTAssertEqual(facets(rows).sizes.count(.unknown), 1)
    }

    func testANotesOnlyMeetingHasNoLength() {
        let m = [meeting("a", at(11, 3, 10), minutes: 30), meeting("b", at(10, 27, 10), minutes: 90)]
        XCTAssertEqual(row(series("s", meetings: m, notesOnly: ["b"]), m).seconds, 30 * 60)
    }

    func testTheCadenceGroups() {
        XCTAssertEqual(SeriesFilter.Cadence(SeriesCadence(rhythm: .weekly(weekday: 2), interval: 7)), .weekly)
        XCTAssertEqual(SeriesFilter.Cadence(SeriesCadence(rhythm: .everyOtherWeek(weekday: 2), interval: 14)), .everyTwoWeeks)
        XCTAssertEqual(SeriesFilter.Cadence(SeriesCadence(rhythm: .monthly, interval: 30)), .monthly)
        XCTAssertEqual(SeriesFilter.Cadence(SeriesCadence(rhythm: .weekdays, interval: 1)), .other)
        XCTAssertEqual(SeriesFilter.Cadence(SeriesCadence(rhythm: .everyDays(10), interval: 10)), .other)
        XCTAssertNil(SeriesFilter.Cadence(nil))
    }

    // MARK: The choices

    func testAnUnknownValueMatchesNoChoiceAndIsInNoCount() {
        let known = [meeting("a", at(11, 3, 10), minutes: 20)]
        let rows = [row(series("known", meetings: known), known, openItems: true), row(series("blank", rhythm: nil), [])]
        let f = facets(rows)
        XCTAssertEqual(f.total, 2)
        XCTAssertEqual(f.cadences.count(.weekly), 1)
        XCTAssertEqual(MeetingFilter.Length.allCases.map { f.lengths.count($0) }.reduce(0, +), 1)
        XCTAssertEqual(SeriesFilter.LastMet.allCases.map { f.lastMet.count($0) }, [0, 1, 1, 0], "the ranges overlap; the blank series is in none")
        XCTAssertEqual(f.openItems.count(true), 1)
        for choice: SeriesFilter.Active in [.cadence(.other), .length(.to30), .lastMet(.earlier), .openItems] {
            var filter = SeriesFilter()
            filter.toggle(choice)
            XCTAssertFalse(ids(rows, filter).contains("blank"), "\(choice)")
        }
    }

    func testNextMeetingThisWeekInTwoWeeksOrNoneKnown() {
        let rows = [row(series("fri", next: at(11, 13, 10)), []), row(series("later", next: at(11, 20, 10)), []),
                    row(series("far", next: at(12, 10, 10)), []), row(series("none"), [])]
        var filter = SeriesFilter()
        filter.toggle(.next(.thisWeek))
        XCTAssertEqual(ids(rows, filter), ["fri"])
        filter.toggle(.next(.twoWeeks))
        XCTAssertEqual(ids(rows, filter), ["fri", "later"], "one choice at a time, as the date of the meetings")
        filter.toggle(.next(.noneKnown))
        XCTAssertEqual(ids(rows, filter), ["none"])
        let f = facets(rows)
        XCTAssertEqual(f.next.count(.thisWeek), 1)
        XCTAssertEqual(f.next.count(.twoWeeks), 2)
        XCTAssertEqual(f.next.count(.noneKnown), 1)
    }

    func testLastMetRanges() {
        let a = [meeting("a", at(11, 9, 10))], b = [meeting("b", at(10, 20, 10))], c = [meeting("c", at(6, 1, 10))]
        let rows = [row(series("a", meetings: a), a), row(series("b", meetings: b), b), row(series("c", meetings: c), c)]
        var filter = SeriesFilter()
        filter.toggle(.lastMet(.last7))
        XCTAssertEqual(ids(rows, filter), ["a"])
        filter.toggle(.lastMet(.last30))
        XCTAssertEqual(ids(rows, filter), ["a", "b"])
        filter.toggle(.lastMet(.earlier))
        XCTAssertEqual(ids(rows, filter), ["c"])
    }

    func testGroupsCombineWithAndAndChoicesInAGroupWithOr() {
        let a = [meeting("a1", at(11, 3, 10), platform: .zoom)], b = [meeting("b1", at(11, 3, 10), platform: .teams)]
        let c = [meeting("c1", at(11, 3, 10), platform: .zoom)]
        let rows = [row(series("a", meetings: a), a, openItems: true), row(series("b", meetings: b, rhythm: .monthly), b, openItems: true),
                    row(series("c", meetings: c), c, openItems: false)]
        var filter = SeriesFilter()
        filter.toggle(.platform(.zoom))
        filter.toggle(.platform(.teams))
        XCTAssertEqual(ids(rows, filter), ["a", "b", "c"])
        filter.toggle(.openItems)
        XCTAssertEqual(ids(rows, filter), ["a", "b"])
        filter.toggle(.cadence(.monthly))
        XCTAssertEqual(ids(rows, filter), ["b"])
        // A choice's count is what the list shows with it: every other group's choice applies.
        let f = facets(rows, filter)
        XCTAssertEqual(f.cadences.count(.weekly), 1)
        XCTAssertEqual(f.openItems.count(true), 1)
        XCTAssertEqual(f.platforms.count(.zoom), 0)
        XCTAssertEqual(f.platforms.count(.teams), 1)
    }

    func testPeopleAnyOrAll() {
        let a = [meeting("a1", at(11, 3, 10), people: ["Sam Carter", "Riley Park"])], b = [meeting("b1", at(11, 3, 10), people: ["Sam Carter"])]
        let rows = [row(series("a", meetings: a), a), row(series("b", meetings: b), b), row(series("c"), [], invited: ["Riley Park"])]
        var filter = SeriesFilter()
        filter.toggle(.person(.init(name: "Sam Carter")))
        filter.toggle(.person(.init(name: "Riley Park")))
        XCTAssertEqual(ids(rows, filter), ["a", "b", "c"])
        filter.peopleMode = .all
        XCTAssertEqual(ids(rows, filter), ["a"])
        XCTAssertEqual(facets(rows).people.map(\.who.name), ["Riley Park", "Sam Carter"])
        XCTAssertEqual(facets(rows).people.map(\.count), [2, 2])
        filter.remove(.person(.init(name: "Riley Park")))
        XCTAssertEqual(filter.peopleMode, .any)
    }

    func testNotRatedIsItsOwnChoiceAndNeverLow() {
        let a = [meeting("a1", at(11, 3, 10), value: .low)], b = [meeting("b1", at(11, 3, 10))]
        let rows = [row(series("a", meetings: a), a), row(series("b", meetings: b), b)]
        var filter = SeriesFilter()
        filter.toggle(.value(.low))
        XCTAssertEqual(ids(rows, filter), ["a"])
        filter = SeriesFilter()
        filter.toggle(.value(.notRated))
        XCTAssertEqual(ids(rows, filter), ["b"])
    }

    func testTheSearchNarrowsTheCounts() {
        let a = [meeting("a1", at(11, 3, 10))], b = [meeting("b1", at(11, 3, 10))]
        let rows = [row(series("a", meetings: a), a), row(series("b", meetings: b, rhythm: .monthly), b)]
        let f = facets(rows, within: ["b"])
        XCTAssertEqual(f.total, 1)
        XCTAssertEqual(f.matches, ["b"])
        XCTAssertEqual(f.cadences.count(.weekly), 0)
        XCTAssertEqual(f.filterMatches, ["a", "b"])
    }

    func testChipsAreInTheOrderOfTheGroupsAndHaveWords() {
        var filter = SeriesFilter()
        filter.toggle(.openItems)
        filter.toggle(.cadence(.everyTwoWeeks))
        filter.toggle(.person(.init(name: "Sam Carter")))
        filter.toggle(.next(.noneKnown))
        XCTAssertEqual(filter.active, [.person(.init(name: "Sam Carter")), .cadence(.everyTwoWeeks), .next(.noneKnown), .openItems])
        XCTAssertEqual(filter.active.map(\.label), ["Sam Carter", "Every 2 weeks", "No next meeting known", "Has open items"])
        filter.toggle(.openItems)
        XCTAssertFalse(filter.openItems)
    }

    // MARK: Open items

    func testOpenItemsAreUnknownWhenTheTasksCannotBeReadAndNothingElseIsOpen() {
        var r = CallRecord(id: "a", platform: .meet, bundleID: "x", start: at(11, 3, 10), end: at(11, 3, 11), status: .written)
        r.summary = "A summary."
        let s = series("s", meetings: [meeting("a", at(11, 3, 10))])
        XCTAssertNil(SeriesFilterRow.openItems(series: s, records: ["a": r], commitments: nil, owner: "Dana Lee"))
        XCTAssertEqual(SeriesFilterRow.openItems(series: s, records: ["a": r], commitments: [], owner: "Dana Lee"), false)
        let task = Commitment(text: "Send the plan", to: nil, callID: "a", callTitle: "Weekly sync", madeAt: at(11, 3, 10), due: nil)
        XCTAssertEqual(SeriesFilterRow.openItems(series: s, records: ["a": r], commitments: [task], owner: "Dana Lee"), true)
        r.actionItems = [ActionItem(owner: "Sam Carter", task: "Book the room")]
        XCTAssertEqual(SeriesFilterRow.openItems(series: s, records: ["a": r], commitments: nil, owner: "Dana Lee"), true)
    }

    // MARK: Search

    func searchRow(_ s: MeetingSeries, records: [CallRecord] = [], people: [String] = [], directory: PersonDirectory = PersonDirectory()) -> SeriesSearchRow {
        SeriesSearchRow(series: s, records: Dictionary(uniqueKeysWithValues: records.map { ($0.id, $0) }), people: people.map { MeetingFilter.Who(name: $0) },
                        directory: directory)
    }

    func testASeriesIsFoundByItsTitleCadencePeopleAndEveryAddress() {
        var r = CallRecord(id: "a1", platform: .meet, bundleID: "x", start: at(11, 3, 10), end: at(11, 3, 11), status: .written)
        r.attendees = ["Riley Park", "jo@example.com"]
        let s = series("a", title: "Budget review", meetings: [meeting("a1", at(11, 3, 10))])
        let directory = PersonDirectory([.init(name: "Sam Carter", emails: ["sam@example.com", "scarter@example.org"])])
        let rows = [searchRow(s, records: [r], people: ["Sam Carter"], directory: directory)]
        func found(_ q: String) -> SeriesListSearch.Match? { SeriesListSearch.matches(rows, query: q, meetings: [:])["a"] }
        XCTAssertEqual(found("budget")?.match.source, .title)
        XCTAssertEqual(found("tuesday")?.match.source, .field("Cadence"))
        XCTAssertEqual(found("weekly")?.match.source, .field("Cadence"))
        XCTAssertEqual(found("riley")?.match.source, .field("People"))
        XCTAssertEqual(found("sam")?.match.source, .field("People"))
        XCTAssertEqual(found("scarter")?.match.source, .field("Email"))
        XCTAssertEqual(found("jo@example.com")?.match.source, .field("Email"))
        XCTAssertNil(found("dana"))
    }

    func testAWholeAddressFindsOnlyTheSeriesWithThatAddress() {
        let directory = PersonDirectory([.init(name: "Sam Carter", emails: ["sam@example.com"]), .init(name: "Samantha Lee", emails: ["samantha@example.com"]),
                                         .init(name: "Riley Park", emails: ["riley@example.com"])])
        let a = searchRow(series("a", title: "Sales sync"), people: ["Sam Carter"], directory: directory)
        let b = searchRow(series("b", title: "Sam planning"), people: ["Samantha Lee", "Riley Park"], directory: directory)
        let hits = SeriesListSearch.matches([a, b], query: "sam@example.com", meetings: [:])
        XCTAssertEqual(Set(hits.keys), ["a"])
        XCTAssertEqual(hits["a"]?.match.source, .field("Email"))
        // A meeting that the Meetings search found by the address still counts.
        let s = series("c", title: "Board", meetings: [meeting("c1", at(11, 3, 10))])
        let byMeeting = ListMatch(title: SearchText("Board"), source: .field("People"), context: SearchText("sam@example.com"))
        XCTAssertEqual(Set(SeriesListSearch.matches([a, b, searchRow(s)], query: "sam@example.com", meetings: ["c1": byMeeting]).keys), ["a", "c"])
    }

    func testAddressesComeOnlyFromASurePerson() {
        // Two saved people with one name: nobody, so neither address.
        let twins = PersonDirectory([.init(name: "Sam Carter", emails: ["sam@example.com"]), .init(name: "Sam Carter", emails: ["scarter@example.org"])])
        let row = searchRow(series("a"), people: ["Sam Carter"], directory: twins)
        XCTAssertNil(SeriesListSearch.matches([row], query: "sam@example.com", meetings: [:])["a"])
        // A name on the invite that is no sure person brings no saved address.
        var r = CallRecord(id: "a1", platform: .meet, bundleID: "x", start: at(11, 3, 10), end: at(11, 3, 11), status: .written)
        r.attendees = ["Riley Park"]
        let saved = PersonDirectory([.init(name: "Riley Park", emails: ["riley@example.com"])])
        let invited = searchRow(series("b", meetings: [meeting("a1", at(11, 3, 10))]), records: [r], directory: saved)
        XCTAssertNil(SeriesListSearch.matches([invited], query: "riley@example.com", meetings: [:])["b"])
        XCTAssertNotNil(SeriesListSearch.matches([invited], query: "riley", meetings: [:])["b"])
    }

    func testTheCadenceFieldHasOnlyTheDayAndTheGroup() {
        let rows = [searchRow(series("a", title: "Board"))]
        func found(_ q: String) -> Bool { SeriesListSearch.matches(rows, query: q, meetings: [:])["a"] != nil }
        XCTAssertTrue(found("tuesday"))
        XCTAssertTrue(found("weekly"))
        XCTAssertFalse(found("10"))
        XCTAssertFalse(found("every"))
    }

    func testATagOrAPersonQueryUsesOnlyTheMeetings() {
        let s = series("a", title: "Budget review", meetings: [meeting("m", at(11, 3, 10))])
        XCTAssertNil(SeriesListSearch.matches([searchRow(s)], query: "#budget", meetings: [:])["a"])
        let tagged = ListMatch(title: SearchText("Budget review"), source: .field("Tag"), context: SearchText("Budget"))
        XCTAssertEqual(SeriesListSearch.matches([searchRow(s)], query: "#budget", meetings: ["m": tagged])["a"]?.meetingID, "m")
        XCTAssertNil(SeriesListSearch.matches([searchRow(s, people: ["Sam Carter"])], query: "@sam", meetings: [:])["a"])
    }

    func testASeriesMatchesWhenAnyOfItsMeetingsMatchesAndShowsTheNewestPlace() {
        let s = series("a", title: "Budget review", meetings: [meeting("new", at(11, 3, 10)), meeting("old", at(10, 27, 10))])
        let line = ListMatch(title: SearchText("Budget review"), source: .transcript(speaker: "Sam Carter"), context: SearchText("the vendor quote"), time: 437)
        let older = ListMatch(title: SearchText("Budget review"), source: .field("Summary"), context: SearchText("vendor"))
        let hit = SeriesListSearch.matches([searchRow(s)], query: "vendor", meetings: ["old": older, "new": line, "other": older])
        XCTAssertEqual(hit.count, 1)
        XCTAssertEqual(hit["a"]?.meetingID, "new")
        XCTAssertEqual(hit["a"]?.match.source, .transcript(speaker: "Sam Carter"))
        XCTAssertEqual(hit["a"]?.match.time, 437)
        // Its own words come first: no meeting to open.
        let own = SeriesListSearch.matches([searchRow(s)], query: "budget", meetings: ["new": line])
        XCTAssertNil(own["a"]?.meetingID)
        XCTAssertEqual(own["a"]?.match.source, .title)
    }

    func testAMeetingFoundByAnOlderTitleSaysSo() {
        let s = series("a", title: "Budget review", meetings: [meeting("old", at(10, 27, 10))])
        let byTitle = ListMatch(title: SearchText("Finance sync"))
        let hit = SeriesListSearch.matches([searchRow(s)], query: "finance", meetings: ["old": byTitle])["a"]
        XCTAssertEqual(hit?.match.source, .field("Meeting"))
        XCTAssertEqual(hit?.match.context?.text, "Finance sync")
        XCTAssertEqual(hit?.meetingID, "old")
    }
}
