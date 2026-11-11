import Foundation
import XCTest
@testable import MossadCore

/// Made-up events in the shape of Calendar API v3. No name or address here is a real one.
enum CalendarFixture {
    static var page: [String: Any] { [
        "kind": "calendar#events",
        "summary": "Owner@Example.com",
        "items": [
            [
                "id": "evt1_20261110T150000Z", "iCalUID": "series-1@google.com", "status": "confirmed",
                "summary": "Design review", "description": "Agenda in the doc.",
                "start": ["dateTime": "2026-11-10T10:00:00-05:00"], "end": ["dateTime": "2026-11-10T10:45:00-05:00"],
                "recurringEventId": "evt1",
                "organizer": ["email": "sam.carter@example.com", "displayName": "Sam Carter"],
                "attendees": [
                    ["email": "owner@example.com", "displayName": "Alex Rivera", "self": true, "responseStatus": "accepted"],
                    ["email": "Sam.Carter@example.com", "displayName": "Sam Carter", "organizer": true, "responseStatus": "accepted"],
                    ["email": "jordan.lee@example.com", "responseStatus": "tentative"],
                    ["email": "room-4@resource.example.com", "displayName": "Room 4", "resource": true, "responseStatus": "accepted"],
                ],
                "hangoutLink": "https://meet.google.com/old-link-xyz",
                "conferenceData": ["entryPoints": [
                    ["entryPointType": "phone", "uri": "tel:+1-555-0100"],
                    ["entryPointType": "video", "uri": "https://meet.google.com/abc-defg-hij"],
                ]],
                "attachments": [[
                    "fileId": "doc-123", "title": "Notes by Gemini", "mimeType": "application/vnd.google-apps.document",
                    "fileUrl": "https://docs.google.com/document/d/doc-123/edit",
                ]],
            ],
            ["id": "gone", "status": "cancelled", "iCalUID": "gone@google.com"],
            [
                "id": "evt2", "iCalUID": "declined@google.com", "summary": "Vendor pitch",
                "start": ["dateTime": "2026-11-10T16:00:00Z"], "end": ["dateTime": "2026-11-10T16:30:00Z"],
                "attendees": [["email": "owner@example.com", "self": true, "responseStatus": "declined"]],
            ],
            ["id": "evt3", "iCalUID": "holiday@google.com", "summary": "Company holiday", "start": ["date": "2026-11-11"], "end": ["date": "2026-11-12"]],
        ],
    ] }

    static func event(_ title: String, start: Date, minutes: Double = 30, uid: String?, account: String? = nil, source: EventSource = .eventKit,
                      declined: Bool = false) -> CalendarEventInfo {
        var e = CalendarEventInfo(title: title, start: start, end: start.addingTimeInterval(minutes * 60), attendees: [], text: "", isAllDay: false,
                                  participants: declined ? [Invitee(name: nil, email: "owner@example.com", isSelf: true, response: "declined")] : [])
        e.iCalUID = uid
        e.calendarAccount = account
        e.source = source
        return e
    }
}

final class GoogleCalendarTests: XCTestCase {
    private func iso(_ s: String) -> Date { ISO8601DateFormatter().date(from: s)! }

    func testTheRequestAsksForSingleEventsInOrder() {
        let url = GoogleCalendarAPI.eventsURL(from: iso("2026-11-10T00:00:00Z"), to: iso("2026-11-11T00:00:00Z"), pageToken: "p2")
        let r = URLRequest(url: url)
        XCTAssertEqual(url.path, "/calendar/v3/calendars/primary/events")
        XCTAssertEqual(r.query("singleEvents"), "true")
        XCTAssertEqual(r.query("orderBy"), "startTime")
        XCTAssertEqual(r.query("timeMin"), "2026-11-10T00:00:00Z")
        XCTAssertEqual(r.query("pageToken"), "p2")
    }

