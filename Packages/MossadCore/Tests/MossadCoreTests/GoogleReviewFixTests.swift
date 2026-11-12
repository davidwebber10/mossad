import Foundation
import XCTest
@testable import MossadCore

/// The findings of the review of Connect Google, one test or more each (F-xx is the finding).
final class GoogleReviewFixTests: XCTestCase {
    private let now = localDate(2026, 11, 11, 12, 0)

    private func event(_ title: String = "Weekly design review", hoursAgo: Double = 2, minutes: Double = 45, doc: String? = "doc-123",
                       text: String = "https://meet.google.com/abc-defg-hij", link: String? = "https://meet.google.com/abc-defg-hij",
                       eventID: String = "evt1") -> CalendarEventInfo {
        let start = now.addingTimeInterval(-hoursAgo * 3600)
        var e = CalendarEventInfo(title: title, start: start, end: start.addingTimeInterval(minutes * 60), attendees: ["Alex Rivera", "Sam Carter"],
                                  text: text, isAllDay: false,
                                  participants: [Invitee(name: "Alex Rivera", email: "alex@example.com", isSelf: true, response: "accepted")])
        e.source = .google
        e.eventID = eventID
        e.meetingLink = link.flatMap(URL.init(string:))
        if let doc {
            e.attachments = [EventAttachment(fileID: doc, title: "\(title) - Notes by Gemini", mimeType: "application/vnd.google-apps.document",
                                             url: URL(string: "https://docs.google.com/document/d/\(doc)/edit"))]
        }
        return e
    }

    private func doc() throws -> GeminiDoc { try GeminiDoc.parse(StubTransport.json(GeminiFixture.document)) }

    // MARK: F-01 One call link for the lists, the choice, and its gate

    func testAGoogleEventWithTwoLinksIsBlockedByTheOwnersChoice() {
        // A Zoom link in the location, and the Meet link that Workspace adds as the conference.
        var e = event(hoursAgo: -1, text: "https://us02web.zoom.us/j/123456789\nhttps://meet.google.com/abc-defg-hij")
        e.meetingLink = URL(string: "https://meet.google.com/abc-defg-hij")
        let meeting = UpcomingMeeting.from([e], now: now)[0]
        XCTAssertEqual(meeting.platform, .meet, "the platform and the Join link are of one link")
        XCTAssertEqual(meeting.link?.absoluteString, "https://meet.google.com/abc-defg-hij")
        var book = NoRecordBook()
        book.set(.skipThisMeeting, for: meeting)
        XCTAssertTrue(book.blocks(platform: .meet, meetingID: "abc-defg-hij", at: e.start.addingTimeInterval(60), events: [e]))
        let gate = NoRecordGate()
        gate.update(book: book)
        gate.update(events: [e])
        XCTAssertTrue(gate.blocksStart(platform: .meet, bundleID: "com.google.Chrome", meetingID: "abc-defg-hij", at: e.start.addingTimeInterval(60)))
    }

    func testARuleThatAnOlderBuildKeyedByTheTextLinkStillCounts() {
        var e = event(hoursAgo: -1, text: "https://us02web.zoom.us/j/123456789")
        e.meetingLink = URL(string: "https://meet.google.com/abc-defg-hij")
        var old = UpcomingMeeting.from([e], now: now)[0]
        XCTAssertEqual(old.textLink?.absoluteString, "https://us02web.zoom.us/j/123456789")
        // The older build saved the choice by the first link of the text.
        old.link = old.textLink
        old.textLink = nil
        var book = NoRecordBook()
        book.set(.skipSeries, for: old)
        XCTAssertEqual(book.choice(for: UpcomingMeeting.from([e], now: now)[0]), .skipSeries)
    }

    // MARK: F-04 "Do not record" means no notes either

    func testAMeetingOrASeriesTheOwnerDidNotWantRecordedGetsNoNotes() {
        let e = event()
        let meeting = UpcomingMeeting(title: e.title, start: e.start, end: e.end, attendees: [], platform: .meet, link: e.callLink.url)
        var one = NoRecordBook()
        one.set(.skipThisMeeting, for: meeting)
        // The rule for one meeting ends with the meeting; the notes come after that.
        one.removeExpired(now: now)
        XCTAssertEqual(one.choice(for: meeting), .record)
        XCTAssertTrue(GeminiImport.plan(events: [e], records: [], now: now, noRecord: one).isEmpty)
        var series = NoRecordBook()
        series.set(.skipSeries, for: meeting)
        XCTAssertTrue(GeminiImport.plan(events: [e], records: [], now: now, noRecord: series).isEmpty)
        XCTAssertEqual(GeminiImport.plan(events: [e], records: [], now: now, noRecord: NoRecordBook()).count, 1)
    }

