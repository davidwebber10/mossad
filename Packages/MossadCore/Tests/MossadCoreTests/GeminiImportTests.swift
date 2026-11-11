import Foundation
import XCTest
@testable import MossadCore

final class GeminiImportTests: XCTestCase {
    private let now = localDate(2026, 11, 11, 12, 0)

    private func event(_ title: String = "Weekly design review", hoursAgo: Double = 2, minutes: Double = 45, doc: String? = "doc-123",
                       link: String = "https://meet.google.com/abc-defg-hij", declined: Bool = false, eventID: String = "evt1") -> CalendarEventInfo {
        let start = now.addingTimeInterval(-hoursAgo * 3600)
        var e = CalendarEventInfo(title: title, start: start, end: start.addingTimeInterval(minutes * 60),
                                  attendees: ["Alex Rivera", "Sam Carter", "Jordan Lee"], text: link, isAllDay: false,
                                  participants: [Invitee(name: "Alex Rivera", email: "alex@example.com", isSelf: true, response: declined ? "declined" : "accepted"),
                                                 Invitee(name: "Sam Carter", email: "sam.carter@example.com", response: "accepted"),
                                                 Invitee(name: "Jordan Lee", email: "jordan.lee@example.com", response: "tentative")])
        e.source = .google
        e.eventID = eventID
        e.meetingLink = URL(string: link)
        if let doc {
            e.attachments = [EventAttachment(fileID: doc, title: "\(title) - 2026/11/11 - Notes by Gemini", mimeType: "application/vnd.google-apps.document",
                                             url: URL(string: "https://docs.google.com/document/d/\(doc)/edit"))]
        }
        return e
    }

    private func recording(_ e: CalendarEventInfo, status: CallStatus = .written, meetingID: String? = "abc-defg-hij", title: String? = nil) -> CallRecord {
        var r = CallRecord(id: "rec-1", platform: .meet, bundleID: "com.google.Chrome", start: e.start.addingTimeInterval(60), end: e.end, status: status)
        r.meetingID = meetingID
        r.calendarTitle = title
        return r
    }

    // MARK: The plan

    func testAMeetingWithNotesAndNoRecordingIsMade() {
        let plan = GeminiImport.plan(events: [event()], records: [], now: now)
        XCTAssertEqual(plan.map(\.action), [.create])
        XCTAssertEqual(plan.first?.docID, "doc-123")
    }

    func testARecordedMeetingGetsTheNotesAsASecondSource() {
        let e = event()
        XCTAssertEqual(GeminiImport.plan(events: [e], records: [recording(e)], now: now).map(\.action), [.attach(callID: "rec-1")])
        // By the invite's title when the call ran in the Meet app with no code.
        XCTAssertEqual(GeminiImport.plan(events: [e], records: [recording(e, meetingID: nil, title: "Weekly design review")], now: now).map(\.action),
                       [.attach(callID: "rec-1")])
    }

    func testAnOverlappingRecordingOfAnotherMeetingIsNotThisMeeting() {
        let e = event()
        XCTAssertEqual(GeminiImport.plan(events: [e], records: [recording(e, meetingID: "zzz-zzzz-zzz")], now: now).map(\.action), [.create])
    }

    func testNothingTwiceNothingDeclinedNothingTooSoonAndNoNotes() {
        let e = event()
        var imported = recording(e)
        imported.gemini = GeminiNotesRef(docID: "doc-123", title: "t", url: nil, eventID: "evt1", imported: now, notes: nil)
        XCTAssertTrue(GeminiImport.plan(events: [e], records: [imported], now: now).isEmpty, "the document is already in")
        var notesOnly = CallRecord(id: "n1", platform: .meet, bundleID: "", start: e.start, end: e.end, status: .written)
        notesOnly.source = CallRecord.geminiNotesSource
        notesOnly.gemini = GeminiNotesRef(docID: "older-doc", title: "t", url: nil, eventID: "evt1", imported: now, notes: nil)
        XCTAssertTrue(GeminiImport.plan(events: [e], records: [notesOnly], now: now).isEmpty, "the event is already a meeting")
        XCTAssertTrue(GeminiImport.plan(events: [event(declined: true)], records: [], now: now).isEmpty, "declined meetings are not imported")
        XCTAssertTrue(GeminiImport.plan(events: [event(hoursAgo: 0.5, minutes: 25)], records: [], now: now).isEmpty, "Gemini needs a few minutes")
        XCTAssertTrue(GeminiImport.plan(events: [event(doc: nil)], records: [], now: now).isEmpty)
        XCTAssertEqual(GeminiImport.plan(events: [e, e], records: [], now: now).count, 1, "one document, one import")
    }

