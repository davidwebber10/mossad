import XCTest
@testable import MossadCore

/// The owner's points around a meeting: a meeting the owner missed never closes or carries them, the points during
/// the call (the local pre-check, the request bounds, the header's accent), and what the check after the call
/// makes of a live mark.
final class LivePointsTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let owner = "Dana Lee"

    private func call(_ id: String, daysAgo: Double, title: String = "Platform TB", notesOnly: Bool = false,
                      lines: [(Int, Double, String)] = [(0, 5, "Hello all"), (1, 20, "Hello")]) -> CallRecord {
        let start = now.addingTimeInterval(-daysAgo * 86_400)
        var r = CallRecord(id: id, platform: .meet, bundleID: "", start: start, end: start.addingTimeInterval(1800), status: .written)
        r.calendarTitle = title
        r.speakerNames = ["me:A": owner, "them:1": "Sam Carter"]
        if notesOnly { r.source = CallRecord.geminiNotesSource }
        r.utterances = lines.map { s, at, text in Utterance(track: s == 0 ? .me : .them, speakerLabel: s == 0 ? "A" : "\(s)", start: at, end: at + 10, text: text) }
        return r
    }

    private func series(_ records: [CallRecord]) -> MeetingSeries {
        SeriesCatalog.build(records: records, upcoming: [], owner: owner, directory: PersonDirectory())[0]
    }

    // MARK: A meeting the owner missed

    func testAMeetingTheOwnerMissedNeitherClosesNorCarriesAPoint() {
        let s = series([call("a", daysAgo: 14), call("b", daysAgo: 7)])
        var book = NextTimeBook()
        let found = book.add("API sunset plan", series: s, at: now.addingTimeInterval(-30 * 86_400))!
        let other = book.add("Hiring", series: s, at: now.addingTimeInterval(-30 * 86_400))!
        // Notes only, and no line of the owner's: the owner was not there.
        let missed = call("c", daysAgo: 1, notesOnly: true, lines: [(1, 120, "About the API sunset next year, we plan to move by March.")])
        XCTAssertTrue(NextTimeRules.ownerMissed(missed))
        NextTimeRules.apply([.init(point: found.id, at: 120, quote: "the API sunset next year, we plan")], checked: [found, other], call: missed, to: &book, at: now)
        let a = book.points.first { $0.id == found.id }!, b = book.points.first { $0.id == other.id }!
        XCTAssertTrue(a.isOpen)
        XCTAssertNil(a.carried)
        XCTAssertEqual(a.mentions, [.init(callID: "c", at: 120, quote: "the API sunset next year, we plan", date: missed.start)])
        XCTAssertTrue(b.isOpen)
        XCTAssertNil(b.carried)
        XCTAssertNil(b.mentions)
        XCTAssertEqual(book.mentioned(in: "c").map(\.id), [found.id])
        XCTAssertTrue(book.discussed(in: "c").isEmpty)
        XCTAssertTrue(book.checked.contains("c"))
    }

    func testAMeetingTheOwnerAttendedClosesAsBefore() {
        // A recording, and a notes-only meeting with a line of the owner's.
        let recording = call("c", daysAgo: 1)
        let spoke = call("d", daysAgo: 1, notesOnly: true, lines: [(0, 10, "Let us start with the API sunset next year please")])
        XCTAssertFalse(NextTimeRules.ownerMissed(recording))
        XCTAssertFalse(NextTimeRules.ownerMissed(spoke))
        let s = series([call("a", daysAgo: 14), call("b", daysAgo: 7)])
        var book = NextTimeBook()
        let p = book.add("API sunset", series: s, at: now.addingTimeInterval(-30 * 86_400))!
        NextTimeRules.apply([.init(point: p.id, at: 10, quote: "the API sunset next year please")], checked: [p], call: spoke, to: &book, at: now)
        XCTAssertEqual(book.points[0].done?.callID, "d")
        XCTAssertNil(book.points[0].mentions)
    }

    func testAMentionIsKeptOncePerMeeting() {
        var book = NextTimeBook()
        let p = book.add("Hiring", personID: "p1", personName: "Sam Carter", at: now)!
        let m = NextTimePoint.Mention(callID: "c", at: 5, quote: "we need to talk about hiring soon", date: now)
        book.mention(p.id, m, at: now)
        book.mention(p.id, m, at: now)
        XCTAssertEqual(book.points[0].mentions?.count, 1)
    }

    // MARK: The mention in the file

    func testAnOlderBuildThatSavesThePointLosesNoMentionAfterTheMerge() throws {
        var mac = NextTimeBook()
        let p = mac.add("Hiring", personID: "p1", personName: "Sam Carter", at: now)!
        mac.mention(p.id, .init(callID: "c", at: 5, quote: "we need to talk about hiring soon", date: now), at: now.addingTimeInterval(10))
        // An older build reads the file, which it can, and saves an edit without the field it does not know.
        let data = try JSONEncoder.coach.encode(mac)
        var json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        var points = json["points"] as! [[String: Any]]
        XCTAssertNotNil(points[0]["mentions"])
        points[0]["mentions"] = nil
        points[0]["text"] = "Hiring in Q3"
        points[0]["updated"] = ISO8601DateFormatter().string(from: now.addingTimeInterval(1000))
        json["points"] = points
        let older = try JSONDecoder.coach.decode(NextTimeBook.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertNil(older.points[0].mentions)
        XCTAssertEqual(older.version, 1)
        // The newer edit wins, and the mention comes back from the copy that has it, both ways.
        for merged in [mac.merged(with: older), older.merged(with: mac)] {
            XCTAssertEqual(merged.points[0].text, "Hiring in Q3")
            XCTAssertEqual(merged.points[0].mentions?.map(\.callID), ["c"])
        }
        // Without mentions on either side the merge changes nothing.
        var plain = NextTimeBook()
        plain.add("Budget", personID: "p1", personName: "Sam Carter", at: now)
        XCTAssertEqual(plain.merged(with: plain), plain)
    }

    func testTheVersionStaysOneSoOlderBuildsKeepSaving() throws {
        XCTAssertEqual(NextTimeBook.currentVersion, 1)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mention-\(UUID())")
        defer { try? FileManager.default.removeItem(at: dir) }
        try NextTimeBook.change(in: dir) { book in
            let p = book.add("Hiring", personID: "p1", personName: "Sam Carter", at: now)!
            book.mention(p.id, .init(callID: "c", at: 5, quote: "we need to talk about hiring soon", date: now))
        }
        XCTAssertEqual(NextTimeBook.peek(in: dir)?.points[0].mentions?.first?.quote, "we need to talk about hiring soon")
    }

    // MARK: The pre-check

    func testThePreCheckTable() {
        let cases: [(point: String, line: String, may: Bool, why: String)] = [
            ("Ask about the API sunset", "What's the plan for the API sunset next year?", true, "the key words"),
            ("Hiring plan for Q3", "In Q3 we need to hire two engineers", true, "stems and a number"),
            ("Raise the 15% price increase", "Can we go over the 15 percent increase", true, "a number weighs double"),
            ("Ask Sam about the vendor contract", "Sam, where are we on the vendor contract?", true, "a name and the subject"),
            ("Hiring", "Can we talk hiring for a minute", true, "a point of one word"),
            ("Q3 hiring plan", "We planned the offsite for Q4", false, "near miss: another quarter"),
            ("Ask Sam about the vendor contract", "Sam, how are you doing today?", false, "near miss: the name alone"),
            ("Budget for the offsite", "How much money can we spend on the offsite", false, "paraphrase with one shared word"),
            ("Budget for the offsite", "What will this cost us", false, "paraphrase with no shared word"),
            ("Ask about the API sunset", "Let me ask you about something", false, "only the words of asking"),
        ]
        for c in cases {
            XCTAssertEqual(LivePointMatch.mayHaveComeUp(c.point, in: c.line), c.may, "\(c.why): \(c.point) / \(c.line)")
        }
    }

    func testOnlyTheOwnersOwnFinalLinesStartARequest() {
        let p = NextTimePoint(text: "API sunset plan", rank: 1)
        let theirs = LiveEntry(time: 30, who: "Sam Carter", text: "The API sunset plan is ready", isFinal: true, mine: false)
        let draft = LiveEntry(time: 40, who: owner, text: "So the API sunset plan", isFinal: false, mine: true)
        XCTAssertTrue(LivePointRules.due([p], entries: [theirs, draft], marks: .init(), now: 60, transcriptOn: true).isEmpty)
        let mine = LiveEntry(time: 50, who: owner, text: "Where are we on the API sunset plan?", isFinal: true, mine: true)
        let due = LivePointRules.due([p], entries: [theirs, mine], marks: .init(), now: 60, transcriptOn: true)
        XCTAssertEqual(due.map(\.point.id), [p.id])
        // The lines around the owner's go with it, so an answer by another speaker can be the proof.
        XCTAssertEqual(due.first?.lines.count, 2)
        XCTAssertEqual(due.first?.through, 50)
    }

    // MARK: The bounds

    func testRequestBounds() {
        let p = NextTimePoint(text: "API sunset plan", rank: 1)
        let line = { (t: Double) in LiveEntry(time: t, who: self.owner, text: "Back to the API sunset plan", isFinal: true, mine: true) }
        // No request when the live transcript is off.
        XCTAssertTrue(LivePointRules.due([p], entries: [line(10)], marks: .init(), now: 20, transcriptOn: false).isEmpty)
        var marks = LivePointMarks()
        marks.asks = [.init(point: p.id, at: 20, through: 10)]
        // One request per point per 3 minutes, and only for lines after the last one read.
        XCTAssertTrue(LivePointRules.due([p], entries: [line(10), line(100)], marks: marks, now: 199, transcriptOn: true).isEmpty)
        XCTAssertTrue(LivePointRules.due([p], entries: [line(10)], marks: marks, now: 400, transcriptOn: true).isEmpty)
        XCTAssertEqual(LivePointRules.due([p], entries: [line(10), line(100)], marks: marks, now: 200, transcriptOn: true).count, 1)
        // At most 12 in a call, across points.
        let many = (0..<20).map { NextTimePoint(text: "API sunset plan \($0)", rank: Double($0)) }
        XCTAssertEqual(LivePointRules.due(many, entries: [line(10)], marks: .init(), now: 20, transcriptOn: true).count, 12)
        var spent = LivePointMarks()
        spent.asks = (0..<11).map { _ in .init(point: UUID(), at: 0, through: 0) }
        XCTAssertEqual(LivePointRules.due(many, entries: [line(10)], marks: spent, now: 20, transcriptOn: true).count, 1)
        // A point heard or ticked is not asked about.
        var heard = LivePointMarks()
        heard.add(.init(point: p.id, at: 10, quote: "back to the API sunset plan"))
        XCTAssertTrue(LivePointRules.due([p], entries: [line(10)], marks: heard, now: 20, transcriptOn: true).isEmpty)
        var ticked = p
        ticked.done = .init(callID: "live", at: 15, quote: nil, date: now, byOwner: true)
        XCTAssertTrue(LivePointRules.due([ticked], entries: [line(10)], marks: .init(), now: 20, transcriptOn: true).isEmpty)
    }

    func testTheConfirmationNeedsAQuoteFromALineSent() async throws {
        let p = NextTimePoint(text: "API sunset plan", rank: 1)
        let lines = [LiveEntry(time: 50, who: owner, text: "Where are we on the API sunset plan for next year?", isFinal: true, mine: true)]
        let due = LivePointRules.Due(point: p, lines: lines, through: 50)
        let good = FakeModel(output: ["raised": true, "quote": "where are we on the API sunset plan"])
        let mark = try await LivePointConfirmer(llm: good).confirm(due)
        XCTAssertEqual(mark, .init(point: p.id, at: 50, quote: "Where are we on the API sunset plan"))
        XCTAssertTrue(good.user.contains("API sunset plan"))
        let made = FakeModel(output: ["raised": true, "quote": "we agreed to move the API sunset to March"])
        let none = try await LivePointConfirmer(llm: made).confirm(due)
        XCTAssertNil(none)
        let no = FakeModel(output: ["raised": false, "quote": NSNull()])
        let notRaised = try await LivePointConfirmer(llm: no).confirm(due)
        XCTAssertNil(notRaised)
    }

    // MARK: The header

    func testTheHeaderTurnsToTheAccentNearThePlannedEndWithPointsOpen() {
        let end = now.addingTimeInterval(600)
        XCTAssertFalse(LivePointRules.nearEnd(plannedEnd: end, now: now, open: 2))
        XCTAssertFalse(LivePointRules.nearEnd(plannedEnd: end, now: end.addingTimeInterval(-301), open: 2))
        XCTAssertTrue(LivePointRules.nearEnd(plannedEnd: end, now: end.addingTimeInterval(-300), open: 2))
        XCTAssertTrue(LivePointRules.nearEnd(plannedEnd: end, now: end.addingTimeInterval(120), open: 1))
        XCTAssertFalse(LivePointRules.nearEnd(plannedEnd: end, now: end.addingTimeInterval(-60), open: 0))
        XCTAssertFalse(LivePointRules.nearEnd(plannedEnd: nil, now: now, open: 3))
        // Open means neither ticked nor heard.
        var ticked = NextTimePoint(text: "A", rank: 1)
        ticked.done = .init(callID: "live", at: 1, quote: nil, date: now, byOwner: true)
        let heard = NextTimePoint(text: "B", rank: 2), open = NextTimePoint(text: "C", rank: 3)
        var marks = LivePointMarks()
        marks.add(.init(point: heard.id, at: 5, quote: "q"))
        XCTAssertEqual(LivePointRules.open([ticked, heard, open], marks: marks).map(\.text), ["C"])
    }

    // MARK: The list

    func testTheLiveListIsTheSeriesThenEachPersonWithTheTicksOfThisCall() {
        let earlier = [call("a", daysAgo: 14), call("b", daysAgo: 7)]
        let all = SeriesCatalog.build(records: earlier, upcoming: [], owner: owner, directory: PersonDirectory())
        var live = CallRecord(id: "live", platform: .meet, bundleID: "", start: now, end: now, status: .recording)
        live.calendarTitle = "Platform TB"
        live.attendees = ["Sam Carter"]
        let s = LivePoints.series(ofLive: live, in: all, records: earlier + [live], owner: owner, directory: PersonDirectory())
        XCTAssertEqual(s?.id, all[0].id)
        let sam = Person(id: PersonID(rawValue: "p-sam"), displayName: "Sam Carter", origin: .voiceNaming, at: .distantPast)
        let jo = Person(id: PersonID(rawValue: "p-jo"), displayName: "Jo Park", origin: .voiceNaming, at: .distantPast)
        let refs = PersonReferences(people: [sam, jo])
        XCTAssertEqual(LivePoints.personIDs(attendees: live.attendees, heard: ["Jo Park", "Sam Carter"], people: refs), ["p-sam", "p-jo"])
        var book = NextTimeBook()
        let one = book.add("API sunset", series: s, at: now)!
        let two = book.add("Hiring", series: s, at: now)!
        book.add("Offsite", personID: "p-jo", personName: "Jo Park", at: now)
        let old = book.add("Old", series: s, at: now)!
        book.update(old.id) { $0.done = .init(callID: "earlier", at: nil, quote: nil, date: now, byOwner: true) }
        book.update(two.id) { $0.done = .init(callID: "live", at: 30, quote: nil, date: now, byOwner: true) }
        let list = LivePoints.list(book, series: s, people: ["p-sam", "p-jo"], callID: "live")
        XCTAssertEqual(list.map(\.text), ["API sunset", "Hiring", "Offsite"])
        XCTAssertEqual(list.first?.id, one.id)
        // A call with no title of the calendar has no series.
        var untitled = live
        untitled.calendarTitle = nil
        XCTAssertNil(LivePoints.series(ofLive: untitled, in: all, records: earlier, owner: owner, directory: PersonDirectory()))
    }

    // MARK: After the call

    func testTheCheckAfterTheCallIsTheTruthForLiveMarks() {
        let s = series([call("a", daysAgo: 14), call("b", daysAgo: 7)])
        var book = NextTimeBook()
        let confirmed = book.add("API sunset", series: s, at: now.addingTimeInterval(-30 * 86_400))!
        let unsupported = book.add("Hiring", series: s, at: now.addingTimeInterval(-30 * 86_400))!
        let ticked = book.add("Budget", series: s, at: now.addingTimeInterval(-30 * 86_400))!
        let r = call("c", daysAgo: 1)
        // During the call: the owner ticked one; Mossad heard two.
        book.update(ticked.id) { $0.done = .init(callID: "c", at: 400, quote: nil, date: now, byOwner: true) }
        var marks = LivePointMarks()
        marks.add(.init(point: confirmed.id, at: 100, quote: "the API sunset next year please now"))
        marks.add(.init(point: unsupported.id, at: 200, quote: "and then the hiring for the team"))
        // After the call: the ticked point is not checked at all.
        let checked = NextTimeRules.points(for: r, in: book, series: s, people: PersonReferences(people: []))
        XCTAssertEqual(Set(checked.map(\.id)), [confirmed.id, unsupported.id])
        let found = [NextTimeChecker.Found(point: confirmed.id, at: 101, quote: "the API sunset next year please")]
        let result = LivePointRules.reconcile(marks, found: found, checked: checked)
        XCTAssertEqual(result.confirmed, [confirmed.id])
        XCTAssertEqual(result.unsupported, [unsupported.id])
        NextTimeRules.apply(found, checked: checked, call: r, to: &book, at: now)
        let after = Dictionary(uniqueKeysWithValues: book.points.map { ($0.id, $0) })
        XCTAssertEqual(after[confirmed.id]?.done?.quote, "the API sunset next year please")
        XCTAssertTrue(after[unsupported.id]!.isOpen)
        XCTAssertEqual(after[unsupported.id]?.carried, ["c"])
        XCTAssertEqual(after[ticked.id]?.done?.byOwner, true)
        XCTAssertEqual(after[ticked.id]?.done?.at, 400)
    }

    func testARejectedMarkOpensThePointAndItsLineNeverMarksItAgain() throws {
        let p = NextTimePoint(text: "API sunset plan", rank: 1)
        var marks = LivePointMarks()
        marks.add(.init(point: p.id, at: 50, quote: "where are we on the API sunset plan"))
        marks.reject(p.id)
        XCTAssertNil(marks.mark(for: p.id))
        XCTAssertEqual(LivePointRules.open([p], marks: marks).map(\.id), [p.id])
        // The same line again: no mark. Another line later: a mark.
        marks.add(.init(point: p.id, at: 50, quote: "where are we on the API sunset plan"))
        XCTAssertNil(marks.mark(for: p.id))
        marks.add(.init(point: p.id, at: 400, quote: "so the API sunset plan is final then"))
        XCTAssertEqual(marks.mark(for: p.id)?.at, 400)
        // A file from before rejections reads.
        let old = try JSONDecoder().decode(LivePointMarks.self, from: Data(#"{"marks":[],"asks":[]}"#.utf8))
        XCTAssertNil(old.rejected)
    }

    func testTheMarksSaveAndRead() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("marks-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        XCTAssertNil(LivePointMarks.load(from: dir))
        var marks = LivePointMarks()
        let id = UUID()
        marks.add(.init(point: id, at: 5, quote: "q"))
        marks.add(.init(point: id, at: 9, quote: "again"))
        marks.asks.append(.init(point: id, at: 5, through: 5))
        try marks.save(to: dir)
        XCTAssertEqual(LivePointMarks.load(from: dir), marks)
        XCTAssertEqual(marks.marks.count, 1)
    }

    // MARK: The live chat

    func testTheLiveChatListsThePointsAndOffersTheChip() {
        let facts0 = LiveCallFacts(callID: "live", title: "Platform TB", platform: "Google Meet", start: now, invited: [], owner: owner)
        var facts = facts0
        let a = NextTimePoint(text: "API sunset", rank: 1)
        var b = NextTimePoint(text: "Hiring", rank: 2)
        b.done = .init(callID: "live", at: 724, quote: nil, date: now, byOwner: true)
        let c = NextTimePoint(text: "Budget", rank: 3)
        var marks = LivePointMarks()
        marks.add(.init(point: c.id, at: 65, quote: "the budget for next quarter is tight"))
        facts.points = LivePointFact.from([a, b, c], marks: marks, callID: "live")
        XCTAssertEqual(facts.points.filter(\.isOpen).map(\.text), ["API sunset"])
        let system = LiveChatPrompt.system(facts: facts, entries: [], summary: nil, openQuestions: [], now: now.addingTimeInterval(800))
        XCTAssertTrue(system.contains("- Open: API sunset"))
        XCTAssertTrue(system.contains("- Raised at [12:04]: Hiring (marked by Dana Lee)"))
        XCTAssertTrue(system.contains("- Raised at [01:05]: Budget (heard by Mossad"))
        XCTAssertFalse(LiveChatPrompt.system(facts: facts0, entries: [], summary: nil, openQuestions: [], now: now).contains("points for this call"))
        XCTAssertEqual(LiveChips.chips([], owner: owner, openQuestions: 0, openPoints: 1).map(\.label), ["My open points"])
        let entries = [LiveEntry(time: 5, who: "Sam Carter", text: "Hello", isFinal: true, mine: false)]
        XCTAssertEqual(LiveChips.chips(entries, owner: owner, openQuestions: 0, openPoints: 2).last?.label, "My open points")
        XCTAssertFalse(LiveChips.chips(entries, owner: owner, openQuestions: 0, openPoints: 0).contains { $0.label == "My open points" })
    }
}
