import XCTest
@testable import MossadCore

/// The fixes from the review of the recurring meetings.
final class SeriesFixesTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let owner = "Dana Lee"
    private var utc: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }

    private func call(_ id: String, daysAgo: Double, title: String = "1:1", speakers: [String] = ["Dana Lee", "Sam Carter"], seriesID: String? = nil,
                      start: Date? = nil, lines: [(Int, Double, Double, String)] = [], decisions: [Decision] = []) -> CallRecord {
        let s = start ?? now.addingTimeInterval(-daysAgo * 86_400)
        var r = CallRecord(id: id, platform: .meet, bundleID: "", start: s, end: s.addingTimeInterval(1800), status: .written)
        r.calendarTitle = title
        r.calendarSeriesID = seriesID
        for (i, name) in speakers.enumerated() { r.speakerNames[i == 0 ? "me:A" : "them:\(i)"] = name }
        r.utterances = lines.map { sp, at, len, text in Utterance(track: sp == 0 ? .me : .them, speakerLabel: sp == 0 ? "A" : "\(sp)", start: at, end: at + len, text: text) }
        r.decisions = decisions
        return r
    }

    private func catalog(_ records: [CallRecord], aliases: [String: String] = [:]) -> [MeetingSeries] {
        SeriesCatalog.build(records: records, upcoming: [], owner: owner, directory: PersonDirectory(), aliases: aliases, calendar: utc)
    }

    // M1
    func testAnAnswerTakenBackStaysTakenBackAfterAMergeWithAnOlderCopy() {
        var mac = NextTimeBook()
        let s = SeriesSuggestion(key: "pendingDecision:x", kind: .pendingDecision, text: "t", source: .init(label: "l"))
        mac.answer(s, .never, at: now)
        let phone = mac
        mac.takeBack(s.key, at: now.addingTimeInterval(60))
        let merged = mac.merged(with: phone)
        XCTAssertFalse(SuggestionTraining(answers: merged.answers, asOf: now).isBlocked(.pendingDecision))
        XCTAssertFalse(SuggestionTraining(answers: merged.answers, asOf: now).answered.contains(s.key))
        var blocked = NextTimeBook()
        blocked.answer(s, .never, at: now)
        blocked.allowAgain(.pendingDecision, at: now.addingTimeInterval(60))
        XCTAssertFalse(SuggestionTraining(answers: blocked.merged(with: phone).answers, asOf: now).isBlocked(.pendingDecision))
    }

    // M8
    func testTheKindsThatAreOffAreListed() {
        let answers = [SuggestionAnswer(key: "a", kind: "unanswered", verdict: .never, date: now)]
            + (0..<2).map { SuggestionAnswer(key: "d\($0)", kind: "openItem", verdict: .dismiss, date: now) }
        XCTAssertEqual(SuggestionTraining(answers: answers, asOf: now).off, [.openItem, .unanswered])
        var book = NextTimeBook()
        book.answers = answers
        book.allowAgain(.openItem, at: now.addingTimeInterval(1))
        XCTAssertEqual(SuggestionTraining(answers: book.answers, asOf: now).off, [.unanswered])
    }

    // M2
    func testAMeetingWithNoKnownPeopleDoesNotJoinTwoSeries() {
        let records = [call("a", daysAgo: 14), call("b", daysAgo: 7),
                       call("c", daysAgo: 13, speakers: ["Dana Lee", "Jo Park"]), call("d", daysAgo: 6, speakers: ["Dana Lee", "Jo Park"]),
                       call("e", daysAgo: 1, speakers: ["Dana Lee", "Speaker B"])]
        XCTAssertEqual(Set(catalog(records).map { Set($0.meetings.map(\.id)) }), [["a", "b"], ["c", "d"]])
        // With one series of that title, it joins it.
        XCTAssertEqual(catalog([call("a", daysAgo: 14), call("b", daysAgo: 7), call("e", daysAgo: 1, speakers: ["Dana Lee"])]).first?.meetings.count, 3)
    }

    // M3
    func testTheMacsSeriesIDNeverReplacesGooglesAndAliasesJoin() {
        var r = call("a", daysAgo: 7, seriesID: "g1")
        var mac = CalendarEventInfo(title: "1:1", start: r.start, end: r.end, attendees: [], text: "", isAllDay: false)
        mac.seriesID = "ek:U1"
        mac.isRecurring = true
        r.setInvite(mac)
        XCTAssertEqual(r.calendarSeriesID, "g1")
        let s = catalog([call("x", daysAgo: 14, title: "Old name", seriesID: "ek:U1"), call("y", daysAgo: 7, title: "New name", seriesID: "g1")], aliases: ["ek:U1": "g1"])
        XCTAssertEqual(s.count, 1)
        XCTAssertEqual(s[0].id, "cal:g1")
        XCTAssertTrue(s[0].keys.contains("cal:ek:U1"))
        XCTAssertEqual(SeriesCatalog.aliases([{ var e = mac; e.source = .google; e.seriesID = "g1"; e.iCalUID = "U1"; return e }()]), ["ek:U1": "g1"])
    }

    // M4
    func testTheWholeQuoteMustBeInTheLineAndTheSavedWordsAreTheTranscripts() {
        let lines = [Utterance(track: .them, speakerLabel: "1", start: 30, end: 40, text: "So, about the API sunset next year: we plan to move by March.")]
        XCTAssertEqual(NextTimeChecker.line(quoting: "about the API sunset next year we plan", in: lines)?.quote, "about the API sunset next year: we plan")
        XCTAssertNil(NextTimeChecker.line(quoting: "about the API sunset next year we plan to stop everything at once", in: lines))
        XCTAssertNil(NextTimeChecker.line(quoting: "the API sunset next", in: lines))
        XCTAssertNil(NextTimeChecker.line(quoting: "bout the API sunset next year we", in: lines))
    }

    // M5
    func testTheOpenDecisionRuleReadsWholeWords() {
        for made in ["Approved the Q4 spending plan", "Go with vendor A or B depending on the quote", "The demo sparked the move to weekly releases",
                     "Revisited the pricing and kept it", "Put hiring on hold until March", "Deferred the launch to March", "Use the new template next time"] {
            XCTAssertFalse(SeriesSuggestion.isPending(made), made)
        }
        for open in ["Pricing change is pending legal review", "Vendor choice TBD", "No decision yet on the offsite", "The budget is still open",
                     "Location to be confirmed", "Revisit the roadmap next meeting", "Decide on the vendor next time", "Tabled the hiring question"] {
            XCTAssertTrue(SeriesSuggestion.isPending(open), open)
        }
    }

    // M9
    func testAQuestionAnsweredAfterTheOwnersNextLineWasAnswered() {
        let r = call("a", daysAgo: 1, lines: [(0, 10, 5, "Before we go, what is the plan for the old billing service?"), (0, 16, 4, "I mean the one from last year."),
                                              (1, 21, 10, "We move it in March.")])
        XCTAssertTrue(SeriesSuggestion.unanswered(in: r, owner: OwnerIdentity(name: owner)).isEmpty)
        let silent = call("b", daysAgo: 1, lines: [(0, 10, 5, "Before we go, what is the plan for the old billing service?"), (0, 16, 30, "Okay, let us move on to the next topic now."),
                                                   (1, 60, 10, "Fine.")])
        XCTAssertEqual(SeriesSuggestion.unanswered(in: silent, owner: OwnerIdentity(name: owner)).count, 1)
    }

    // M10
    func testAWeekdayMeetingCountsNoWeekendAsSkipped() {
        let monday = utc.nextDate(after: now, matching: DateComponents(hour: 9, weekday: 2), matchingPolicy: .nextTime)!
        let days = (0..<26).map { utc.date(byAdding: .day, value: $0, to: monday)! }.filter { !utc.isDateInWeekend($0) }
        let records = days.enumerated().map { call("s\($0.offset)", daysAgo: 0, title: "Standup", start: $0.element) }
        let s = catalog(records)[0]
        XCTAssertEqual(s.cadence?.rhythm, .weekdays)
        let report = SeriesReport(series: s, records: records, commitments: nil, owner: OwnerIdentity(name: owner), directory: PersonDirectory(), calendar: utc)
        XCTAssertEqual(report.gaps, 0)
        let fewer = Array(records.dropFirst(2))
        XCTAssertEqual(SeriesReport(series: catalog(fewer)[0], records: fewer, commitments: nil, owner: OwnerIdentity(name: owner), directory: PersonDirectory(), calendar: utc).gaps, 0)
        var missing = records
        missing.remove(at: 3)
        XCTAssertEqual(SeriesReport(series: catalog(missing)[0], records: missing, commitments: nil, owner: OwnerIdentity(name: owner), directory: PersonDirectory(), calendar: utc).gaps, 1)
    }

    // M5: the report reads the last meetings only
    func testTheReportReadsOpenDecisionsOfTheLastThreeMeetings() {
        let records = (0..<5).map { i in call("m\(i)", daysAgo: Double(35 - 7 * i), decisions: i == 0 ? [Decision(text: "Vendor choice TBD")] : []) }
        let report = SeriesReport(series: catalog(records)[0], records: records, commitments: nil, owner: OwnerIdentity(name: owner), directory: PersonDirectory())
        XCTAssertTrue(report.openItems.isEmpty)
    }

    // C2
    func testInvitedPeopleAreFoundInThePeopleStoreByAddressAndAPointFollowsAMerge() {
        var sam = Person(id: PersonID(rawValue: "p-sam"), displayName: "Sam Carter", origin: .voiceNaming, at: .distantPast)
        sam.addEmail("sam@example.com", state: .verified, source: .voiceNaming, at: .distantPast)
        var old = Person(id: PersonID(rawValue: "p-old"), displayName: "Samuel Carter", origin: .voiceNaming, at: .distantPast)
        old.mergedInto = sam.id
        var me = Person(id: PersonID(rawValue: "p-me"), displayName: owner, origin: .voiceNaming, at: .distantPast)
        me.isOwner = true
        let refs = PersonReferences(people: [sam, old, me])
        XCTAssertEqual(NextTimeInvite.personIDs(["sam@example.com", "Dana Lee", "jo@example.com"], people: refs), ["p-sam"])
        var book = NextTimeBook()
        book.add("Offsite budget", personID: "p-old", personName: "Samuel Carter", at: now)
        XCTAssertEqual(book.points(for: nil, people: ["p-sam"], canonical: refs.canonical).count, 1)
    }

    // C1
    func testRecurringMeetingsLookFurtherAheadThanTheLists() {
        XCTAssertGreaterThanOrEqual(UpcomingMeeting.seriesDays, 45)
        XCTAssertEqual(UpcomingMeeting.days, 7)
    }

    // L4
    func testASuggestionKeyFollowsTheItemsWordsNotItsPlace() {
        var a = call("b", daysAgo: 7, speakers: ["Dana Lee", "Sam Carter"])
        a.actionItems = [ActionItem(owner: "Sam Carter", task: "Send the list")]
        var b = a
        b.actionItems.insert(ActionItem(owner: "Sam Carter", task: "Book a room"), at: 0)
        let records = [call("a", daysAgo: 14)]
        func keys(_ last: CallRecord) -> Set<String> {
            let s = catalog(records + [last])[0]
            return Set(SeriesSuggestion.make(for: s, records: records + [last], commitments: [], owner: OwnerIdentity(name: owner), points: [], answers: [], goal: nil, now: now).map(\.key))
        }
        XCTAssertTrue(keys(b).isSuperset(of: keys(a)))
    }

    // L1
    func testAPointTakesTheNewKeysOfItsSeries() {
        let first = catalog([call("a", daysAgo: 14), call("b", daysAgo: 7)])[0]
        var book = NextTimeBook()
        book.add("Hiring", series: first, at: now)
        let later = catalog([call("a", daysAgo: 14), call("b", daysAgo: 7), call("c", daysAgo: 1)])
        XCTAssertTrue(book.refreshKeys(later))
        XCTAssertTrue(book.points[0].seriesKeys?.contains("call:c") == true)
        XCTAssertFalse(book.refreshKeys(later))
    }

    // L5
    func testANewerBookIsReadAndNeverSaved() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("nt-\(UUID())")
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data(#"{"version": 99, "points": [], "answers": [], "checked": []}"#.utf8).write(to: dir.appendingPathComponent(NextTimeBook.fileName))
        XCTAssertNotNil(NextTimeBook.peek(in: dir))
        XCTAssertThrowsError(try NextTimeBook.change(in: dir) { $0.add("x", personID: "p", personName: "P") })
    }
}
