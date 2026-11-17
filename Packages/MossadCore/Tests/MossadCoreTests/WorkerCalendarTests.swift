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
    func events(from: Date, to: Date) async -> [CalendarEventInfo] { events }
    func canRead() async -> Bool { readable }
}

extension PipelineTests {
    func pipeline(source: any CalendarSource) -> Pipeline {
        let notifications = notifications
        let later = start.addingTimeInterval(3600)
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
        let id = try makeRecord()
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
        // While the calendar still cannot be read, nothing is looked at.
        let id2 = try load(id)
        XCTAssertNil(id2.calendarTitle)
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
}
