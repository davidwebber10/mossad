import Foundation
import XCTest
@testable import MossadCore

/// The findings of the second review (R-xx).
final class GoogleRecheckTests: XCTestCase {
    private let now = localDate(2026, 11, 11, 12, 0)

    private func event(_ title: String = "Weekly 1:1", hoursAgo: Double = 2, minutes: Double = 30, doc: String? = "doc-1",
                       text: String = "https://meet.google.com/abc-defg-hij", link: String? = "https://meet.google.com/abc-defg-hij",
                       eventID: String = "evt1", uid: String? = "uid-1") -> CalendarEventInfo {
        let start = now.addingTimeInterval(-hoursAgo * 3600)
        var e = CalendarEventInfo(title: title, start: start, end: start.addingTimeInterval(minutes * 60), attendees: [], text: text, isAllDay: false)
        e.source = .google
        e.eventID = eventID
        e.iCalUID = uid
        e.meetingLink = link.flatMap(URL.init(string:))
        if let doc {
            e.attachments = [EventAttachment(fileID: doc, title: "\(title) - Notes by Gemini", mimeType: "application/vnd.google-apps.document",
                                             url: URL(string: "https://docs.google.com/document/d/\(doc)/edit"))]
        }
        return e
    }

    private func meeting(_ e: CalendarEventInfo) -> UpcomingMeeting {
        let t = e.textLink
        return UpcomingMeeting(title: e.title, start: e.start, end: e.end, attendees: [], platform: .meet, link: e.callLink.url,
                               textLink: t == e.callLink.url ? nil : t)
    }

    // MARK: R-01

    func testTheFirstReadReturnsBeforeASlowGoogleAndTheNextUsesItsAnswer() async throws {
        struct Mac: CalendarSource {
            func events(from: Date, to: Date) async -> [CalendarEventInfo] { [] }
        }
        final class Slow: GoogleTransport, @unchecked Sendable {
            private let lock = NSLock()
            private var count = 0
            var calls: Int { lock.withLock { count } }
            func send(_ request: URLRequest) async throws -> (Data, Int) {
                lock.withLock { count += 1 }
                // Ignores a cancel, as a slow network does.
                let until = Date().addingTimeInterval(1.5)
                while Date() < until { try? await Task.sleep(for: .milliseconds(20)) }
                return (StubTransport.json(["summary": "owner@example.com", "items": [
                    ["id": "g1", "iCalUID": "g1@google.com", "summary": "From Google",
                     "start": ["dateTime": "2030-01-01T10:00:00Z"], "end": ["dateTime": "2030-01-01T10:30:00Z"]],
                ]]), 200)
            }
        }
        let secrets = MemorySecrets()
        try secrets.setClient(testClient)
        try secrets.setTokens(GoogleTokens(accessToken: "a", refreshToken: "r", expiry: Date().addingTimeInterval(3600), scopes: [.calendar]))
        let slow = Slow()
        let session = GoogleSession(secrets: secrets, transport: slow)
        let source = MergedCalendarSource(mac: Mac(), google: { GoogleCalendarSource(session: session) }, waitLimit: .milliseconds(100))
        let from = ISO8601DateFormatter().date(from: "2030-01-01T00:00:00Z")!, to = from.addingTimeInterval(86_400)
        let clock = ContinuousClock()
        let start = clock.now
        async let a = source.events(from: from, to: to)
        async let b = source.events(from: from, to: to)
        let (first, second) = await (a, b)
        XCTAssertLessThan(clock.now - start, .milliseconds(800), "the wait is bounded by the limit, not by the read")
        XCTAssertTrue(first.isEmpty && second.isEmpty)
        try await Task.sleep(for: .milliseconds(1800))
        let later = await source.events(from: from, to: to)
        XCTAssertEqual(later.map(\.title), ["From Google"])
        XCTAssertEqual(slow.calls, 1, "one read in flight for all callers")
    }

    // MARK: R-02

