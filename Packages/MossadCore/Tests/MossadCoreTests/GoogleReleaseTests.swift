import Foundation
import XCTest
@testable import MossadCore

/// The findings of the release check of 2.19 (S-xx).
final class GoogleReleaseTests: XCTestCase {
    private let now = localDate(2026, 11, 11, 12, 0)

    private func event(_ title: String = "Design review", hoursAgo: Double = 2, doc: String? = "doc-9", eventID: String = "e9") -> CalendarEventInfo {
        let start = now.addingTimeInterval(-hoursAgo * 3600)
        var e = CalendarEventInfo(title: title, start: start, end: start.addingTimeInterval(1800), attendees: [],
                                  text: "https://meet.google.com/abc-defg-hij", isAllDay: false)
        e.source = .google
        e.eventID = eventID
        e.meetingLink = URL(string: "https://meet.google.com/abc-defg-hij")
        if let doc {
            e.attachments = [EventAttachment(fileID: doc, title: "\(title) - Notes by Gemini", mimeType: "application/vnd.google-apps.document", url: nil)]
        }
        return e
    }

    private func pipeline(_ paths: Paths) -> Pipeline {
        Pipeline(paths: paths, transcriber: FakeTranscriber(), library: VoiceLibrary(directory: paths.voices), embeddings: ToneEmbeddingProvider(),
                 calendar: FakeCalendar(), summarizer: FakeSummarizer(), notify: { _ in }, now: { [now] in now }, ownerName: "Alex Rivera")
    }

    private func save(_ r: CallRecord, _ paths: Paths) throws {
        let dir = paths.callDirectory(r.id)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try r.save(to: dir)
    }

    // MARK: S-01

    func testADeletedRecordingNeverComesBackAsANotesOnlyMeeting() async throws {
        for withNotes in [true, false] {
            let paths = Paths(root: tempDirectory())
            try paths.ensureDirectories()
            let e = event()
            var rec = CallRecord(id: "rec", platform: .meet, bundleID: "com.google.Chrome", start: e.start.addingTimeInterval(60), end: e.end, status: .written)
            rec.meetingID = withNotes ? "abc-defg-hij" : nil
            rec.calendarTitle = withNotes ? nil : "Design review"
            if withNotes { rec.gemini = GeminiNotesRef(docID: "doc-9", title: "t", url: nil, eventID: "e9", imported: now, notes: nil) }
            try save(rec, paths)
            let deleted = await pipeline(paths).delete(callID: "rec")
            XCTAssertTrue(deleted)
            let gone = RemovedNotes.load(paths)
            XCTAssertTrue(GeminiImport.plan(events: [e], records: [], now: now, removed: gone.ids, deleted: gone.meetings).isEmpty, "with notes: \(withNotes)")
            // Another meeting at another time still comes in.
            let other = event("Another meeting", hoursAgo: 6, doc: "doc-8", eventID: "e8")
            XCTAssertEqual(GeminiImport.plan(events: [other], records: [], now: now, removed: gone.ids, deleted: gone.meetings).count, 1)
        }
    }