    func testACallThatStillRecordsWaitsForTheNextCheck() {
        let e = event()
        XCTAssertTrue(GeminiImport.plan(events: [e], records: [recording(e, status: .recording)], now: now).isEmpty)
    }

    func testTheCapKeepsTheNewestAndAttachesCostNothing() {
        let older = event("Old", hoursAgo: 48, doc: "d-old", eventID: "e-old")
        let newer = event("New", hoursAgo: 4, doc: "d-new", eventID: "e-new")
        let recorded = event("Recorded", hoursAgo: 24, doc: "d-rec", link: "https://meet.google.com/rec-ordd-xyz", eventID: "e-rec")
        var r = recording(recorded, meetingID: "rec-ordd-xyz")
        r.id = "rec-2"
        let plan = GeminiImport.plan(events: [older, newer, recorded], records: [r], now: now)
        XCTAssertEqual(plan.map(\.event.title), ["New", "Recorded", "Old"])
        XCTAssertEqual(GeminiImport.estimate(plan), 0.04, accuracy: 0.0001)
        let capped = GeminiImport.capped(plan, dollars: 0.03)
        XCTAssertEqual(capped.map(\.event.title), ["New", "Recorded"])
        XCTAssertEqual(GeminiImport.estimateLine(plan, cap: 0.03),
                       "2 meetings without a recording, 1 recorded meeting with Gemini notes. Mossad's summaries cost about $0.04. The cap of $0.03 allows 1.")
        XCTAssertEqual(GeminiImport.estimateLine([], cap: 1), "No meetings with Gemini notes to import.")
        XCTAssertFalse(GeminiImport.estimateLine(plan, cap: 0.03).contains("—"))
    }

    func testTheCheckRunsEvery15MinutesAndNeverDuringACall() {
        XCTAssertTrue(GeminiImport.isDue(last: nil, now: now, recording: false))
        XCTAssertFalse(GeminiImport.isDue(last: nil, now: now, recording: true))
        XCTAssertFalse(GeminiImport.isDue(last: now.addingTimeInterval(-600), now: now, recording: false))
        XCTAssertTrue(GeminiImport.isDue(last: now.addingTimeInterval(-900), now: now, recording: false))
    }

    // MARK: The meeting

    private func doc() throws -> GeminiDoc { try GeminiDoc.parse(StubTransport.json(GeminiFixture.document)) }