    func testASeriesRuleThatTheOwnerRemovedStillKeepsItsPastNotesOut() {
        let past = event(hoursAgo: 24)
        var book = NoRecordBook()
        book.set(.skipSeries, for: meeting(past))
        book.set(.record, for: meeting(event(hoursAgo: -24)), at: now)
        XCTAssertEqual(book.choice(for: meeting(event(hoursAgo: -24))), .record)
        XCTAssertTrue(GeminiImport.plan(events: [past], records: [], now: now, noRecord: book).isEmpty)
        let next = event(hoursAgo: -24, eventID: "evt2")
        XCTAssertTrue(book.excludesNotes(of: past))
        XCTAssertFalse(book.excludesNotes(of: next), "a meeting after the change records and gets notes")
    }

    func testAResetKeepsThePastDecisions() {
        let past = event(hoursAgo: 24)
        var book = NoRecordBook()
        book.set(.skipSeries, for: meeting(past))
        book.set(.skipThisMeeting, for: meeting(event("Other", hoursAgo: 5, text: "https://meet.google.com/zzz-zzzz-zzz", link: nil)))
        book.reset(at: now)
        XCTAssertEqual(book.choice(for: meeting(past)), .record)
        XCTAssertTrue(book.excludesNotes(of: past))
        XCTAssertTrue(book.excludesNotes(of: event("Other", hoursAgo: 5, text: "https://meet.google.com/zzz-zzzz-zzz", link: nil)))
    }

    // MARK: R-03

    func testAChoiceOnTheGoogleEventBlocksItsMacCopy() {
        var google = event(hoursAgo: -1, text: "https://us02web.zoom.us/j/123456789")
        google.meetingLink = URL(string: "https://meet.google.com/abc-defg-hij")
        var book = NoRecordBook()
        book.set(.skipThisMeeting, for: meeting(google))
        // The Mac's copy: no conference link, only the text.
        var mac = google
        mac.source = .eventKit
        mac.meetingLink = nil
        let gate = NoRecordGate()
        gate.update(book: book)
        gate.update(events: [mac])
        XCTAssertTrue(gate.blocksStart(platform: .zoom, bundleID: "us.zoom.xos", meetingID: "123456789", at: google.start.addingTimeInterval(60)))
    }

    // MARK: R-04

    func testOneDocumentOnTwoEventsGivesNoMove() {
        let week1 = event(hoursAgo: 7 * 24, eventID: "w1")
        let week2 = event(hoursAgo: 2, eventID: "w2")
        var notes = CallRecord(id: "n1", platform: .meet, bundleID: "", start: week1.start, end: week1.end, status: .written)
        notes.source = CallRecord.geminiNotesSource
        notes.gemini = GeminiNotesRef(docID: "doc-1", title: "t", url: nil, eventID: "w1", imported: now, notes: nil)
        var rec = CallRecord(id: "rec", platform: .meet, bundleID: "com.google.Chrome", start: week2.start, end: week2.end, status: .written)
        rec.meetingID = "abc-defg-hij"
        let plan = GeminiImport.plan(events: [week2, week1], records: [notes, rec], now: now)
        XCTAssertFalse(plan.contains { if case .move = $0.action { true } else { false } })
    }

    // MARK: R-07

    func testAnotherEventDoesNotKeepTheFirstEventsSeries() {
        var r = CallRecord(id: "c1", platform: .meet, bundleID: "", start: now, end: now.addingTimeInterval(1800), status: .identified)
        var first = event(hoursAgo: 0)
        first.seriesID = "X"
        first.organizer = Invitee(name: "Sam Carter", email: "sam@example.com")
        r.setInvite(first)
        var same = first
        same.seriesID = nil
        same.organizer = nil
        r.setInvite(same)
        XCTAssertEqual(r.calendarSeriesID, "X")
        let other = CalendarEventInfo(title: "Exchange meeting", start: now.addingTimeInterval(600), end: now.addingTimeInterval(1800), attendees: [],
                                      text: "", isAllDay: false)
        r.setInvite(other)
        XCTAssertNil(r.calendarSeriesID)
        XCTAssertNil(r.organizer)
    }

    // MARK: R-08