    func testAnOlderListOfRemovedNotesStillReads() throws {
        let paths = Paths(root: tempDirectory())
        try FileManager.default.createDirectory(at: RemovedNotes.url(paths).deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(#"{"ids":["doc-1","evt-1"]}"#.utf8).write(to: RemovedNotes.url(paths))
        XCTAssertEqual(RemovedNotes.load(paths).ids, ["doc-1", "evt-1"])
        XCTAssertTrue(RemovedNotes.load(paths).meetings.isEmpty)
    }

    // MARK: S-06

    func testASkippedCallGetsNoNotes() {
        let e = event()
        var skipped = CallRecord(id: "s1", platform: .meet, bundleID: "com.google.Chrome", start: e.start.addingTimeInterval(120), end: e.start.addingTimeInterval(120),
                                 status: .recording)
        skipped.meetingID = "abc-defg-hij"
        // Skipped two minutes in: the mark runs to the skip.
        let mark = RemovedNotes.mark(skipped, end: e.start.addingTimeInterval(240)).mark
        XCTAssertNotNil(mark)
        XCTAssertTrue(GeminiImport.plan(events: [e], records: [], now: now, deleted: [mark!]).isEmpty)
    }

    // MARK: S-02

    /// Answers each read with one event an hour after the start of its window, after a short wait.
    private final class ByWindow: GoogleTransport, @unchecked Sendable {
        private let lock = NSLock()
        private var n = 0
        private var windows: [Date] = []
        var calls: Int { lock.withLock { n } }
        /// The start of each window that was read, in order.
        var starts: [Date] { lock.withLock { windows } }
        func send(_ request: URLRequest) async throws -> (Data, Int) {
            let iso = ISO8601DateFormatter()
            let from = iso.date(from: request.query("timeMin") ?? "")!
            lock.withLock { n += 1; windows.append(from) }
            try? await Task.sleep(for: .milliseconds(300))
            let start = from.addingTimeInterval(3600)
            return (StubTransport.json(["summary": "owner@example.com", "items": [
                ["id": "g\(Int(from.timeIntervalSince1970))", "iCalUID": "u\(Int(from.timeIntervalSince1970))", "summary": "At \(iso.string(from: start))",
                 "start": ["dateTime": iso.string(from: start)], "end": ["dateTime": iso.string(from: start.addingTimeInterval(1800))]],
            ]]), 200)
        }
    }

    private func windowSource() throws -> (MergedCalendarSource, ByWindow) {
        struct Mac: CalendarSource {
            func events(from: Date, to: Date) async -> [CalendarEventInfo] { [] }
        }
        let secrets = MemorySecrets()
        try secrets.setClient(testClient)
        try secrets.setTokens(GoogleTokens(accessToken: "a", refreshToken: "r", expiry: Date().addingTimeInterval(3600), scopes: [.calendar]))
        let transport = ByWindow()
        let session = GoogleSession(secrets: secrets, transport: transport)
        return (MergedCalendarSource(mac: Mac(), google: { GoogleCalendarSource(session: session) }, waitLimit: .seconds(5)), transport)
    }

    /// Waits until the transport has seen `count` reads, so the order of the callers is the test's, not the scheduler's.
    private func waitFor(_ transport: ByWindow, calls count: Int) async throws {
        for _ in 0..<500 where transport.calls < count { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertGreaterThanOrEqual(transport.calls, count)
    }

    func testTwoCallersWithTwoWindowsGetTheirOwnEvents() async throws {
        let (source, transport) = try windowSource()
        let day = ISO8601DateFormatter().date(from: "2030-01-01T00:00:00Z")!
        // The wide read runs first; then a small window inside it and one on another day.
        let wide = Task { await source.events(from: day, to: day.addingTimeInterval(7 * 86_400)) }
        try await waitFor(transport, calls: 1)
        async let inside = source.events(from: day.addingTimeInterval(1800), to: day.addingTimeInterval(7200))
        async let other = source.events(from: day.addingTimeInterval(-86_400), to: day.addingTimeInterval(-79_200))
        let (i, o) = await (inside, other)
        let w = await wide.value
        XCTAssertEqual(w.count, 1)
        XCTAssertEqual(i.map(\.title), w.map(\.title), "the small window joins the wide read and is cut to its own times")
        XCTAssertEqual(o.count, 1)
        XCTAssertNotEqual(o.first?.title, w.first?.title, "another window gets its own events, not the other caller's")
        XCTAssertEqual(transport.calls, 2)
    }

    /// The other order: a small read runs first, and a wide caller must not join it, since it does not cover the
    /// wide window; each caller gets the events of its own window only.
    func testAWideCallerDoesNotJoinASmallerReadInFlight() async throws {
        let (source, transport) = try windowSource()
        let day = ISO8601DateFormatter().date(from: "2030-01-01T00:00:00Z")!
        let small = Task { await source.events(from: day.addingTimeInterval(1800), to: day.addingTimeInterval(7200)) }
        try await waitFor(transport, calls: 1)
        let w = await source.events(from: day, to: day.addingTimeInterval(7 * 86_400))
        let s = await small.value
        XCTAssertEqual(transport.calls, 2)
        XCTAssertEqual(transport.starts, [day.addingTimeInterval(1800), day])
        XCTAssertEqual(s.map(\.start), [day.addingTimeInterval(1800 + 3600)])
        // The wide window's own read answered it; the small read's event lies in it too, but was never handed over.
        XCTAssertEqual(w.map(\.start), [day.addingTimeInterval(3600)])
        XCTAssertTrue((s + w).allSatisfy { $0.start >= day && $0.start < day.addingTimeInterval(7 * 86_400) })
    }

    func testAReadThatForgetOvertookDoesNotFillTheCache() async throws {
        struct Mac: CalendarSource {
            func events(from: Date, to: Date) async -> [CalendarEventInfo] { [] }
        }
        final class Slow: GoogleTransport, @unchecked Sendable {
            func send(_ request: URLRequest) async throws -> (Data, Int) {
                try? await Task.sleep(for: .milliseconds(300))
                return (StubTransport.json(["summary": "old@example.com", "items": [
                    ["id": "g1", "iCalUID": "g1", "summary": "Old account", "start": ["dateTime": "2030-01-01T10:00:00Z"], "end": ["dateTime": "2030-01-01T10:30:00Z"]],
                ]]), 200)
            }
        }
        let secrets = MemorySecrets()
        try secrets.setClient(testClient)
        try secrets.setTokens(GoogleTokens(accessToken: "a", refreshToken: "r", expiry: Date().addingTimeInterval(3600), scopes: [.calendar]))
        let session = GoogleSession(secrets: secrets, transport: Slow())
        let source = MergedCalendarSource(mac: Mac(), google: { GoogleCalendarSource(session: session) }, waitLimit: .milliseconds(20))
        let day = ISO8601DateFormatter().date(from: "2030-01-01T00:00:00Z")!
        _ = await source.events(from: day, to: day.addingTimeInterval(86_400))
        source.forget()
        try await Task.sleep(for: .milliseconds(500))
        // The next read finds no page of the old read in the cache: it asks again and waits its limit.
        let next = await source.events(from: day, to: day.addingTimeInterval(86_400))
        XCTAssertTrue(next.isEmpty)
    }

    // MARK: S-03

    func testANotesOnlyMeetingDoesNotTakeATraitCardsPlace() {
        var notes = CallRecord(id: "n1", platform: .meet, bundleID: "", start: now.addingTimeInterval(-3600), end: now, status: .written)
        notes.source = CallRecord.geminiNotesSource
        let rec = CallRecord(id: "r1", platform: .meet, bundleID: "", start: now.addingTimeInterval(-86_400), end: now.addingTimeInterval(-82_800), status: .written)
        let calls = PersonaFindings.calls(from: [notes, rec], now: now)
        XCTAssertEqual(calls.map(\.callID), ["r1"])
        let source = PersonaFindings.Source(trait: "p|asks|answer|any", person: "p", personName: "Sam Carter", statement: "Sam asks for the answer.",
                                            state: .shown, supportCalls: 2,
                                            moments: ["n1": PersonaPointer(callID: "n1", at: 30, line: "h"), "r1": PersonaPointer(callID: "r1", at: 40, line: "h")])
        let cards = PersonaFindings.cards([source], calls: calls, profile: CoachProfile(), now: now)
        XCTAssertEqual(Array(cards.keys), ["r1"], "the recorded call gets the card")
    }

    // MARK: S-04

    func testTheEstimateIsForTheSummaryAndTheTasksAndSaysThePersonasKeepTheirBudget() {
        let cost = Pricing.hourCost(transcription: .assemblyai, ai: .anthropic, model: "")
        let perHour = GeminiImport.perHour(cost)
        XCTAssertEqual(perHour, cost.parts.first { $0.kind == .notes }?.amount)
        XCTAssertNotNil(perHour)
        let item = GeminiImport.Item(event: event(), attachment: GeminiNotes.attachment(in: event())!, action: .create)
        let line = GeminiImport.estimateLine([item], cap: 5, perHour: perHour)
        XCTAssertTrue(line.contains("summaries and task lists"))
        XCTAssertTrue(line.contains("own budget"))
    }
}