    func testTheNotesBecomeAMeetingWithNamesAndTheOwnersOwnLines() throws {
        let item = GeminiImport.plan(events: [event()], records: [], now: now)[0]
        let r = GeminiImport.record(item, doc: try doc(), id: GeminiImport.callID(for: item.event), ownerName: "Alex Rivera", ownerNames: [], now: now)
        XCTAssertTrue(r.isNotesOnly)
        XCTAssertEqual(r.sourceLabel, "Gemini notes")
        XCTAssertEqual(r.id, CallRecorder.callID(for: item.event.start) + "-notes")
        XCTAssertEqual(r.status, .identified, "the summary step is next")
        XCTAssertEqual(r.platform, .meet)
        XCTAssertEqual(r.meetingID, "abc-defg-hij")
        XCTAssertEqual(r.calendarTitle, "Weekly design review")
        XCTAssertEqual(r.plannedStart, item.event.start)
        XCTAssertEqual(r.invitees?.count, 3)
        XCTAssertEqual(r.gemini?.docID, "doc-123")
        XCTAssertEqual(r.gemini?.eventID, "evt1")
        XCTAssertNotNil(r.gemini?.notes)
        XCTAssertEqual(r.utterances.count, 6)
        XCTAssertEqual(r.utterances.map(\.speakerKey), ["me:A", "them:A", "them:B", "them:A", "me:A", "them:B"])
        XCTAssertEqual(r.speakerNames, ["me:A": "Alex Rivera", "them:A": "Sam Carter", "them:B": "Jordan Lee"])
        XCTAssertTrue(r.unknownSpeakers.isEmpty)
        XCTAssertTrue(r.utterances.allSatisfy { $0.words == nil }, "the times are placed, not measured")
        let transcript = MarkdownWriter.transcript(r)
        XCTAssertTrue(transcript.hasPrefix("[00:00:00] Alex Rivera: Morning, everyone."))
    }

    func testTheOwnerIsFoundUnderAnotherNameTheyHave() throws {
        let item = GeminiImport.plan(events: [event()], records: [], now: now)[0]
        let r = GeminiImport.record(item, doc: try doc(), id: "x", ownerName: "Alex R.", ownerNames: ["Alex Rivera"], now: now)
        XCTAssertEqual(r.speakerNames["me:A"], "Alex R.", "the owner's lines carry the owner's name of now")
    }

    func testANotesOnlyNoteIsValidWithItsSource() throws {
        let item = GeminiImport.plan(events: [event()], records: [], now: now)[0]
        var r = GeminiImport.record(item, doc: try doc(), id: "n1", ownerName: "Alex Rivera", ownerNames: [], now: now)
        let note = MarkdownWriter.render(r)
        XCTAssertTrue(note.contains("platform: Google Meet\nsource: \"Gemini notes\"\n"))
        XCTAssertTrue(note.contains("gemini_notes: \"https://docs.google.com/document/d/doc-123/edit\"\n---"))
        XCTAssertTrue(note.contains("audio: ~/Mossad/Audio/n1"))
        XCTAssertTrue(note.contains("## Transcript\n\n[00:00:00] Alex Rivera"))
        XCTAssertFalse(note.contains("## Notes by Gemini"), "with a transcript, Mossad's summary is the summary")
        // With no transcript tab, Gemini's own notes keep the note from being empty.
        r.utterances = []
        let bare = MarkdownWriter.render(r)
        XCTAssertTrue(bare.contains("## Notes by Gemini\n\nDetails\nCompletion rose"))
        XCTAssertTrue(bare.hasSuffix("## Transcript\n\n\n"))
    }

    // MARK: Through the pipeline

    private func pipeline(paths: Paths, summarizer: FakeSummarizer, calendar: FakeCalendar = FakeCalendar()) -> Pipeline {
        Pipeline(paths: paths, transcriber: FakeTranscriber(), library: VoiceLibrary(directory: paths.voices), embeddings: ToneEmbeddingProvider(),
                 calendar: calendar, summarizer: summarizer, notify: { _ in XCTFail("no voice to name") }, now: { [now] in now }, ownerName: "Alex Rivera")
    }