    func testTheEndedRulesSurviveARestartAndGoAfterAYear() throws {
        let e = event()
        var book = NoRecordBook()
        book.set(.skipThisMeeting, for: UpcomingMeeting(title: e.title, start: e.start, end: e.end, attendees: [], platform: .meet, link: e.callLink.url))
        book.removeExpired(now: now)
        let dir = tempDirectory()
        try book.save(to: dir)
        let back = NoRecordBook.load(from: dir)
        XCTAssertTrue(back.excludesNotes(of: e))
        var later = back
        later.removeExpired(now: now.addingTimeInterval(401 * 86_400))
        XCTAssertFalse(later.excludesNotes(of: e))
    }

    // MARK: F-03, F-08, F-09, F-10 Each meeting once

    private func pipeline(_ paths: Paths) -> Pipeline {
        Pipeline(paths: paths, transcriber: FakeTranscriber(), library: VoiceLibrary(directory: paths.voices), embeddings: ToneEmbeddingProvider(),
                 calendar: FakeCalendar(), summarizer: FakeSummarizer(), notify: { _ in }, now: { [now] in now }, ownerName: "Alex Rivera")
    }

    private func notesRecord(_ id: String = "n1") throws -> CallRecord {
        let item = GeminiImport.plan(events: [event()], records: [], now: now)[0]
        return GeminiImport.record(item, doc: try doc(), id: id, ownerName: "Alex Rivera", ownerNames: [], now: now)
    }

    func testADeletedNotesOnlyMeetingNeverComesBack() async throws {
        let paths = Paths(root: tempDirectory())
        try paths.ensureDirectories()
        let p = pipeline(paths)
        _ = await p.importNotes(try notesRecord())
        let deleted = await p.delete(callID: "n1")
        XCTAssertTrue(deleted)
        let removed = RemovedNotes.load(paths).ids
        XCTAssertEqual(removed, ["doc-123", "evt1"])
        XCTAssertTrue(GeminiImport.plan(events: [event()], records: [], now: now, removed: removed).isEmpty)
        // A new document for the same event is not billed again either.
        XCTAssertTrue(GeminiImport.plan(events: [event(doc: "doc-new")], records: [], now: now, removed: removed).isEmpty)
    }