    func testAnEventKeepsWhatGoogleGives() throws {
        let page = try GoogleCalendarAPI.page(StubTransport.json(CalendarFixture.page))
        XCTAssertEqual(page.account, "owner@example.com")
        XCTAssertEqual(page.events.map(\.title), ["Design review", "Vendor pitch", "Company holiday"], "a cancelled event is gone")
        let e = page.events[0]
        XCTAssertEqual(e.source, .google)
        XCTAssertEqual(e.start, iso("2026-11-10T15:00:00Z"))
        XCTAssertEqual(e.end, iso("2026-11-10T15:45:00Z"))
        XCTAssertEqual(e.iCalUID, "series-1@google.com")
        XCTAssertEqual(e.seriesID, "evt1")
        XCTAssertEqual(e.organizer, Invitee(name: "Sam Carter", email: "sam.carter@example.com"))
        XCTAssertEqual(e.meetingLink?.absoluteString, "https://meet.google.com/abc-defg-hij", "the video entry wins over the old link")
        XCTAssertTrue(e.text.contains("https://meet.google.com/abc-defg-hij"))
        XCTAssertEqual(e.participants.map(\.email), ["owner@example.com", "sam.carter@example.com", "jordan.lee@example.com"], "a room is not a person")
        XCTAssertEqual(e.participants.map(\.response), ["accepted", "accepted", "tentative"])
        XCTAssertEqual(e.ownEntry?.name, "Alex Rivera")
        XCTAssertEqual(e.attendees, ["Alex Rivera", "Sam Carter", "jordan.lee@example.com"])
        XCTAssertEqual(e.attachments, [EventAttachment(fileID: "doc-123", title: "Notes by Gemini", mimeType: "application/vnd.google-apps.document",
                                                       url: URL(string: "https://docs.google.com/document/d/doc-123/edit"))])
        XCTAssertFalse(e.declinedByOwner)
        XCTAssertTrue(page.events[1].declinedByOwner)
        XCTAssertTrue(page.events[2].isAllDay)
        XCTAssertEqual(page.allUIDs, ["series-1@google.com", "declined@google.com", "holiday@google.com"])
    }

    func testAnUnknownAnswerIsNotADecline() {
        let e = CalendarFixture.event("Mac event", start: Date(), uid: nil)
        XCTAssertFalse(e.declinedByOwner)
        XCTAssertNil(e.ownEntry)
    }

    func testTheMatcherFindsAGoogleEventByItsLink() throws {
        let page = try GoogleCalendarAPI.page(StubTransport.json(CalendarFixture.page))
        let found = CalendarMatcher.bestEvent(for: .meet, meetingID: "abc-defg-hij", start: iso("2026-11-10T15:02:00Z"), end: iso("2026-11-10T15:40:00Z"),
                                              in: page.events)
        XCTAssertEqual(found?.title, "Design review")
    }

    // MARK: The merge

    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    func testWithoutAGoogleReadTheMacCalendarsStayAsTheyAre() {
        let mac = [CalendarFixture.event("A", start: t0, uid: "a"), CalendarFixture.event("B", start: t0, uid: nil)]
        XCTAssertEqual(CalendarMerge.merge(mac: mac, google: nil), mac)
    }

    func testEachMeetingOnceWithGoogleFirstForTheGoogleCalendar() {
        let google = [CalendarFixture.event("Weekly (Google)", start: t0, uid: "w1", account: "owner@example.com", source: .google)]
        let mac = [
            // The same invite in an Exchange calendar on the Mac.
            CalendarFixture.event("Weekly (Exchange)", start: t0, uid: "w1", account: "Exchange"),
            // Another occurrence of the same series that Google did not list in this window.
            CalendarFixture.event("Weekly next week", start: t0.addingTimeInterval(7 * 86_400), uid: "w1", account: "Exchange"),
            // The Google account's own calendar on the Mac: Google has it, so the Mac's copy goes.
            CalendarFixture.event("Lunch", start: t0.addingTimeInterval(3600), uid: "l1", account: "Owner@example.com"),
            CalendarFixture.event("Dentist", start: t0.addingTimeInterval(7200), uid: "d1", account: "iCloud"),
        ]
        let page = GoogleCalendarAPI.Page(account: "owner@example.com", events: google, allUIDs: ["w1"], nextPageToken: nil)
        let merged = CalendarMerge.merge(mac: mac, google: page)
        XCTAssertEqual(merged.map(\.title), ["Weekly (Google)", "Dentist", "Weekly next week"])
    }

    func testADeclinedMeetingIsLeftOutWithItsMacCopy() {
        let google = [CalendarFixture.event("Vendor pitch", start: t0, uid: "v1", source: .google, declined: true)]
        let mac = [CalendarFixture.event("Vendor pitch", start: t0, uid: "v1", account: "Exchange")]
        let page = GoogleCalendarAPI.Page(account: "owner@example.com", events: google, allUIDs: ["v1"], nextPageToken: nil)
        XCTAssertTrue(CalendarMerge.merge(mac: mac, google: page).isEmpty)
    }

