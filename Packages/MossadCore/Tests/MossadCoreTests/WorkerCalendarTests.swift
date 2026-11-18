import XCTest
@testable import MossadCore

final class WorkerCalendarTests: XCTestCase {
    /// A Mac calendar that counts the reads.
    final class Counting: CalendarSource, @unchecked Sendable {
        private let lock = NSLock()
        private var n = 0
        var count: Int { lock.withLock { n } }
        func events(from: Date, to: Date) async -> [CalendarEventInfo] { lock.withLock { n += 1 }; return [] }
    }

    func testAWorkerReadsTheMacsCalendarsOnlyWithPermissionAndAChoice() {
        XCTAssertEqual(WorkerCalendar.mac(authorized: true, chosen: ["a"], madeUpRegistry: false), .readable)
        XCTAssertEqual(WorkerCalendar.mac(authorized: false, chosen: ["a"], madeUpRegistry: false), .unknown)
        XCTAssertEqual(WorkerCalendar.mac(authorized: true, chosen: nil, madeUpRegistry: false), .unknown)
        XCTAssertEqual(WorkerCalendar.mac(authorized: true, chosen: [], madeUpRegistry: false), .none)
        XCTAssertEqual(WorkerCalendar.mac(authorized: true, chosen: ["a"], madeUpRegistry: true), .unknown)
    }

    func testUnknownIsNotNoInvite() {
        for (mac, google, known) in [(WorkerCalendar.Mac.readable, CalendarSnapshot.Access.Read.yes, true), (.readable, .no, true), (.none, .no, true),
                                     (.none, .yes, true), (.readable, .failed, false), (.unknown, .yes, false), (.unknown, .no, false)] {
            XCTAssertEqual(WorkerCalendar.known(mac: mac, google: google), known, "\(mac) \(google)")
        }
    }

    func testAnUnreadableMacCalendarIsNeverAsked() async {
        let counting = Counting()
        let unknown = WorkerCalendar(mac: .unknown, macSource: counting, google: nil)
        let none = await unknown.events(from: Date(), to: Date().addingTimeInterval(60))
        XCTAssertEqual(none, [])
        XCTAssertEqual(counting.count, 0)
        let unknownReads = await unknown.canRead()
        XCTAssertFalse(unknownReads)
        let readable = WorkerCalendar(mac: .readable, macSource: counting, google: nil)
        _ = await readable.events(from: Date(), to: Date().addingTimeInterval(60))
        XCTAssertEqual(counting.count, 1)
        let readableReads = await readable.canRead()
        XCTAssertTrue(readableReads)
        let chosenNone = WorkerCalendar(mac: .none, macSource: counting, google: nil)
        _ = await chosenNone.events(from: Date(), to: Date().addingTimeInterval(60))
        XCTAssertEqual(counting.count, 1)
        let noneReads = await chosenNone.canRead()
        XCTAssertTrue(noneReads)
    }

    func testWithOneProfileTheLaunchLooksAtNoRecord() {
        // A meeting is marked only by a worker, and a worker needs a registry file: with none, nothing is read.
        for mac in [CalendarSnapshot.Access.Read.yes, .no] {
            for google in [true, false] {
                XCTAssertFalse(WorkerCalendar.looksAgainAtLaunch(registry: .none, macCalendar: mac, googleCalendar: google))
            }
        }
        XCTAssertTrue(WorkerCalendar.looksAgainAtLaunch(registry: .read, macCalendar: .yes, googleCalendar: false))
        XCTAssertTrue(WorkerCalendar.looksAgainAtLaunch(registry: .newer, macCalendar: .no, googleCalendar: true))
        XCTAssertFalse(WorkerCalendar.looksAgainAtLaunch(registry: .read, macCalendar: .no, googleCalendar: false))
    }

    func testEverySourceOfTodayCanRead() async {
        let reads = await FakeCalendar().canRead()
        XCTAssertTrue(reads)
    }
}

/// A calendar for the pipeline that can say it could not read.
struct ReadableCalendar: CalendarSource {
    var events: [CalendarEventInfo] = []
    var readable = true
    var google: CalendarSnapshot.Access.Read = .no
    func events(from: Date, to: Date) async -> [CalendarEventInfo] { events }
    func canRead() async -> Bool { readable }
    func read(from: Date, to: Date) async -> CalendarRead { CalendarRead(events: events, known: readable, google: google) }
}

