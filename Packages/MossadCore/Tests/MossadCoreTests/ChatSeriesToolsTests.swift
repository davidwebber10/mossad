import XCTest
@testable import MossadCore

/// The calendar, the prep page, the recurring meetings, and the points for next time, as the tools read them.
final class ChatSeriesToolsTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private var paths: Paths!

    private var people: [Person] {
        let owner = Person(id: PersonID(rawValue: "id-owner"), displayName: "Avery Webb", isOwner: true, origin: .owner, at: now)
        var sam = Person(id: PersonID(rawValue: "id-sam"), displayName: "Sam Carter", origin: .migration, at: now)
        sam.emails = [EmailIdentity(address: "sam@example.com", state: .verified, source: .owner, at: now)]
        return [owner, sam]
    }

    override func setUpWithError() throws {
        paths = Paths(root: tempDirectory())
        try paths.ensureDirectories()
    }

    /// Two weekly meetings of one calendar series, the newest a week ago.
    private func records() -> [CallRecord] {
        (1...2).map { n in
            let start = now.addingTimeInterval(-Double(n) * 7 * 86_400)
            var r = CallRecord(id: "w\(n)", platform: .meet, bundleID: "b", start: start, end: start.addingTimeInterval(1800), status: .written)
            r.calendarTitle = "Weekly sync"
            r.calendarSeriesID = "g-weekly"
            r.attendees = ["Sam Carter"]
            r.speakerNames = ["me:A": "Avery Webb", "them:A": "Sam Carter"]
            r.speakerPeople = ["me:A": "id-owner", "them:A": "id-sam"]
            r.utterances = [Utterance(track: .me, speakerLabel: "A", start: 0, end: 600, text: "Let us go through the roadmap."),
                            Utterance(track: .them, speakerLabel: "A", start: 600, end: 1500, text: "The roadmap slips a week.")]
            r.decisions = [Decision(text: "Ship the beta in March")]
            r.actionItems = [ActionItem(owner: "Sam Carter", task: "Draft the launch plan", ownerID: "id-sam")]
            r.headline = "Roadmap review \(n)"
            return r
        }
    }

    private func saveCalendar() throws {
        var e = CalendarEventInfo(title: "Weekly sync", start: now.addingTimeInterval(86_400), end: now.addingTimeInterval(86_400 + 1800),
                                  attendees: ["Sam Carter", "Avery Webb"], text: "Agenda: secret notes https://meet.google.com/abc-defg-hij", isAllDay: false)
        e.seriesID = "g-weekly"
        e.isRecurring = true
        e.attachments = [EventAttachment(fileID: nil, title: "Plan", mimeType: nil, url: URL(string: "https://docs.google.com/x"))]
        try CalendarSnapshot([e], saved: now.addingTimeInterval(-600)).save(to: paths.calendar)
    }

    private var tools: ChatTools {
        ChatTools(records: records(), owner: "Avery Webb", paths: paths, people: people, settings: ToolSettings(), now: now)
    }

    func testTheSnapshotKeepsOnlyTheAllowedFields() throws {
        try saveCalendar()
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: paths.calendar.appendingPathComponent(CalendarSnapshot.fileName))) as? [String: Any])
        XCTAssertTrue(Set(json.keys).isSubset(of: CalendarSnapshot.allowedKeys["root"]!))
        for event in json["events"] as? [[String: Any]] ?? [] {
            XCTAssertTrue(Set(event.keys).isSubset(of: CalendarSnapshot.allowedKeys["event"]!), "\(event.keys)")
        }
        let text = String(decoding: try Data(contentsOf: paths.calendar.appendingPathComponent(CalendarSnapshot.fileName)), as: UTF8.self)
        XCTAssertFalse(text.contains("secret notes"), "never the event's notes")
        XCTAssertFalse(text.contains("docs.google.com"), "never the attachments")
        XCTAssertTrue(text.contains("meet.google.com"), "the call link, which the lists need")
    }

    func testUpcomingNeedsTheCalendarAndNamesItsAge() throws {
        XCTAssertEqual(tools.run("upcoming_meetings", input: [:]), ChatTools.noCalendar)
        try saveCalendar()
        let text = tools.run("upcoming_meetings", input: [:])
        XCTAssertTrue(text.contains("Calendar as Mossad read it"), text)
        XCTAssertTrue(text.contains("upcoming_id: upcoming:"), text)
        XCTAssertTrue(text.contains("Weekly sync"), text)
        XCTAssertTrue(text.contains("invited: Sam Carter"), "without the owner: \(text)")
        XCTAssertTrue(text.contains("series_id: cal:g-weekly"), text)
        XCTAssertFalse(text.contains("meet.google.com"), "no link in the answer")
    }

    func testPrepShowsLastTimeThePeopleAndYourPoints() throws {
        try saveCalendar()
        var book = NextTimeBook()
        let series = try XCTUnwrap(tools.catalog(now: now).all.first)
        _ = book.add("Ask about the beta date", series: series, at: now)
        try book.save(to: paths.nextTime)
        let text = tools.run("prep", input: [:])
        XCTAssertTrue(text.contains("Last time in this series"), text)
        XCTAssertTrue(text.contains("call_id: w1"), text)
        XCTAssertTrue(text.contains("Ship the beta in March"), text)
        XCTAssertTrue(text.contains("Sam Carter: Draft the launch plan"), text)
        XCTAssertTrue(text.contains("Sam Carter (person_id: id-sam)"), text)
        XCTAssertTrue(text.contains("Ask about the beta date"), text)
        XCTAssertTrue(tools.run("prep", input: ["meeting": "No such call"]).contains("No upcoming call matches"))
    }

    func testRecurringListsTheSeriesWithItsSchedule() throws {
        try saveCalendar()
        let text = tools.run("recurring", input: [:])
        XCTAssertTrue(text.contains("series_id: cal:g-weekly | Weekly sync"), text)
        XCTAssertTrue(text.contains("2 recorded"), text)
        XCTAssertTrue(text.contains("usually: Sam Carter"), text)
    }

    func testReadSeriesHasHistoryPeopleNumbersAndOpenItems() throws {
        let text = tools.run("read_series", input: ["series": "Weekly sync"])
        XCTAssertTrue(text.contains("History (2 of 2)"), text)
        XCTAssertTrue(text.contains("call_id: w1"), text)
        XCTAssertTrue(text.contains("Sam Carter: came 2 of 2"), text)
        XCTAssertTrue(text.contains("Numbers: 2 meetings"), text)
        XCTAssertTrue(text.contains("Draft the launch plan"), "the others' items of the last meeting: \(text)")
        XCTAssertTrue(tools.run("read_series", input: ["series": "Nothing like it"]).hasPrefix("No recurring meeting matches"))
    }

    func testNextTimePointsSayWhatHappenedToEachPoint() throws {
        var book = NextTimeBook()
        let series = try XCTUnwrap(tools.catalog(now: now).all.first)
        let open = try XCTUnwrap(book.add("Ask about the beta date", series: series, at: now))
        let done = try XCTUnwrap(book.add("Thank Sam for the demo", personID: "id-sam", personName: "Sam Carter", at: now))
        book.update(done.id, at: now) { $0.done = NextTimePoint.Discussed(callID: "w1", at: 65, quote: "thanks for the demo", date: now, byOwner: false) }
        book.update(open.id, at: now) { $0.carried = ["w1"] }
        try book.save(to: paths.nextTime)
        let openText = tools.run("next_time_points", input: [:])
        XCTAssertTrue(openText.contains("Ask about the beta date"), openText)
        XCTAssertTrue(openText.contains("carried over 1 meeting"), openText)
        XCTAssertFalse(openText.contains("Thank Sam"), "open only by default")
        let all = tools.run("next_time_points", input: ["status": "all", "person": "Sam Carter"])
        XCTAssertTrue(all.contains("Thank Sam for the demo") && all.contains("discussed in call_id w1 at 00:01:05"), all)
        XCTAssertTrue(all.contains("\u{201C}thanks for the demo\u{201D}"), all)
        XCTAssertFalse(all.contains("Ask about the beta date"), "only the person's points")
    }
}