    func testTheMergedSourceAsksGoogleOnceForTwoMinutesAndNotAtAllWhenNotConnected() async throws {
        struct Mac: CalendarSource {
            let list: [CalendarEventInfo]
            func events(from: Date, to: Date) async -> [CalendarEventInfo] { list }
        }
        let mac = Mac(list: [CalendarFixture.event("Dentist", start: Date(), uid: "d1", account: "iCloud")])
        let secrets = MemorySecrets()
        let transport = StubTransport { _ in (200, StubTransport.json(["summary": "owner@example.com", "items": []])) }
        let session = GoogleSession(secrets: secrets, transport: transport)
        let source = MergedCalendarSource(mac: mac, google: { GoogleCalendarSource(session: session) })
        let now = Date()
        var events = await source.events(from: now, to: now.addingTimeInterval(3600))
        XCTAssertEqual(events.map(\.title), ["Dentist"])
        XCTAssertTrue(transport.sent.isEmpty, "not connected: Google is not asked")

        try secrets.setClient(testClient)
        try secrets.setTokens(GoogleTokens(accessToken: "a", refreshToken: "r", expiry: now.addingTimeInterval(3600), scopes: [.calendar]))
        events = await source.events(from: now, to: now.addingTimeInterval(3600))
        events = await source.events(from: now.addingTimeInterval(60), to: now.addingTimeInterval(1800))
        XCTAssertEqual(events.map(\.title), ["Dentist"])
        XCTAssertEqual(transport.sent.count, 1)
        source.forget()
        _ = await source.events(from: now, to: now.addingTimeInterval(3600))
        XCTAssertEqual(transport.sent.count, 2)
    }

    func testAFailedGoogleReadKeepsTheMacEvents() async throws {
        struct Mac: CalendarSource {
            func events(from: Date, to: Date) async -> [CalendarEventInfo] { [CalendarFixture.event("Lunch", start: from, uid: "l1", account: "owner@example.com")] }
        }
        let secrets = MemorySecrets()
        try secrets.setClient(testClient)
        try secrets.setTokens(GoogleTokens(accessToken: "a", refreshToken: "r", expiry: Date().addingTimeInterval(3600), scopes: [.calendar]))
        let session = GoogleSession(secrets: secrets, transport: StubTransport { _ in (503, Data()) })
        let source = MergedCalendarSource(mac: Mac(), google: { GoogleCalendarSource(session: session) })
        let events = await source.events(from: Date(), to: Date().addingTimeInterval(60))
        XCTAssertEqual(events.map(\.title), ["Lunch"], "unknown is not false: the Mac's copy stays")
    }

    // MARK: The record

    func testTheRecordKeepsTheSeriesAndTheOrganizerFromTheInvite() throws {
        let page = try GoogleCalendarAPI.page(StubTransport.json(CalendarFixture.page))
        var r = CallRecord(id: "c1", platform: .meet, bundleID: "", start: page.events[0].start, end: page.events[0].end, status: .identified)
        r.setInvite(page.events[0])
        XCTAssertEqual(r.calendarSeriesID, "evt1")
        XCTAssertEqual(r.organizer?.email, "sam.carter@example.com")
        XCTAssertEqual(r.invitees?.first { $0.email == "jordan.lee@example.com" }?.response, "tentative")
        let dir = tempDirectory()
        try r.save(to: dir)
        let back = try CallRecord.load(from: dir)
        XCTAssertEqual(back.calendarSeriesID, "evt1")
        XCTAssertEqual(back.organizer, r.organizer)
        XCTAssertEqual(back.invitees, r.invitees)
    }

    func testAnOlderRecordReadsWithoutTheNewFields() throws {
        let dir = tempDirectory()
        let json = #"{"id":"old","platform":"meet","bundleID":"","start":"2026-01-01T10:00:00Z","end":"2026-01-01T10:30:00Z","status":"written","invitees":[{"name":"Sam","email":"sam@example.com"}]}"#
        try Data(json.utf8).write(to: dir.appendingPathComponent("call.json"))
        let r = try CallRecord.load(from: dir)
        XCTAssertNil(r.calendarSeriesID)
        XCTAssertNil(r.organizer)
        XCTAssertNil(r.invitees?.first?.response)
    }
}
