import XCTest
@testable import MossadCore

/// Recurring meetings: which meetings are one series, its cadence, what is useful to know about it, the owner's
/// points for next time, the coach's suggestions, and the check after a meeting.
final class SeriesTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let owner = "Dana Lee"
    private var utc: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }

    private var directory: PersonDirectory {
        PersonDirectory([.init(name: owner, email: "dana@example.com"), .init(name: "Sam Carter", email: "sam@example.com"),
                         .init(name: "Jo Park", email: nil), .init(name: "Riley Chen", email: nil)])
    }

    private func call(_ id: String, daysAgo: Double, title: String = "Platform TB", speakers: [String] = ["Dana Lee", "Sam Carter"],
                      seriesID: String? = nil, minutes: Double = 30, planned: Double? = nil, items: [ActionItem] = [], decisions: [Decision] = [],
                      lines: [(Int, Double, String)] = [], meetingID: String? = nil) -> CallRecord {
        let start = now.addingTimeInterval(-daysAgo * 86_400)
        var r = CallRecord(id: id, platform: .meet, bundleID: "", start: start, end: start.addingTimeInterval(minutes * 60), status: .written)
        r.calendarTitle = title
        r.calendarSeriesID = seriesID
        r.meetingID = meetingID
        for (i, name) in speakers.enumerated() { r.speakerNames[i == 0 ? "me:A" : "them:\(i)"] = name }
        if let planned {
            r.plannedStart = start
            r.plannedEnd = start.addingTimeInterval(planned * 60)
        }
        r.actionItems = items
        r.decisions = decisions
        r.utterances = lines.map { speaker, at, text in
            Utterance(track: speaker == 0 ? .me : .them, speakerLabel: speaker == 0 ? "A" : "\(speaker)", start: at, end: at + 10, text: text)
        }
        return r
    }

    private func invite(_ title: String = "Platform TB", inDays: Double = 2, attendees: [String] = ["Sam Carter"], seriesID: String? = nil,
                        recurring: Bool = false) -> UpcomingMeeting {
        UpcomingMeeting(title: title, start: now.addingTimeInterval(inDays * 86_400), end: now.addingTimeInterval(inDays * 86_400 + 1800),
                        attendees: attendees, platform: .meet, link: nil, seriesID: seriesID, isRecurring: recurring)
    }

    private func catalog(_ records: [CallRecord], upcoming: [UpcomingMeeting] = []) -> [MeetingSeries] {
        SeriesCatalog.build(records: records, upcoming: upcoming, owner: owner, directory: directory, calendar: utc)
    }

    // MARK: The catalog

    func testTwoMeetingsWithTheTitleAndThePeopleAreOneSeries() {
        let s = catalog([call("a", daysAgo: 14), call("b", daysAgo: 7), call("c", daysAgo: 3, title: "Budget review")])
        XCTAssertEqual(s.count, 1)
        XCTAssertEqual(s[0].meetings.map(\.id), ["b", "a"])
        XCTAssertEqual(s[0].id, "call:a")
        XCTAssertEqual(s[0].usualPeople, ["Sam Carter"])
    }

    func testTheSameTitleWithOtherPeopleIsAnotherSeries() {
        let s = catalog([call("a", daysAgo: 14, title: "1:1"), call("b", daysAgo: 7, title: "1:1"),
                         call("c", daysAgo: 13, title: "1:1", speakers: ["Dana Lee", "Jo Park"]), call("d", daysAgo: 6, title: "1:1", speakers: ["Dana Lee", "Jo Park"])])
        XCTAssertEqual(Set(s.map { Set($0.meetings.map(\.id)) }), [["a", "b"], ["c", "d"]])
    }

    func testAGeneratedTitleIsNoSeries() {
        var a = call("a", daysAgo: 14), b = call("b", daysAgo: 7)
        a.calendarTitle = nil; a.generatedTitle = "Platform TB"
        b.calendarTitle = nil; b.generatedTitle = "Platform TB"
        XCTAssertTrue(catalog([a, b]).isEmpty)
    }

    func testTheCalendarSeriesIDJoinsMeetingsWhateverTheTitleAndGivesTheID() {
        let s = catalog([call("a", daysAgo: 14, title: "TB", seriesID: "g1"), call("b", daysAgo: 7, title: "Platform TB (moved)", seriesID: "g1")])
        XCTAssertEqual(s.count, 1)
        XCTAssertEqual(s[0].id, "cal:g1")
        XCTAssertTrue(s[0].keys.isSuperset(of: ["cal:g1", "call:a", "call:b"]))
    }

    func testOneMeetingIsASeriesOnlyWhenTheCalendarSaysItRepeats() {
        XCTAssertTrue(catalog([call("a", daysAgo: 7)], upcoming: [invite()]).isEmpty)
        let s = catalog([call("a", daysAgo: 7)], upcoming: [invite(recurring: true)])
        XCTAssertEqual(s.count, 1)
        XCTAssertEqual(s[0].next?.title, "Platform TB")
        XCTAssertTrue(s[0].recurringInCalendar)
    }

    func testARepeatingInviteWithNoHistoryIsASeriesOfItsOwn() {
        let s = catalog([], upcoming: [invite("Design crit", seriesID: "g9")])
        XCTAssertEqual(s.map(\.id), ["cal:g9"])
        XCTAssertTrue(s[0].meetings.isEmpty)
    }

    func testTheNextInviteJoinsItsSeries() {
        let s = catalog([call("a", daysAgo: 14), call("b", daysAgo: 7)], upcoming: [invite(inDays: 3), invite(inDays: 10)])
        XCTAssertEqual(s[0].upcoming.count, 2)
        XCTAssertEqual(SeriesCatalog.series(of: invite(inDays: 3), in: s)?.id, s[0].id)
        XCTAssertEqual(SeriesCatalog.series(ofCall: "a", in: s)?.id, s[0].id)
    }

    func testNotesOnlyMeetingsAreOccurrences() {
        var notes = call("n", daysAgo: 21)
        notes.source = CallRecord.geminiNotesSource
        let s = catalog([notes, call("a", daysAgo: 14)])
        XCTAssertEqual(s.first?.meetings.map(\.notesOnly), [false, true])
    }

    func testARepeatedMacEventHasTheSeriesUIDAsItsSeriesID() {
        let e = CalendarEventInfo(title: "Platform TB", start: now, end: now.addingTimeInterval(1800), attendees: [], text: "https://meet.google.com/abc-defg-hij", isAllDay: false)
        let repeated = e.from(eventKit: "UID-1", account: nil, recurring: true)
        XCTAssertEqual(repeated.seriesID, "ek:UID-1")
        XCTAssertNil(e.from(eventKit: "UID-1", account: nil).seriesID)
        XCTAssertEqual(UpcomingMeeting.from([repeated], now: now.addingTimeInterval(-60)).first?.isRecurring, true)
    }

    // MARK: Cadence

    func testTheCadenceSaysTheWeekdayAndTheTime() {
        let tuesday = utc.nextDate(after: now, matching: DateComponents(hour: 10, weekday: 3), matchingPolicy: .nextTime)!
        let dates = (0..<4).map { tuesday.addingTimeInterval(Double($0) * 7 * 86_400) }
        let c = SeriesCadence.from(dates, calendar: utc)
        XCTAssertEqual(c?.text, "Every Tuesday 10:00")
        XCTAssertEqual(SeriesCadence.from(dates.enumerated().filter { $0.offset % 2 == 0 }.map(\.element) + [tuesday.addingTimeInterval(28 * 86_400)], calendar: utc)?.rhythm,
                       .everyOtherWeek(weekday: utc.component(.weekday, from: tuesday)))
        XCTAssertNil(SeriesCadence.from([tuesday], calendar: utc))
    }

    func testATimeThatMovesIsNotSaid() {
        let d = utc.startOfDay(for: now)
        let dates = [d.addingTimeInterval(9 * 3600), d.addingTimeInterval(7 * 86_400 + 14 * 3600), d.addingTimeInterval(14 * 86_400 + 16 * 3600)]
        XCTAssertNil(SeriesCadence.from(dates, calendar: utc)?.hour)
    }

    // MARK: The report

    func testTheLineSaysOnlyWhatIsKnown() {
        let records = (0..<4).map { i in
            call("c\(i)", daysAgo: Double(28 - 7 * i), speakers: ["Dana Lee", "Sam Carter", "Jo Park"], minutes: 38, planned: 30,
                 lines: [(0, 0, "Hello all"), (1, 20, String(repeating: "word ", count: 40)), (1, 40, "more"), (2, 60, "ok")])
        }
        let s = catalog(records)[0]
        let report = SeriesReport(series: s, records: records, commitments: [], owner: OwnerIdentity(name: owner), directory: directory)
        XCTAssertEqual(report.line, "Usually 3 people, runs 8 min over, Sam talks most")
        XCTAssertEqual(report.ranOver, 4)
        XCTAssertEqual(report.medianMinutes, 38)
        XCTAssertEqual(report.attendees.map(\.name).sorted(), ["Jo Park", "Sam Carter"])
    }

    func testFewPlannedMeetingsSayNothingOfTheOverrun() {
        let records = [call("a", daysAgo: 14, planned: 20), call("b", daysAgo: 7)]
        let report = SeriesReport(series: catalog(records)[0], records: records, commitments: nil, owner: OwnerIdentity(name: owner), directory: directory)
        XCTAssertNil(report.usualOverrun)
        XCTAssertEqual(report.line, "Usually 2 people")
    }

    func testOpenItemsAreTheOwnersTasksTheOthersItemsAndOpenDecisions() {
        let last = call("b", daysAgo: 7, items: [ActionItem(owner: "Sam Carter", task: "Send the vendor list"), ActionItem(owner: "Dana Lee", task: "Book the room")],
                        decisions: [Decision(text: "Pricing change is pending legal review"), Decision(text: "Ship on Friday")])
        let records = [call("a", daysAgo: 14), last]
        var task = Commitment(text: "Share the roadmap", to: "Sam Carter", callID: "a", callTitle: "Platform TB", madeAt: now, due: nil)
        task.at = 30
        let report = SeriesReport(series: catalog(records)[0], records: records, commitments: [task], owner: OwnerIdentity(name: owner), directory: directory)
        XCTAssertEqual(Set(report.openItems.map(\.text)), ["Share the roadmap", "Send the vendor list", "Pricing change is pending legal review"])
        XCTAssertEqual(report.line, "Usually 2 people; 3 open items")
    }

    func testGapsCountTheWeeksWithNoMeeting() {
        let records = [call("a", daysAgo: 28), call("b", daysAgo: 21), call("c", daysAgo: 7), call("d", daysAgo: 0)]
        let report = SeriesReport(series: catalog(records)[0], records: records, commitments: nil, owner: OwnerIdentity(name: owner), directory: directory)
        XCTAssertEqual(report.gaps, 1)
    }

    // MARK: The book

    func testPointsKeepTheirOrderAndFindTheirSeriesByAnyKey() {
        let s = catalog([call("a", daysAgo: 14), call("b", daysAgo: 7)])[0]
        var book = NextTimeBook()
        let one = book.add("Ask about the API sunset", series: s, at: now)!
        let two = book.add("Hiring plan", series: s, at: now)!
        book.reorder([two.id, one.id], at: now)
        XCTAssertEqual(book.points(of: s).open.map(\.text), ["Hiring plan", "Ask about the API sunset"])
        // The series got a Google id later: the saved keys still find it.
        var moved = s
        moved.id = "cal:new"
        moved.keys = ["cal:new", "call:a", "call:b", "call:c"]
        XCTAssertEqual(book.points(of: moved).open.count, 2)
        XCTAssertNil(book.add("   ", series: s))
    }

    func testTakingBackAFoundDoneNeverFindsItInThatMeetingAgain() {
        let s = catalog([call("a", daysAgo: 14), call("b", daysAgo: 7)])[0]
        var book = NextTimeBook()
        let p = book.add("Hiring plan", series: s, at: now.addingTimeInterval(-30 * 86_400))!
        NextTimeRules.apply([.init(point: p.id, at: 12, quote: "the hiring plan")], checked: [p], call: call("b", daysAgo: 7), to: &book, at: now)
        XCTAssertEqual(book.discussed(in: "b").map(\.id), [p.id])
        book.toggleDone(p.id, at: now)
        XCTAssertTrue(book.points.first!.isOpen)
        XCTAssertTrue(NextTimeRules.points(for: call("b", daysAgo: 7), in: book, series: s, people: PersonReferences(people: [])).isEmpty)
    }

    func testAnUndiscussedPointIsCarried() {
        let s = catalog([call("a", daysAgo: 14), call("b", daysAgo: 7)])[0]
        var book = NextTimeBook()
        let p = book.add("Hiring plan", series: s, at: now.addingTimeInterval(-30 * 86_400))!
        NextTimeRules.apply([], checked: [p], call: call("b", daysAgo: 7), to: &book, at: now)
        XCTAssertEqual(book.points[0].carried, ["b"])
        XCTAssertTrue(book.checked.contains("b"))
    }

    func testAPointIsCheckedOnlyAgainstMeetingsAfterItWasMade() {
        let s = catalog([call("a", daysAgo: 14), call("b", daysAgo: 7)])[0]
        var book = NextTimeBook()
        book.add("Hiring plan", series: s, at: now.addingTimeInterval(-10 * 86_400))
        let records = [call("a", daysAgo: 14), call("b", daysAgo: 7)]
        XCTAssertEqual(NextTimeRules.pending(records, book: book).map(\.id), ["b"])
        XCTAssertTrue(NextTimeRules.points(for: records[0], in: book, series: s, people: PersonReferences(people: [])).isEmpty)
    }

    func testTheNewerCopyOfAPointWinsAndAnswersJoin() {
        var mac = NextTimeBook()
        let p = mac.add("Hiring plan", personID: "p1", personName: "Sam Carter", at: now)!
        var phone = mac
        phone.update(p.id, at: now.addingTimeInterval(60)) { $0.text = "Hiring plan for Q3" }
        mac.answers = [SuggestionAnswer(key: "goal:x", kind: "goal", verdict: .dismiss, date: now)]
        let merged = mac.merged(with: phone)
        XCTAssertEqual(merged.points.map(\.text), ["Hiring plan for Q3"])
        XCTAssertEqual(merged.answers.count, 1)
        XCTAssertEqual(merged.points(forPerson: "p1").count, 1)
    }

    func testThePersonPageShowsThePointsOfAPersonMergedIntoThisOne() {
        var book = NextTimeBook()
        book.add("Hiring plan", personID: "p1", personName: "Sam Carter", at: now)
        book.add("Budget", personID: "p2", personName: "S. Carter", at: now.addingTimeInterval(1))
        var a = Person(id: PersonID(rawValue: "p1"), displayName: "Sam Carter", origin: .voiceNaming, at: now)
        let b = Person(id: PersonID(rawValue: "p2"), displayName: "S. Carter", origin: .voiceNaming, at: now)
        XCTAssertEqual(book.points(forPerson: "p2", people: [a, b]).map(\.text), ["Budget"])
        a.mergedInto = b.id
        XCTAssertEqual(book.points(forPerson: "p2", people: [a, b]).map(\.text), ["Hiring plan", "Budget"])
        XCTAssertEqual(book.points(forPerson: "p1", people: [a, b]).map(\.text), ["Hiring plan", "Budget"])
    }

    func testTheBookSavesAndReads() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("series-\(UUID())")
        defer { try? FileManager.default.removeItem(at: dir) }
        try NextTimeBook.change(in: dir) { $0.add("Hiring plan", personID: "p1", personName: "Sam Carter", at: now) }
        XCTAssertEqual(NextTimeBook.peek(in: dir)?.points.map(\.text), ["Hiring plan"])
        XCTAssertEqual(SharedPayload.nextTime(try NextTimeBook.load(from: dir)).key, "next-time")
        XCTAssertTrue(SharedPayload.isShared("next-time"))
    }

    // MARK: Suggestions

    private func suggestions(_ records: [CallRecord], commitments: [Commitment]? = [], points: [NextTimePoint] = [], answers: [SuggestionAnswer] = [],
                             goal: (String, Bool)? = nil, upcoming: [UpcomingMeeting] = []) -> [SeriesSuggestion] {
        let s = catalog(records, upcoming: upcoming)[0]
        return SeriesSuggestion.make(for: s, records: records, commitments: commitments, owner: OwnerIdentity(name: owner), points: points, answers: answers,
                                     goal: goal.map { (plan: $0.0, oneOnOne: $0.1) }, now: now, calendar: utc)
    }

    func testEachSuggestionHasASourceFromWhatMossadKnows() {
        let last = call("b", daysAgo: 7, items: [ActionItem(owner: "Sam Carter", task: "Send the vendor list"), ActionItem(owner: "Dana Lee", task: "Book it")],
                        decisions: [Decision(text: "Revisit the pricing next meeting", at: 90)],
                        lines: [(0, 10, "Before we go, what is the plan for the old billing service?"), (0, 20, "Okay, let us move on then."),
                                (1, 60, "Fine."), (0, 70, "Can you hear me?")])
        var due = Commitment(text: "Share the roadmap", to: "Sam", callID: "a", callTitle: "Platform TB", madeAt: now, at: 30, due: now.addingTimeInterval(86_400))
        due.created = now
        var later = due
        later.id = UUID()
        later.text = "Write the long plan"
        later.due = now.addingTimeInterval(60 * 86_400)
        let out = suggestions([call("a", daysAgo: 14), last], commitments: [due, later], goal: ("Leave room in 1:1s", true), upcoming: [invite(inDays: 2)])
        XCTAssertEqual(out.map(\.kind), [.openItem, .promise, .pendingDecision, .unanswered, .goal])
        XCTAssertEqual(out[0].text, "Ask Sam about: Send the vendor list")
        XCTAssertEqual(out[0].source.callID, "b")
        XCTAssertEqual(out[1].source.commitment, due.id)
        XCTAssertEqual(out[2].source.at, 90)
        XCTAssertEqual(out[3].text, "Ask again: \u{201C}Before we go, what is the plan for the old billing service?\u{201D}")
        XCTAssertEqual(out[3].source.at, 10)
        XCTAssertNil(out[4].source.callID)
    }

    func testAOneOnOneGoalIsNotSuggestedForAGroup() {
        let records = [call("a", daysAgo: 14, speakers: ["Dana Lee", "Sam Carter", "Jo Park"]), call("b", daysAgo: 7, speakers: ["Dana Lee", "Sam Carter", "Jo Park"])]
        XCTAssertTrue(suggestions(records, goal: ("Leave room", true)).isEmpty)
        XCTAssertEqual(suggestions(records, goal: ("Open with the decision", false)).map(\.kind), [.goal])
    }

    func testDismissalsLowerAKindAndNeverBlocksIt() {
        let records = [call("a", daysAgo: 14), call("b", daysAgo: 7, items: [ActionItem(owner: "Sam Carter", task: "Send the vendor list")])]
        XCTAssertEqual(suggestions(records).count, 1)
        let no = (0..<2).map { SuggestionAnswer(key: "openItem:old\($0)", kind: "openItem", verdict: .dismiss, date: now) }
        XCTAssertTrue(suggestions(records, answers: no).isEmpty)
        // Old answers no longer count.
        let old = no.map { a -> SuggestionAnswer in var a = a; a.date = now.addingTimeInterval(-100 * 86_400); return a }
        XCTAssertEqual(suggestions(records, answers: old).count, 1)
        XCTAssertTrue(suggestions(records, answers: [SuggestionAnswer(key: "x", kind: "openItem", verdict: .never, date: .distantPast)]).isEmpty)
        // An answered suggestion does not come again.
        XCTAssertTrue(suggestions(records, answers: [SuggestionAnswer(key: "openItem:b:\(PersonNames.key("Send the vendor list"))", kind: "openItem", verdict: .keep, date: now)]).isEmpty)
    }

    func testAPointTheOwnerWroteIsNotSuggestedAgain() {
        let records = [call("a", daysAgo: 14), call("b", daysAgo: 7, items: [ActionItem(owner: "Sam Carter", task: "Send the vendor list")])]
        let point = NextTimePoint(text: "Ask Sam about the vendor list", rank: 1)
        XCTAssertTrue(suggestions(records, points: [point]).isEmpty)
    }

    func testKeepMovesASuggestionIntoTheOwnersListAndUndoTakesItBack() {
        let records = [call("a", daysAgo: 14), call("b", daysAgo: 7, items: [ActionItem(owner: "Sam Carter", task: "Send the vendor list")])]
        let s = catalog(records)[0]
        let suggestion = suggestions(records)[0]
        var book = NextTimeBook()
        book.add(suggestion.text, series: s, suggestion: suggestion.key, at: now)
        book.answer(suggestion, .keep, at: now)
        XCTAssertEqual(book.points(of: s).open.map(\.suggestion), [suggestion.key])
        book.takeBack(suggestion.key, at: now)
        XCTAssertTrue(book.points(of: s).open.isEmpty)
        // The answer stays as a mark, so a sync cannot bring it back.
        XCTAssertTrue(book.answers.allSatisfy { !$0.counts })
    }

    // MARK: The check

    func testADiscussedPointNeedsAQuoteThatIsInTheTranscript() async throws {
        let r = call("b", daysAgo: 1, lines: [(1, 120, "So about the API sunset next year, we plan to move everything by March."), (0, 200, "Great.")])
        let a = NextTimePoint(text: "API sunset plan", rank: 1), b = NextTimePoint(text: "Hiring", rank: 2), c = NextTimePoint(text: "Budget", rank: 3)
        let model = FakeModel(output: ["points": [
            ["point": "P1", "discussed": true, "quote": "about the API sunset next year, we plan"],
            ["point": "P2", "discussed": true, "quote": "we talked about hiring a lot"],
            ["point": "P3", "discussed": false, "quote": NSNull()],
        ]])
        let found = try await NextTimeChecker(llm: model).check([a, b, c], in: r)
        XCTAssertEqual(found.map(\.point), [a.id])
        XCTAssertEqual(found.first?.at, 120)
        XCTAssertTrue(model.user.contains("P1: API sunset plan"))
    }

    func testNoRequestWithoutPoints() async throws {
        let model = FailingCheckModel()
        let found = try await NextTimeChecker(llm: model).check([], in: call("b", daysAgo: 1, lines: [(0, 1, "Hello there")]))
        XCTAssertTrue(found.isEmpty)
        XCTAssertEqual(model.calls, 0)
    }

    func testAPersonsPointIsCheckedInAMeetingWhereTheySpoke() {
        let sam = Person(id: PersonID(rawValue: "p-sam"), displayName: "Sam Carter", origin: .voiceNaming, at: .distantPast)
        var book = NextTimeBook()
        book.add("Ask about the offsite", personID: "p-sam", personName: "Sam Carter", at: now.addingTimeInterval(-30 * 86_400))
        let refs = PersonReferences(people: [sam])
        XCTAssertEqual(NextTimeRules.points(for: call("x", daysAgo: 1, title: "Lunch"), in: book, series: nil, people: refs).count, 1)
        XCTAssertTrue(NextTimeRules.points(for: call("y", daysAgo: 1, speakers: ["Dana Lee", "Jo Park"]), in: book, series: nil, people: refs).isEmpty)
    }

    // MARK: Adding from words

    func testAddingFromChatFindsTheSeriesByWordsOrPerson() {
        let records = [call("a", daysAgo: 14), call("b", daysAgo: 7), call("c", daysAgo: 13, title: "Budget review", speakers: ["Dana Lee", "Jo Park"]),
                       call("d", daysAgo: 6, title: "Budget review", speakers: ["Dana Lee", "Jo Park"])]
        let all = catalog(records)
        var book = NextTimeBook()
        guard case .added(let p) = NextTimeAdd.add("Ask about the API sunset", series: "TB", person: nil, series: all, people: PersonReferences(people: []), book: &book) else {
            return XCTFail("not added")
        }
        XCTAssertEqual(p.seriesTitle, "Platform TB")
        guard case .added = NextTimeAdd.add("Q3 numbers", series: "Jo", person: nil, series: all, people: PersonReferences(people: []), book: &book) else {
            return XCTFail("not added by person")
        }
        if case .added = NextTimeAdd.add("x", series: "Standup", person: nil, series: all, people: PersonReferences(people: []), book: &book) { XCTFail("no such series") }
        XCTAssertTrue(ChatTools.allDefinitions.contains { $0.name == "add_next_time_point" })
        XCTAssertTrue(MCPServer.tools.contains { $0.name == "add_next_time_point" })
    }
}

/// Fails the test when asked: no request is expected.
final class FailingCheckModel: LanguageModel, @unchecked Sendable {
    private(set) var calls = 0
    func json<Output: Decodable>(system: String, user: String, schema: [String: Any], effort: Effort, purpose: UsageEvent.Purpose, as: Output.Type) async throws -> Output {
        calls += 1
        throw SummaryError.malformed
    }

    func runTools(system: String, history: [ChatMessage], question: String, tools: [ToolSpec], purpose: UsageEvent.Purpose,
                  execute: @escaping @Sendable (String, [String: Any]) -> String) async throws -> String { "" }
}
