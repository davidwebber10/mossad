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

    /// Call 1 of the morning of three wrong titles, written by an older build with the overlap's event as its invite.
    /// The check at launch gives it the event whose invited person spoke, writes the note again under that title, and
    /// keeps the summary and the voices. It runs once; a call that records stops it.
    func testTheCheckAtLaunchMovesAnOlderMeetingToTheEventWhosePeopleSpoke() async throws {
        try library.add([0, 1, 0, 0], to: "Alex Rivera")
        let right = CalendarEventInfo(title: "Leadership sync", start: start.addingTimeInterval(-60), end: start.addingTimeInterval(1740),
                                      attendees: ["Alex Rivera", "Sam Carter"], text: "https://meet.google.com/aaa-aaaa-aaa", isAllDay: false)
        let wrong = CalendarEventInfo(title: "Quick check", start: start.addingTimeInterval(1740), end: start.addingTimeInterval(3540),
                                      attendees: ["Pat Quill"], text: "https://meet.google.com/bbb-bbbb-bbb", isAllDay: false)
        let id = try makeRecord()
        await pipeline(source: ReadableCalendar(events: [wrong], readable: true)).process(id)
        var old = try load(id)
        old.setInvite(wrong)
        old.inviteNotSure = nil
        old.inviteChecked = nil
        old.end = start.addingTimeInterval(3840)
        old.speakerNames["them:A"] = "Alex Rivera"
        old.fromInvite = nil
        try old.save(to: paths.callDirectory(id))

        let next = pipeline(source: ReadableCalendar(events: [right, wrong], readable: true))
        let stopped = await next.recheckInvites(stop: { true })
        XCTAssertEqual(stopped, 0)
        XCTAssertNil(try load(id).inviteChecked, "a call that records stops the pass")

        let changed = await next.recheckInvites(stop: { false })
        XCTAssertEqual(changed, 1)
        let after = try load(id)
        XCTAssertEqual(after.calendarTitle, "Leadership sync")
        XCTAssertNil(after.inviteNotSure)
        XCTAssertEqual(after.inviteChecked, true)
        XCTAssertEqual(after.summary, old.summary)
        XCTAssertEqual(after.speakerNames, old.speakerNames)
        let notes = try FileManager.default.contentsOfDirectory(atPath: paths.meetings.path).filter { $0.hasSuffix(".md") }
        XCTAssertEqual(notes.count, 1, "\(notes)")
        XCTAssertTrue(notes[0].hasSuffix(" - Leadership sync.md"), "\(notes)")
        let again = await next.recheckInvites(stop: { false })
        XCTAssertEqual(again, 0, "once")
    }

    /// A meeting written by an older build with `invite` as its invite, the voices `names`, and no check yet.
    func olderMeeting(_ invite: CalendarEventInfo?, sure: Bool = true, names: [String: String] = [:], end: TimeInterval = 1800,
                      change: (inout CallRecord) -> Void = { _ in }) throws -> String {
        let id = try makeRecord()
        var r = try load(id)
        r.status = .written
        r.end = start.addingTimeInterval(end)
        if let invite { r.setInvite(invite) }
        r.inviteNotSure = sure ? nil : true
        r.speakerNames = names
        change(&r)
        try r.save(to: paths.callDirectory(id))
        return id
    }

    func meetEvent(_ title: String, _ from: TimeInterval, _ to: TimeInterval, _ people: [String], link: String) -> CalendarEventInfo {
        CalendarEventInfo(title: title, start: start.addingTimeInterval(from), end: start.addingTimeInterval(to), attendees: people,
                          text: "https://meet.google.com/\(link)", isAllDay: false)
    }

    /// The four real cases, each as an older meeting the check at launch meets, and a Zoom user's correct meeting.
    func testTheCheckAtLaunchChangesAMeetingOnlyOnProof() async throws {
        try library.add([0, 1, 0, 0], to: "Alex Rivera")
        let quick = meetEvent("Quick check", -2100, -300, ["Alex Rivera"], link: "bbb-bbbb-bbb")
        let meetup = meetEvent("Team meetup", -300, 1500, ["Pat Quill", "Lee Morgan"], link: "ccc-cccc-ccc")
        let rows: [(String, CallRecord?, [CalendarEventInfo], (CallRecord) -> Void)] = [
            // Call 2: main's sure pick of the one overlapping event; the voice of the event that ended 5 minutes before.
            ("call 2", try load(olderMeeting(meetup, names: ["me:A": "Avery Lane", "them:A": "Alex Rivera"])), [quick, meetup], { r in
                XCTAssertEqual(r.calendarTitle, "Quick check", "call 2")
                XCTAssertEqual(r.attendees, ["Alex Rivera"], "call 2")
            }),
        ]
        for (name, record, events, check) in rows {
            let id = try XCTUnwrap(record?.id)
            let changed = await pipeline(source: ReadableCalendar(events: events, readable: true)).recheckInvites(stop: { false })
            XCTAssertEqual(changed, 1, name)
            check(try load(id))
            try FileManager.default.removeItem(at: paths.callDirectory(id))
        }

        // Call 3 with the code of its title, which no event holds: no invite.
        var id = try olderMeeting(meetup) { $0.titleLink = "zzz-zzzz-zzz" }
        var changed = await pipeline(source: ReadableCalendar(events: [meetup], readable: true)).recheckInvites(stop: { false })
        XCTAssertEqual(changed, 1)
        XCTAssertNil(try load(id).calendarTitle)
        try FileManager.default.removeItem(at: paths.callDirectory(id))

        // A part of a cut with the wrong pick, not sure; its own title key proves its event.
        id = try olderMeeting(meetup, sure: false) {
            $0.cutFrom = "20261020-140000"
            $0.firstTitleKey = CallTitleWatch.key("Quick check")
        }
        changed = await pipeline(source: ReadableCalendar(events: [quick, meetup], readable: true)).recheckInvites(stop: { false })
        XCTAssertEqual(changed, 1)
        XCTAssertEqual(try load(id).calendarTitle, "Quick check")
        XCTAssertNil(try load(id).inviteNotSure)
        try FileManager.default.removeItem(at: paths.callDirectory(id))

        // A Zoom user's correct meeting: one event, its people not saved voices, no evidence. Nothing changes; it is checked.
        let vendor = CalendarEventInfo(title: "Vendor call", start: start, end: start.addingTimeInterval(1800), attendees: ["Lee Morgan"],
                                       text: "https://zoom.us/j/123456789", isAllDay: false)
        id = try olderMeeting(vendor, names: ["me:A": "Avery Lane", "them:A": "Lee Morgan"]) { $0.platform = .zoom; $0.fromInvite = ["them:A"] }
        let before = try load(id)
        changed = await pipeline(source: ReadableCalendar(events: [vendor], readable: true)).recheckInvites(stop: { false })
        XCTAssertEqual(changed, 0)
        var after = try load(id)
        XCTAssertEqual(after.inviteChecked, true)
        after.inviteChecked = nil
        XCTAssertEqual(after, before, "nothing else changes")

        // An unknown calendar changes nothing and does not mark the meeting checked.
        after = try load(id)
        after.inviteChecked = nil
        try after.save(to: paths.callDirectory(id))
        changed = await pipeline(source: ReadableCalendar(events: [], readable: true, google: .failed)).recheckInvites(stop: { false })
        XCTAssertEqual(changed, 0)
        XCTAssertNil(try load(id).inviteChecked)
        XCTAssertEqual(try load(id).calendarTitle, "Vendor call")
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