extension PipelineTests {
    func pipeline(source: any CalendarSource, now: TimeInterval = 3600) -> Pipeline {
        let notifications = notifications
        let later = start.addingTimeInterval(now)
        return Pipeline(paths: paths, transcriber: transcriber, library: library, embeddings: ToneEmbeddingProvider(),
                        calendar: source, summarizer: summarizer, notify: { notifications.records.append($0) },
                        now: { later }, ownerName: "Avery Lane", onStep: { notifications.steps.append($0) })
    }

    func testAMeetingFinishedWithAnUnreadableCalendarIsMarkedAndStillWritten() async throws {
        let id = try makeRecord()
        await pipeline(source: ReadableCalendar(events: [], readable: false)).process(id)
        let marked = try load(id)
        XCTAssertEqual(marked.status, .written)
        XCTAssertEqual(marked.inviteUnknown, true)
        // The same call with a calendar that reads and has no invite: the same names.
        try FileManager.default.removeItem(at: paths.root)
        try paths.ensureDirectories()
        let again = try makeRecord()
        await pipeline(source: FakeCalendar()).process(again)
        let plain = try load(again)
        XCTAssertEqual(marked.speakerNames, plain.speakerNames)
        XCTAssertNil(plain.inviteUnknown)
    }

    func testTheNextActiveLaunchMatchesAMarkedMeeting() async throws {
        // The call's link proves the event (with no link the overlap alone is a guess, which keeps no people).
        let id = try makeRecord(meetingID: "abc-defg-hij")
        await pipeline(source: ReadableCalendar(events: [], readable: false)).process(id)
        let before = try load(id)
        XCTAssertEqual(before.inviteUnknown, true)
        let event = CalendarEventInfo(title: "Budget review", start: start, end: start.addingTimeInterval(1800),
                                      attendees: ["Alex Rivera", "Sam Carter"], text: "https://meet.google.com/abc-defg-hij", isAllDay: false)
        let next = pipeline(source: ReadableCalendar(events: [event], readable: true))
        let matched = await next.matchUnknownInvites()
        XCTAssertEqual(matched, 1)
        let after = try load(id)
        XCTAssertEqual(after.calendarTitle, "Budget review")
        XCTAssertEqual(after.attendees, ["Alex Rivera", "Sam Carter"])
        XCTAssertNil(after.inviteUnknown)
        XCTAssertEqual(after.summary, before.summary)
        XCTAssertEqual(after.speakerNames, before.speakerNames)
        let notes = try FileManager.default.contentsOfDirectory(atPath: paths.meetings.path)
        XCTAssertTrue(notes.contains { $0.hasSuffix(" - Budget review.md") }, "\(notes)")
        XCTAssertEqual(notes.filter { $0.hasSuffix(".md") }.count, 1, "the old note does not stay: \(notes)")
        let second = await next.matchUnknownInvites()
        XCTAssertEqual(second, 0)
    }

    func testAMarkedMeetingWithNoInviteLosesOnlyItsMark() async throws {
        let id = try makeRecord()
        await pipeline(source: ReadableCalendar(events: [], readable: false)).process(id)
        let matched = await pipeline(source: ReadableCalendar(events: [], readable: true)).matchUnknownInvites()
        XCTAssertEqual(matched, 0)
        XCTAssertNil(try load(id).inviteUnknown)
        // No match gives no invite.
        XCTAssertNil(try load(id).calendarTitle)
    }

    func testAnUnreadableCalendarLooksAtNothing() async throws {
        let id = try makeRecord()
        await pipeline(source: ReadableCalendar(events: [], readable: false)).process(id)
        let matched = await pipeline(source: ReadableCalendar(events: [], readable: false)).matchUnknownInvites()
        XCTAssertEqual(matched, 0)
        XCTAssertEqual(try load(id).inviteUnknown, true)
    }

    func testAReadableCalendarNeverMarksAMeeting() async throws {
        let id = try makeRecord()
        await pipeline().process(id)
        XCTAssertNil(try load(id).inviteUnknown)
        let json = try String(contentsOf: paths.callDirectory(id).appendingPathComponent(CallRecord.fileName), encoding: .utf8)
        XCTAssertFalse(json.contains("inviteUnknown"))
    }

    private var budgetEvent: CalendarEventInfo {
        CalendarEventInfo(title: "Budget review", start: start, end: start.addingTimeInterval(1800),
                          attendees: ["Alex Rivera", "Sam Carter"], text: "https://meet.google.com/abc-defg-hij", isAllDay: false)
    }