    func testAnImportRunsTheSummaryAndWritesTheNoteWithNoAudio() async throws {
        let paths = Paths(root: tempDirectory())
        try paths.ensureDirectories()
        let summarizer = FakeSummarizer()
        // A calendar event that would rename it, to show that a notes-only meeting keeps the invite it was made from.
        var other = event("Something else")
        other.text = "https://meet.google.com/abc-defg-hij"
        let p = pipeline(paths: paths, summarizer: summarizer, calendar: FakeCalendar(events: [other]))
        let item = GeminiImport.plan(events: [event()], records: [], now: now)[0]
        let record = GeminiImport.record(item, doc: try doc(), id: "n1", ownerName: "Alex Rivera", ownerNames: [], now: now)
        let made = await p.importNotes(record)
        XCTAssertTrue(made)
        let r = try CallRecord.load(from: paths.callDirectory("n1"))
        XCTAssertEqual(r.status, .written)
        XCTAssertEqual(r.summary, "Summary 1")
        XCTAssertEqual(r.calendarTitle, "Weekly design review")
        XCTAssertTrue(summarizer.lastTranscript.contains("Sam Carter: Completion went up"))
        let files = try FileManager.default.contentsOfDirectory(atPath: paths.callDirectory("n1").path)
        XCTAssertFalse(files.contains { $0.hasSuffix(".caf") || $0.hasSuffix(".m4a") })
        let note = try String(contentsOfFile: try XCTUnwrap(r.markdownPath), encoding: .utf8)
        XCTAssertTrue(note.contains("source: \"Gemini notes\""))
        XCTAssertTrue(note.contains("## Summary\n\nSummary 1"))
        let again = await p.importNotes(record)
        XCTAssertFalse(again, "an import never replaces a meeting")
    }

    func testAttachingGivesTheRecordedNoteTheLinkOnce() async throws {
        let paths = Paths(root: tempDirectory())
        try paths.ensureDirectories()
        let p = pipeline(paths: paths, summarizer: FakeSummarizer())
        let e = event()
        var r = recording(e)
        r.utterances = [Utterance(track: .me, speakerLabel: "A", start: 0, end: 3, text: "Hello.")]
        r.speakerNames = ["me:A": "Alex Rivera"]
        let dir = paths.callDirectory(r.id)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try r.save(to: dir)
        let ref = GeminiNotesRef(docID: "doc-123", title: "Notes by Gemini", url: URL(string: "https://docs.google.com/document/d/doc-123/edit"),
                                 eventID: "evt1", imported: now, notes: "Gemini's notes.")
        let attached = await p.attachNotes(callID: r.id, ref)
        XCTAssertTrue(attached)
        let back = try CallRecord.load(from: dir)
        XCTAssertEqual(back.gemini, ref)
        XCTAssertFalse(back.isNotesOnly)
        let note = try String(contentsOfFile: try XCTUnwrap(back.markdownPath), encoding: .utf8)
        XCTAssertTrue(note.contains("gemini_notes: \"https://docs.google.com/document/d/doc-123/edit\""))
        XCTAssertFalse(note.contains("## Notes by Gemini"), "no duplicate: the recording's own transcript stays the source")
        let twice = await p.attachNotes(callID: r.id, ref)
        XCTAssertFalse(twice)
    }

    func testTheCoachDoesNotReviewANotesOnlyMeeting() throws {
        let item = GeminiImport.plan(events: [event()], records: [], now: now)[0]
        var notes = GeminiImport.record(item, doc: try doc(), id: "n1", ownerName: "Alex Rivera", ownerNames: [], now: now)
        notes.status = .written
        var recorded = notes
        recorded.id = "r1"
        recorded.source = nil
        let pending = CoachRunner.pending([notes, recorded], owner: "Alex Rivera", since: .distantPast, reviewed: [])
        XCTAssertEqual(pending.map(\.id), ["r1"])
    }