    func testARecordingKeepsTheLinkAndNotGeminisText() throws {
        let doc = try GeminiDoc.parse(StubTransport.json(GeminiFixture.document))
        let item = GeminiImport.Item(event: event(), attachment: GeminiNotes.attachment(in: event())!, action: .attach(callID: "rec"))
        XCTAssertNil(GeminiImport.reference(item, doc: doc, now: now).notes)
        let create = GeminiImport.Item(event: event(), attachment: GeminiNotes.attachment(in: event())!, action: .create)
        XCTAssertNotNil(GeminiImport.reference(create, doc: doc, now: now).notes)
        var rec = CallRecord(id: "rec", platform: .meet, bundleID: "", start: now, end: now, status: .written)
        rec.gemini = GeminiNotesRef(docID: "d", title: "t", url: nil, eventID: nil, imported: now, notes: "Gemini's text.")
        XCTAssertFalse(MarkdownWriter.render(rec).contains("## Notes by Gemini"), "a recording with no lines is still not a notes-only meeting")
    }

    // MARK: R-09

    func testANameWithNoCapitalsIsASpeaker() {
        let lines = GeminiTranscript.parse([
            .init(style: "NORMAL_TEXT", text: "山田 太郎: おはようございます。"),
            .init(style: "NORMAL_TEXT", text: "sam carter: morning."),
            .init(style: "NORMAL_TEXT", text: "One more thing: the date."),
        ])
        XCTAssertEqual(lines.map(\.name), ["山田 太郎", "sam carter"])
    }

    // MARK: R-10

    func testTheLogKeepsNoJobTitle() {
        var p = Person(displayName: "Sam Carter", origin: .voiceNaming, at: now)
        p.addEmail("sam@example.com", state: .verified, source: .owner, at: now)
        let profile = GoogleProfile(emails: ["sam@example.com"], name: "Sam Carter", jobTitle: "Staff Engineer", department: "Platform", source: .directory)
        let log = DirectoryMerge.apply([profile], to: [p], at: now).log
        XCTAssertFalse(log.contains { ($0.after ?? "").contains("Engineer") || ($0.before ?? "").contains("@") })
    }

    // MARK: R-11

    func testTheKeychainIsReadOnce() throws {
        final class Counting: GoogleSecrets, @unchecked Sendable {
            let inner = MemorySecrets()
            private let lock = NSLock()
            private var n = 0
            var reads: Int { lock.withLock { n } }
            func get(_ key: APIKey) -> String? { lock.withLock { n += 1 }; return inner.get(key) }
            func set(_ value: String, for key: APIKey) throws { try inner.set(value, for: key) }
            func delete(_ key: APIKey) { inner.delete(key) }
        }
        let secrets = Counting()
        try secrets.inner.setTokens(GoogleTokens(accessToken: "a", refreshToken: "r", expiry: now.addingTimeInterval(3600), scopes: [.calendar]))
        let session = GoogleSession(secrets: secrets)
        for _ in 0..<20 { _ = session.isConnected; _ = session.has(.calendar); _ = session.account }
        XCTAssertEqual(secrets.reads, 1)
    }

    func testARefreshThatEndsNormallyAfterASignOutSavesNothing() async throws {
        final class Stubborn: GoogleTransport, @unchecked Sendable {
            func send(_ request: URLRequest) async throws -> (Data, Int) {
                if request.url?.path == "/token" {
                    // Ignores a cancel: the answer comes anyway.
                    let until = Date().addingTimeInterval(0.3)
                    while Date() < until { try? await Task.sleep(for: .milliseconds(10)) }
                    return (StubTransport.json(["access_token": "late", "expires_in": 3600]), 200)
                }
                return (Data("{}".utf8), 200)
            }
        }
        let secrets = MemorySecrets()
        try secrets.setClient(testClient)
        try secrets.setTokens(GoogleTokens(accessToken: "old", refreshToken: "r", expiry: Date().addingTimeInterval(-10), scopes: [.calendar]))
        let session = GoogleSession(secrets: secrets, transport: Stubborn())
        let read = Task { try await session.get(URL(string: "https://www.googleapis.com/x")!, scope: .calendar) }
        try await Task.sleep(for: .milliseconds(50))
        await session.signOut()
        _ = try? await read.value
        XCTAssertNil(secrets.tokens)
    }

    // MARK: R-12

    func testAnAnswerWithAnotherStateSaysNotFound() {
        XCTAssertTrue(LoopbackReceiver.page(nil).contains("Not found"))
    }
}
