import XCTest
@testable import MossadCore

/// The tools of the other pages: bookmarks, a meeting's numbers, the coach's cards and goals, the share links,
/// the app's state, and the extended meeting tools. Never a token, a PIN, a key, or a fingerprint.
final class ChatPagesToolsTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private var paths: Paths!

    override func setUpWithError() throws {
        paths = Paths(root: tempDirectory())
        try paths.ensureDirectories()
    }

    private func record(_ id: String = "c1", days: Double = 1, notes: Bool = false) -> CallRecord {
        let start = now.addingTimeInterval(-days * 86_400)
        var r = CallRecord(id: id, platform: .zoom, bundleID: "b", start: start, end: start.addingTimeInterval(1800), status: .written)
        r.calendarTitle = "Budget review"
        r.speakerNames = ["me:A": "Avery Webb", "them:A": "Sam Carter"]
        r.utterances = [Utterance(track: .me, speakerLabel: "A", start: 0, end: 400, text: "Let me look at it and get back to you."),
                        Utterance(track: .them, speakerLabel: "A", start: 400, end: 1200, text: "When can we see the forecast?")]
        r.decisions = [Decision(text: "Hold the budget", at: 300)]
        r.actionItems = [ActionItem(owner: "Sam Carter", task: "Send the forecast")]
        r.markers = [TranscriptMarker(offset: 410, text: "Bookmark", isBookmark: true, note: "Forecast date")]
        r.kind = "Monthly update"
        r.summary = "The budget holds."
        if notes { r.source = CallRecord.geminiNotesSource }
        return r
    }

    private func tools(_ records: [CallRecord]? = nil, settings: ToolSettings = ToolSettings()) -> ChatTools {
        ChatTools(records: records ?? [record()], owner: "Avery Webb", paths: paths, people: [], settings: settings, now: now)
    }

    func testBookmarksGiveTheMomentTheNoteAndTheLine() {
        let text = tools().run("bookmarks", input: [:])
        XCTAssertTrue(text.contains("call_id: c1 | Budget review"), text)
        XCTAssertTrue(text.contains("at_seconds: 410") && text.contains("note: Forecast date"), text)
        XCTAssertTrue(text.contains("Sam Carter: When can we see the forecast?"), text)
        XCTAssertEqual(tools().run("bookmarks", input: ["query": "nothing like it"]), "No bookmarks match.")
    }

    func testReadMeetingHasTheSourceKindBookmarksAndYourPoints() throws {
        var book = NextTimeBook()
        let p = try XCTUnwrap(book.add("Ask for the forecast date", personID: "id-sam", personName: "Sam Carter", at: now))
        book.update(p.id, at: now) { $0.done = NextTimePoint.Discussed(callID: "c1", at: 400, quote: "When can we see the forecast", date: now, byOwner: false) }
        try book.save(to: paths.nextTime)
        let text = try XCTUnwrap(tools().readMeeting("c1"))
        XCTAssertTrue(text.contains("Platform: Zoom | Kind: Monthly update"), text)
        XCTAssertTrue(text.contains("[00:05:00] Hold the budget"), text)
        XCTAssertTrue(text.contains("Bookmarks:\n- [00:06:50] Forecast date"), text)
        XCTAssertTrue(text.contains("Your points discussed here:") && text.contains("Ask for the forecast date"), text)
        let notes = try XCTUnwrap(tools([record(notes: true)]).readMeeting("c1"))
        XCTAssertTrue(notes.contains("Source: Gemini notes"), notes)
    }

    func testFindMeetingsTakesTheFiltersChoicesAndCountsThem() {
        var group = record("c2", days: 2)
        group.platform = .meet
        group.speakerNames = ["me:A": "Avery Webb", "them:A": "Sam Carter", "them:B": "Dana Lee", "them:C": "Riley Chen"]
        group.utterances += [Utterance(track: .them, speakerLabel: "B", start: 1200, end: 1400, text: "Agreed."),
                             Utterance(track: .them, speakerLabel: "C", start: 1400, end: 1600, text: "Fine.")]
        group.actionItems = []
        let t = tools([record(), group])
        let zoom = t.run("find_meetings", input: ["platform": ["zoom"]])
        XCTAssertTrue(zoom.contains("call_id: c1") && !zoom.contains("call_id: c2"), zoom)
        let items = t.run("find_meetings", input: ["has": ["action_items"]])
        XCTAssertTrue(items.contains("call_id: c1") && !items.contains("call_id: c2"), items)
        let facets = t.run("find_meetings", input: ["facets": true])
        XCTAssertTrue(facets.contains("platform: zoom 1, meet 1"), facets)
        XCTAssertTrue(facets.contains("has: action_items 1, decisions 2"), facets)
        XCTAssertTrue(t.run("find_meetings", input: ["rating": ["high"]]).hasPrefix("No meetings match"), "no rating is never a high one")
    }

    func testMeetingAnalyticsGivesTheSpeakersAndSaysWhatIsNotKnown() {
        let text = tools().run("meeting_analytics", input: ["call_id": "c1"])
        XCTAssertTrue(text.contains("Speakers:"), text)
        XCTAssertTrue(text.contains("You (Avery Webb)"), text)
        XCTAssertTrue(text.contains("Sam Carter"), text)
        // The owner answered nobody: the reply time is not known, never 0.
        XCTAssertTrue(text.contains("You (Avery Webb)") && text.contains("reply after not known"), text)
        XCTAssertEqual(tools().run("meeting_analytics", input: ["call_id": "nope"]), "No meeting with that call_id.")
    }

    func testCoachFindingsListTheCardsOnlyWithTheCoachOn() throws {
        var review = CoachReview(headline: "H", overview: "", strengths: [], improvements: [], focusProgress: nil)
        review.tryNext = CoachNote(text: "When you take an item, say the day.", quote: "Let me look at it and get back to you.", at: 0,
                                   say: "I will send it by Friday.", skill: CoachSkill.commitmentDates.rawValue)
        try FileManager.default.createDirectory(at: paths.callDirectory("c1"), withIntermediateDirectories: true)
        try review.save(in: paths.callDirectory("c1"))
        XCTAssertTrue(tools().run("coach_findings", input: [:]).contains("The coach is off"))
        var on = ToolSettings()
        on.coach = true
        let text = tools(settings: on).run("coach_findings", input: [:])
        XCTAssertTrue(text.contains("When you take an item, say the day."), text)
        XCTAssertTrue(text.contains("call_id: c1"), text)
        XCTAssertTrue(text.contains("Say instead: \u{201C}I will send it by Friday.\u{201D}"), text)
        XCTAssertTrue(text.contains("It asks:"), text)
    }

    func testCoachGoalsSayThereIsNoneOrTheGoalAndItsCalls() throws {
        XCTAssertTrue(tools().run("coach_goals", input: [:]).hasPrefix("No goal yet"))
        var profile = CoachProfile()
        var focus = CoachFocus(plan: "Name a date when you take an item", why: "Items without dates slip.", metric: nil, proposed: now)
        focus.status = .active
        focus.results = [FocusResult(callID: "c1", date: now, outcome: .hit, evidence: "Said Friday.", at: 30)]
        profile.foci = [focus]
        try profile.save(to: paths.coach)
        let text = tools().run("coach_goals", input: [:])
        XCTAssertTrue(text.contains("Your goal: Name a date when you take an item"), text)
        XCTAssertTrue(text.contains("Call by call (1 of 1 chances)"), text)
        XCTAssertTrue(text.contains("Hit | call_id: c1 at_seconds: 30 | Said Friday."), text)
    }

    func testSharesNeverGiveTheTokenTheLinkOrThePIN() throws {
        var link = MeetingLink(token: "tok-SECRET-123", callID: "c1", title: "Budget review", options: ShareOptions(), created: now, expires: now.addingTimeInterval(10 * 86_400))
        link.pin = "4821"
        try FileManager.default.createDirectory(at: paths.shares, withIntermediateDirectories: true)
        try JSONEncoder.callRecord.encode(ShareBook(links: [link])).write(to: paths.shares.appendingPathComponent(ShareBook.fileName))
        let text = tools().run("shares", input: [:])
        XCTAssertTrue(text.contains("Budget review | call_id: c1"), text)
        XCTAssertTrue(text.contains("PIN on"), text)
        XCTAssertFalse(text.contains("4821"), "never the PIN")
        XCTAssertFalse(text.contains("tok-SECRET"), "never the token")
        XCTAssertFalse(text.contains(link.id), "never the server's id of the link")
    }

    func testAppStatusNamesProvidersAndSwitchesOnly() throws {
        let suite = "mcp-status-\(UUID().uuidString)"
        let d = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { d.removePersistentDomain(forName: suite) }
        d.set("openrouter", forKey: "aiProvider")
        d.set(true, forKey: "coachEnabled")
        d.set("server", forKey: "syncWith")
        d.set("https://notes.example.com", forKey: "serverAddress")
        d.set("owner@example.com", forKey: "ownerEmail")
        d.set("bucket-name", forKey: "cloudBucket")
        d.set(["calendar", "docs"], forKey: "googleScopes")
        let text = tools(settings: .read(d)).run("app_status", input: [:])
        XCTAssertTrue(text.contains("Notes and Chat: OpenRouter"), text)
        XCTAssertTrue(text.contains("Coach: on"), text)
        XCTAssertTrue(text.contains("Sync with the iPhone: the owner's own server"), text)
        XCTAssertTrue(text.contains("calendar, docs"), text)
        for secret in ["notes.example.com", "owner@example.com", "bucket-name"] { XCTAssertFalse(text.contains(secret), secret) }
    }

    func testStatsAddTheTrendsTheWeekAndTheOutcomes() {
        let text = tools().run("stats", input: [:])
        XCTAssertTrue(text.contains("Outcomes:"), text)
        XCTAssertTrue(text.contains("Trend, "), text)
    }

    func testTheMCPListsTheNewToolsAndStillNotRemember() {
        let names = Set(MCPServer.tools.map(\.name))
        for name in ["read_person", "upcoming_meetings", "prep", "recurring", "read_series", "next_time_points", "bookmarks", "meeting_analytics",
                     "coach_findings", "coach_goals", "shares", "app_status", "add_next_time_point"] {
            XCTAssertTrue(names.contains(name), name)
        }
        XCTAssertFalse(names.contains("remember"))
        // Every tool but the one write is marked as a read for the apps that ask.
        XCTAssertEqual(Set(MCPServer.tools.filter { !$0.readOnly }.map(\.name)), ["add_next_time_point"])
    }

    func testCurrentCallListsYourPointsForTheCall() throws {
        var live = CallRecord(id: "live", platform: .meet, bundleID: "b", start: now.addingTimeInterval(-600), end: now, status: .recording)
        live.attendees = ["sam@example.com"]
        try FileManager.default.createDirectory(at: paths.callDirectory("live"), withIntermediateDirectories: true)
        var sam = Person(id: PersonID(rawValue: "id-sam"), displayName: "Sam Carter", origin: .migration, at: now)
        sam.emails = [EmailIdentity(address: "sam@example.com", state: .verified, source: .owner, at: now)]
        var book = NextTimeBook()
        _ = book.add("Ask about the hiring plan", personID: "id-sam", personName: "Sam Carter", at: now)
        try book.save(to: paths.nextTime)
        let tools = ChatTools(records: [record(), live], owner: "Avery Webb", paths: paths, people: [sam], settings: ToolSettings(), now: now)
        let text = tools.currentCall(minutes: nil, now: now)
        XCTAssertTrue(text.contains("Your points for this call:\n- Ask about the hiring plan"), text)
    }
}