    func testTheAnalyticsOfANotesOnlyMeetingAreByWordsOnly() throws {
        let item = GeminiImport.plan(events: [event()], records: [], now: now)[0]
        var r = GeminiImport.record(item, doc: try doc(), id: "n1", ownerName: "Alex Rivera", ownerNames: [], now: now)
        r.status = .written
        r.summary = "A summary."
        let a = MeetingAnalytics(record: r, owner: "Alex Rivera")
        XCTAssertTrue(a.byWords)
        let words = a.speakers.reduce(0) { $0 + $1.words }
        let owner = try XCTUnwrap(a.owner)
        XCTAssertEqual(owner.share, Double(owner.words) / Double(words), accuracy: 0.0001)
        XCTAssertEqual(a.ownerShare ?? 0, owner.share, accuracy: 0.0001)
        XCTAssertEqual(a.speakers.first { $0.name == "Jordan Lee" }?.questions, 1)
        for s in a.speakers {
            XCTAssertNil(s.wordsPerMinute)
            XCTAssertNil(s.fillersPerMinute)
            XCTAssertNil(s.medianResponse)
            XCTAssertNil(s.interruptionsMade)
            XCTAssertNil(s.longestTurn)
            XCTAssertNil(s.firstQuestion)
        }
        XCTAssertNil(a.flow)
        XCTAssertTrue(a.floor.isEmpty)
        // In the history: the size and the outcomes, nobody's numbers.
        XCTAssertTrue(a.facts.people.allSatisfy { $0.values.isEmpty })
        XCTAssertNil(a.facts.values[.wordsPerMinute])
        XCTAssertNil(a.facts.values[.silenceShare])
        XCTAssertEqual(a.facts.values[.actionItems], 0)
        // The People page counts the meeting, with no talk time.
        let stats = PersonStatistics.compute([r])
        XCTAssertEqual(stats["Sam Carter"]?.meetings.count, 1)
        XCTAssertEqual(stats["Sam Carter"]?.totalTalk, 0)
        XCTAssertNil(stats["Sam Carter"]?.meetings.first?.share)
    }

    func testTheRunnerReadsEachDocumentAndMakesTheMeetingsFromAStubbedGoogle() async throws {
        let paths = Paths(root: tempDirectory())
        try paths.ensureDirectories()
        let secrets = MemorySecrets()
        try secrets.setClient(testClient)
        try secrets.setTokens(GoogleTokens(accessToken: "a", refreshToken: "r", expiry: Date().addingTimeInterval(3600), scopes: [.calendar, .docs]))
        let t = StubTransport { r in
            r.url?.path == "/v1/documents/doc-123" ? (200, StubTransport.json(GeminiFixture.document)) : (404, Data())
        }
        let session = GoogleSession(secrets: secrets, transport: t)
        let p = pipeline(paths: paths, summarizer: FakeSummarizer())
        let runner = GeminiRunner(session: session, pipeline: p, paths: paths)
        // A folder with the first id exists already: the import takes the next one and never replaces it.
        let first = GeminiImport.callID(for: event())
        try FileManager.default.createDirectory(at: paths.callDirectory(first), withIntermediateDirectories: true)
        let items = GeminiImport.plan(events: [event(), event("Missing doc", hoursAgo: 5, doc: "doc-gone", eventID: "e2")], records: [], now: now)
        let outcome = await runner.run(items, ownerName: "Alex Rivera", ownerNames: [], now: { [now] in now })
        XCTAssertEqual(outcome, GeminiRunner.Outcome(made: 1, attached: 0, failed: 1))
        let r = try CallRecord.load(from: paths.callDirectory(first + "-2"))
        XCTAssertEqual(r.status, .written)
        XCTAssertTrue(r.isNotesOnly)
        XCTAssertEqual(t.sent.first?.query("includeTabsContent"), "true")
        // The next check finds the document in and the missing one still to do.
        let records = ProcessingQueue(paths: paths).allRecords()
        XCTAssertEqual(GeminiImport.plan(events: [event(), event("Missing doc", hoursAgo: 5, doc: "doc-gone", eventID: "e2")], records: records, now: now)
                        .map(\.docID), ["doc-gone"])
    }

    func testAnOlderRecordHasNoSource() throws {
        let dir = tempDirectory()
        try Data(#"{"id":"old","platform":"meet","bundleID":"","start":"2026-01-01T10:00:00Z","end":"2026-01-01T10:30:00Z","status":"written"}"#.utf8)
            .write(to: dir.appendingPathComponent("call.json"))
        let r = try CallRecord.load(from: dir)
        XCTAssertFalse(r.isNotesOnly)
        XCTAssertNil(r.gemini)
        XCTAssertNil(r.sourceLabel)
    }
}