    func testTwoRunsCannotMakeOneDocumentTwice() async throws {
        let paths = Paths(root: tempDirectory())
        try paths.ensureDirectories()
        let p = pipeline(paths)
        let first = await p.importNotes(try notesRecord("n1"))
        let second = await p.importNotes(try notesRecord("n1-2"))
        XCTAssertTrue(first)
        XCTAssertFalse(second)
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.callDirectory("n1-2").path))
    }

    func testANotesOnlyMeetingIsNeverJoinedWithARecording() async throws {
        let paths = Paths(root: tempDirectory())
        try paths.ensureDirectories()
        let p = pipeline(paths)
        var notes = try notesRecord()
        notes.status = .written
        var rec = CallRecord(id: "rec", platform: .meet, bundleID: "com.google.Chrome", start: notes.start.addingTimeInterval(-1800),
                             end: notes.start.addingTimeInterval(-60), status: .written)
        rec.meetingID = notes.meetingID
        for r in [notes, rec] {
            let dir = paths.callDirectory(r.id)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try r.save(to: dir)
        }
        let joined = await p.merge(callIDs: ["rec", "n1"])
        XCTAssertNil(joined)
        await p.continueSplitMeetings()
        XCTAssertTrue(FileManager.default.fileExists(atPath: paths.callDirectory("n1").appendingPathComponent("call.json").path))
    }

    func testARecordingThatCameLaterTakesTheNotesAndTheMeetingIsThereOnce() async throws {
        let e = event()
        var notes = try notesRecord()
        notes.status = .written
        // A failed recording still has its audio: it is the meeting's recording.
        var rec = CallRecord(id: "rec", platform: .meet, bundleID: "com.google.Chrome", start: e.start.addingTimeInterval(60), end: e.end, status: .failed)
        rec.meetingID = "abc-defg-hij"
        let plan = GeminiImport.plan(events: [e], records: [notes, rec], now: now)
        XCTAssertEqual(plan.map(\.action), [.move(notesID: "n1", callID: "rec")])

        let paths = Paths(root: tempDirectory())
        try paths.ensureDirectories()
        for r in [notes, rec] {
            let dir = paths.callDirectory(r.id)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try r.save(to: dir)
        }
        let moved = await pipeline(paths).moveNotes(from: "n1", to: "rec")
        XCTAssertTrue(moved)
        XCTAssertEqual(try CallRecord.load(from: paths.callDirectory("rec")).gemini?.docID, "doc-123")
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.callDirectory("n1").path))
        XCTAssertTrue(RemovedNotes.load(paths).ids.isEmpty, "the notes live on in the recording: no mark")
        XCTAssertTrue(GeminiImport.plan(events: [e], records: ProcessingQueue(paths: paths).allRecords(), now: now).isEmpty)
    }

    // MARK: F-11 The cap is money

    func testTheCapCountsInCentsAndByTheModelsPrice() {
        let items = (0..<3).map { i in
            GeminiImport.Item(event: event("M\(i)", hoursAgo: Double(i + 2), minutes: 60, doc: "d\(i)", eventID: "e\(i)"),
                              attachment: EventAttachment(fileID: "d\(i)", title: "Notes by Gemini", mimeType: nil, url: nil), action: .create)
        }
        XCTAssertEqual(GeminiImport.capped(items, dollars: 0.06).count, 3, "3 at $0.02 fit in $0.06")
        // A model at $0.10 for an hour: one meeting of an hour fits in $0.15.
        XCTAssertEqual(GeminiImport.capped(items, dollars: 0.15, perHour: 0.10).count, 1)
        XCTAssertEqual(GeminiImport.estimate(items, perHour: 0.10), 0.30, accuracy: 0.0001)
        XCTAssertTrue(GeminiImport.estimateLine(items, cap: 1, perHour: 0).contains("free"))
        XCTAssertTrue(GeminiImport.estimateLine(items, cap: 1, perHour: nil).contains("not known"))
        XCTAssertTrue(GeminiImport.estimateLine(items, cap: 1, perHour: 0.1, complete: false).contains("shorter time"))
    }

    func testTheRunStopsAtTheCapAndWhenACallStarts() async throws {
        let paths = Paths(root: tempDirectory())
        try paths.ensureDirectories()
        let secrets = MemorySecrets()
        try secrets.setClient(testClient)
        try secrets.setTokens(GoogleTokens(accessToken: "a", refreshToken: "r", expiry: Date().addingTimeInterval(3600), scopes: [.calendar, .docs]))
        let session = GoogleSession(secrets: secrets, transport: StubTransport { _ in (200, StubTransport.json(GeminiFixture.document)) })
        let runner = GeminiRunner(session: session, pipeline: pipeline(paths), paths: paths)
        let items = [event("A", hoursAgo: 3, doc: "da", eventID: "ea"), event("B", hoursAgo: 5, doc: "db", eventID: "eb")]
            .flatMap { GeminiImport.plan(events: [$0], records: [], now: now) }
        let capped = await runner.run(items, ownerName: "Alex Rivera", ownerNames: [], now: { [now] in now }, spent: { $0.count > 0 ? 1 : 0 }, cap: 0.5)
        XCTAssertEqual(capped.made, 1)
        XCTAssertTrue(capped.stopped)
        let live = await runner.run(items, ownerName: "Alex Rivera", ownerNames: [], now: { [now] in now }, isLive: { true })
        XCTAssertTrue(live.stopped)
        XCTAssertEqual(live.made, 0)
    }

    // MARK: F-12 The window after a long time away

    func testTheCheckLooksBackToTheLastGoodCheckWithLimits() {
        let day: TimeInterval = 86_400
        XCTAssertEqual(GeminiImport.windowStart(lastGood: nil, now: now), now.addingTimeInterval(-2 * day))
        XCTAssertEqual(GeminiImport.windowStart(lastGood: now.addingTimeInterval(-600), now: now), now.addingTimeInterval(-2 * day))
        XCTAssertEqual(GeminiImport.windowStart(lastGood: now.addingTimeInterval(-3 * day), now: now), now.addingTimeInterval(-3 * day - 3600))
        XCTAssertEqual(GeminiImport.windowStart(lastGood: now.addingTimeInterval(-90 * day), now: now), now.addingTimeInterval(-30 * day))
    }

    // MARK: F-14 The parser

    func testBoldNamesWithMarksAndAColonInTheText() {
        let lines = GeminiTranscript.parse([
            .init(style: "HEADING_3", text: "00:00:00"),
            .init(style: "NORMAL_TEXT", text: "Dr. Sam Carter: Morning.", boldLead: "Dr. Sam Carter:"),
            .init(style: "NORMAL_TEXT", text: "Boardroom (12): Hello from the room.", boldLead: "Boardroom (12):"),
            .init(style: "NORMAL_TEXT", text: "One more thing: the date."),
            .init(style: "NORMAL_TEXT", text: "Sam Carter Jr.: Agreed.", boldLead: "Sam Carter Jr.:"),
        ])
        XCTAssertEqual(lines.map(\.name), ["Dr. Sam Carter", "Boardroom (12)", "Sam Carter Jr."])
        XCTAssertEqual(lines[1].text, "Hello from the room. One more thing: the date.")
    }

    func testWithoutBoldAPhraseWithAColonIsNotASpeaker() {
        let lines = GeminiTranscript.parse([
            .init(style: "NORMAL_TEXT", text: "Sam Carter: Morning."),
            .init(style: "NORMAL_TEXT", text: "One more thing: the date."),
            .init(style: "NORMAL_TEXT", text: "Ana de la Cruz: Yes."),
        ])
        XCTAssertEqual(lines.map(\.name), ["Sam Carter", "Ana de la Cruz"])
        XCTAssertEqual(lines[0].text, "Morning. One more thing: the date.")
    }

    func testATranscriptThatStartsAgainAfterItsEndLineIsRead() {
        let lines = GeminiTranscript.parse([
            .init(style: "HEADING_3", text: "00:00:00"),
            .init(style: "NORMAL_TEXT", text: "Sam Carter: Part one."),
            .init(style: "NORMAL_TEXT", text: "Transcription ended after 00:10:00"),
            .init(style: "NORMAL_TEXT", text: "This editable transcript was computer generated and might contain errors."),
            .init(style: "HEADING_3", text: "00:12:00"),
            .init(style: "NORMAL_TEXT", text: "Jordan Lee: Part two."),
            .init(style: "NORMAL_TEXT", text: "Transcription ended after 00:20:00"),
        ])
        XCTAssertEqual(lines.map(\.text), ["Part one.", "Part two."])
        XCTAssertEqual(lines.last?.end, 1200)
    }

    func testSmartChipsAndBoldRunsAreRead() throws {
        let json: [String: Any] = ["documentId": "d", "title": "t", "tabs": [GeminiFixture.tab("Full notes", [
            ["paragraph": ["elements": [
                ["person": ["personProperties": ["name": "Sam Carter", "email": "sam.carter@example.com"]]],
                ["textRun": ["content": " will send the "]],
                ["richLink": ["richLinkProperties": ["title": "Roadmap", "uri": "https://docs.google.com/document/d/x"]]],
                ["textRun": ["content": " by "]],
                ["dateElement": ["dateElementProperties": ["displayText": "Nov 14, 2026"]]],
                ["textRun": ["content": ".\n"]],
            ], "paragraphStyle": ["namedStyleType": "NORMAL_TEXT"]]],
        ]), GeminiFixture.tab("Transcript", [
            ["paragraph": ["elements": [["textRun": ["content": "Sam Carter:", "textStyle": ["bold": true]]], ["textRun": ["content": " Hello.\n"]]],
                           "paragraphStyle": ["namedStyleType": "NORMAL_TEXT"]]],
        ])]]
        let d = try GeminiDoc.parse(StubTransport.json(json))
        XCTAssertEqual(d.notesText, "Sam Carter will send the Roadmap by Nov 14, 2026.")
        XCTAssertEqual(d.tabs[1].paragraphs[0].boldLead, "Sam Carter:")
        XCTAssertEqual(d.transcript.map(\.text), ["Hello."])
    }

    func testAnUnfinishedTranscriptWaitsAnHour() throws {
        let unfinished: [String: Any] = ["documentId": "d", "title": "t", "tabs": [GeminiFixture.tab("Transcript", [
            GeminiFixture.paragraph("00:00:00", "HEADING_3"), GeminiFixture.paragraph("Sam Carter: Hello."),
        ])]]
        let d = try GeminiDoc.parse(StubTransport.json(unfinished))
        let e = event(hoursAgo: 1, minutes: 30)
        XCTAssertFalse(GeminiImport.isReady(d, event: e, now: now))
        XCTAssertTrue(GeminiImport.isReady(d, event: e, now: now.addingTimeInterval(3600)))
        XCTAssertTrue(GeminiImport.isReady(try doc(), event: e, now: now), "the end line says it is complete")
    }

    // MARK: F-15 The owner's meetings

    func testAMeetingTheOwnerMissedIsNotTheOwnersTime() throws {
        var missed = try notesRecord()
        missed.status = .written
        missed.utterances = missed.utterances.filter { $0.track == .them }
        XCTAssertNil(missed.ownerPresent, "not known, not false")
        var there = try notesRecord("n2")
        there.status = .written
        XCTAssertEqual(there.ownerPresent, true)
        let report = AnalyticsReport(records: [missed], usage: [], owner: "Alex Rivera", interval: DateInterval(start: now.addingTimeInterval(-86_400), end: now))
        XCTAssertEqual(report.callSeconds, 0)
    }

    // MARK: F-16, F-17 People

    func testTheDirectoryNeverMakesTwoPeopleOfOneName() {
        var named = Person(displayName: "Sam Carter", origin: .voiceNaming, at: now)
        named.addForm("Sam Carter", kind: .display, source: .voiceNaming, confirmed: true, at: now)
        var address = Person(displayName: "sam.carter@example.com", origin: .calendar, at: now)
        address.addEmail("sam.carter@example.com", state: .verified, source: .calendar, at: now)
        let profile = GoogleProfile(emails: ["sam.carter@example.com"], name: "Sam Carter", source: .directory)
        let out = DirectoryMerge.apply([profile], to: [named, address], at: now).people
        XCTAssertEqual(out[1].displayName, "sam.carter@example.com")
        XCTAssertTrue(out[1].forms.contains { $0.text == "Sam Carter" && $0.kind == .seen })
    }

    func testClearingRemovesOnlyThatSourcesDetails() {
        var a = Person(displayName: "Sam Carter", origin: .voiceNaming, at: now)
        a.directory = DirectoryDetails(jobTitle: "Engineer", department: nil, photoURL: nil, source: .googleDirectory, updated: now)
        var b = Person(displayName: "Jo Park", origin: .voiceNaming, at: now)
        b.directory = DirectoryDetails(jobTitle: nil, department: nil, photoURL: URL(string: "https://example.com/p"), source: .googleContacts, updated: now)
        let out = DirectoryMerge.clear([.directory], from: [a, b], at: now)
        XCTAssertNil(out[0].directory)
        XCTAssertNotNil(out[1].directory)
        XCTAssertEqual(out[0].displayName, "Sam Carter")
    }

    func testAPartTurnedOffStopsAtOnceAndTheCacheKeepsTheOldCopyOfAFailedPart() throws {
        let secrets = MemorySecrets()
        try secrets.setClient(testClient)
        try secrets.setTokens(GoogleTokens(accessToken: "a", refreshToken: "r", expiry: Date().addingTimeInterval(3600), scopes: [.directory, .contacts]))
        let session = GoogleSession(secrets: secrets)
        XCTAssertTrue(session.has(.directory))
        session.choose([.contacts])
        XCTAssertFalse(session.has(.directory))
        let old = GoogleDirectoryCache(profiles: [GoogleProfile(emails: ["a@example.com"], name: "Old Dir", source: .directory),
                                                  GoogleProfile(emails: ["b@example.com"], name: "Old Contact", source: .contacts)], read: now)
        let next = old.replacing([.contacts: [GoogleProfile(emails: ["c@example.com"], name: "New Contact", source: .contacts)]], read: now)
        XCTAssertEqual(Set(next.profiles.compactMap(\.name)), ["Old Dir", "New Contact"])
    }

    // MARK: F-19, F-21, F-23, F-26, F-35 The connection

    func testTheCheckReadsTheDocsAPIAndSaysWhenItIsOff() async throws {
        let secrets = MemorySecrets()
        try secrets.setClient(testClient)
        try secrets.setTokens(GoogleTokens(accessToken: "a", refreshToken: "r", expiry: Date().addingTimeInterval(3600), scopes: [.docs]))
        let off = StubTransport { _ in
            (403, StubTransport.json(["error": ["code": 403, "details": [["reason": "SERVICE_DISABLED", "metadata": ["service": "docs.googleapis.com"]]]]]))
        }
        let report = await GoogleCheck.run(session: GoogleSession(secrets: secrets, transport: off), scopes: [.docs])
        XCTAssertEqual(report.parts[.docs], .some(.apiDisabled(.docs)))
        let on = StubTransport { _ in (404, Data()) }
        let fine = await GoogleCheck.run(session: GoogleSession(secrets: secrets, transport: on), scopes: [.docs])
        XCTAssertEqual(fine.parts[.docs], .some(nil))
        XCTAssertEqual(on.sent.first?.url?.host, "docs.googleapis.com")
    }

    func testARefreshThatEndsAfterASignOutSavesNothing() async throws {
        final class Gate: GoogleTransport, @unchecked Sendable {
            func send(_ request: URLRequest) async throws -> (Data, Int) {
                if request.url?.host == "oauth2.googleapis.com", request.url?.path == "/token" {
                    try await Task.sleep(for: .milliseconds(200))
                    return (StubTransport.json(["access_token": "late", "expires_in": 3600]), 200)
                }
                return (Data("{}".utf8), 200)
            }
        }
        let secrets = MemorySecrets()
        try secrets.setClient(testClient)
        try secrets.setTokens(GoogleTokens(accessToken: "old", refreshToken: "r", expiry: Date().addingTimeInterval(-10), scopes: [.calendar]))
        let session = GoogleSession(secrets: secrets, transport: Gate())
        let read = Task { try await session.get(URL(string: "https://www.googleapis.com/x")!, scope: .calendar) }
        try await Task.sleep(for: .milliseconds(50))
        await session.signOut()
        _ = try? await read.value
        XCTAssertNil(secrets.tokens, "the old sign-in does not come back")
    }

    func testAnAnswerWithAnotherStateDoesNotEndTheSignIn() async throws {
        let receiver = try LoopbackReceiver(state: "right")
        let address = try await receiver.start()
        let waiting = Task { try await receiver.callback(timeout: .seconds(10)) }
        func open(_ query: String) async throws {
            _ = try await URLSession(configuration: .ephemeral).data(from: URL(string: address.absoluteString + "/?" + query)!)
        }
        try await open("error=access_denied&state=wrong")
        try await open("code=4/made-up&state=right")
        let answer = try await waiting.value
        XCTAssertEqual(answer, .code("4/made-up", state: "right"))
    }

    func testCancelEndsTheWaitAtOnce() async throws {
        let receiver = try LoopbackReceiver(state: "s")
        _ = try await receiver.start()
        let waiting = Task { try await receiver.callback(timeout: .seconds(60)) }
        try await Task.sleep(for: .milliseconds(50))
        let clock = ContinuousClock(), start = clock.now
        waiting.cancel()
        _ = try? await waiting.value
        XCTAssertLessThan(clock.now - start, .seconds(2))
    }

    func testASignInWithNoRefreshTokenIsAClearError() {
        XCTAssertThrowsError(try GoogleOAuth.tokens(from: StubTransport.json(["access_token": "a", "expires_in": 3600]), now: now)) {
            XCTAssertEqual($0 as? GoogleError, .noRefreshToken)
        }
    }

    func testTheTransportKeepsNothingOnDisk() {
        let c = URLSessionTransport.ephemeral.configuration
        XCTAssertEqual(c.urlCache?.diskCapacity ?? 0, 0)
        XCTAssertNil(c.httpCookieStorage.flatMap { $0.cookies?.isEmpty == false ? $0 : nil })
    }
}