    func testAFailedGoogleReadAtLaunchKeepsTheMark() async throws {
        let id = try makeRecord()
        await pipeline(source: ReadableCalendar(events: [], readable: false)).process(id)
        // The window app's source answers `canRead()` true, but this read of Google failed: no match is no answer.
        let matched = await pipeline(source: ReadableCalendar(events: [], readable: true, google: .failed)).matchUnknownInvites()
        XCTAssertEqual(matched, 0)
        XCTAssertEqual(try load(id).inviteUnknown, true)
        // A match from the Mac's calendars still counts while Google failed.
        let found = await pipeline(source: ReadableCalendar(events: [budgetEvent], readable: true, google: .failed)).matchUnknownInvites()
        XCTAssertEqual(found, 1)
        XCTAssertNil(try load(id).inviteUnknown)
        XCTAssertEqual(try load(id).calendarTitle, "Budget review")
    }

    func testOnlyAWrittenMeetingOfTheLast30DaysIsLookedAt() async throws {
        let id = try makeRecord()
        await pipeline(source: ReadableCalendar(events: [], readable: false)).process(id)
        // 31 days after the meeting: it is not looked at again.
        let late = await pipeline(source: ReadableCalendar(events: [budgetEvent]), now: 31 * 86_400).matchUnknownInvites()
        XCTAssertEqual(late, 0)
        XCTAssertEqual(try load(id).inviteUnknown, true)
        // A meeting that is not written yet is the pipeline's, not the launch's.
        var r = try load(id)
        r.status = .identified
        try r.save(to: paths.callDirectory(id))
        let notWritten = await pipeline(source: ReadableCalendar(events: [budgetEvent])).matchUnknownInvites()
        XCTAssertEqual(notWritten, 0)
        XCTAssertEqual(try load(id).inviteUnknown, true)
    }
}

final class CalendarReadTests: XCTestCase {
    struct Mac: CalendarSource {
        func events(from: Date, to: Date) async -> [CalendarEventInfo] { [] }
    }

    private func session(_ transport: GoogleTransport) throws -> GoogleSession {
        let secrets = MemorySecrets()
        try secrets.setClient(testClient)
        try secrets.setTokens(GoogleTokens(accessToken: "a", refreshToken: "r", expiry: Date().addingTimeInterval(3600), scopes: [.calendar]))
        return GoogleSession(secrets: secrets, transport: transport)
    }

    func testTheWindowAppsSourceCanReadAfterAFailedGoogleRead() async throws {
        let s = try session(StubTransport { _ in (500, Data()) })
        let source = MergedCalendarSource(mac: Mac(), google: { GoogleCalendarSource(session: s) })
        let now = Date()
        let read = await source.read(from: now, to: now.addingTimeInterval(3600))
        XCTAssertEqual(read.google, .failed)
        XCTAssertEqual(source.lastGoogleRead, .failed)
        // This keeps a one-profile install as before: the window app never marks a meeting.
        let can = await source.canRead()
        XCTAssertTrue(can)
        XCTAssertTrue(read.known)
    }

    func testAWorkerWaitsLongerForGoogleThanTheWindowApp() {
        XCTAssertEqual(WorkerCalendar(mac: .none, macSource: Mac(), google: nil).googleWait, .seconds(20))
        XCTAssertEqual(MergedCalendarSource(mac: Mac(), google: { nil }).waitLimit, .seconds(2))
    }

    func testEachReadOfAWorkerKeepsItsOwnAnswer() async throws {
        final class Split: GoogleTransport, @unchecked Sendable {
            let failing: String
            init(failing: String) { self.failing = failing }
            func send(_ request: URLRequest) async throws -> (Data, Int) {
                try await Task.sleep(for: .milliseconds(150))
                if request.url?.absoluteString.contains(failing) == true { return (Data(), 500) }
                return (StubTransport.json(["summary": "owner@example.com", "items": []]), 200)
            }
        }
        let a = Date(timeIntervalSince1970: 1_900_000_000), b = a.addingTimeInterval(30 * 86_400)
        let failing = ISO8601DateFormatter().string(from: a).prefix(10)
        let s = try session(Split(failing: String(failing)))
        let worker = WorkerCalendar(mac: .none, macSource: Mac(), google: GoogleCalendarSource(session: s))
        async let first = worker.read(from: a, to: a.addingTimeInterval(3600))
        async let second = worker.read(from: b, to: b.addingTimeInterval(3600))
        let (one, two) = await (first, second)
        XCTAssertEqual(one.google, .failed); XCTAssertFalse(one.known)
        XCTAssertEqual(two.google, .yes); XCTAssertTrue(two.known)
    }
}
