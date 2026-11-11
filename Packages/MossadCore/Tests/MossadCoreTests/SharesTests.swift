import XCTest
@testable import MossadCore

final class SharesTests: XCTestCase {
    let connection = ServerConnection(address: URL(string: "https://notes.example.com")!, secret: "owner-secret")
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    var client: ServerClient!

    override func setUp() { client = ServerClient(connection, session: StubURLProtocol.session()) }

    private func link(_ token: String = "tok-1", title: String = "Budget review", days: Int? = 30, created: TimeInterval = -86_400, expires: TimeInterval? = 3 * 86_400,
                      pin: String? = nil) -> MeetingLink {
        var l = MeetingLink(token: token, callID: "call-\(token)", title: title, options: ShareOptions(days: days), created: now.addingTimeInterval(created),
                            expires: expires.map { now.addingTimeInterval($0) })
        l.pin = pin
        return l
    }

    private func remote(_ link: MeetingLink, views: Int = 0, viewers: Int? = 0, lastView: TimeInterval? = nil, pin: Bool = false, locked: Bool = false,
                        gone: Bool = false) -> ServerShare {
        ServerShare(id: link.id, title: link.title, created: link.created, expires: link.expires, views: views, questions: 0, viewers: viewers,
                    firstView: nil, lastView: lastView.map { now.addingTimeInterval($0) }, pin: pin, pinLocked: locked, wrongPins: 0, gone: gone)
    }

    // MARK: The PIN and the message

    func testAPINIsFourDigitsAndNotAlwaysTheSame() {
        let pins = (0..<200).map { _ in SharePIN.random() }
        XCTAssertTrue(pins.allSatisfy { $0.count == 4 && $0.allSatisfy(\.isNumber) })
        XCTAssertGreaterThan(Set(pins).count, 150)
        XCTAssertTrue(SharePIN.isValid("0042"))
        for bad in ["123", "12345", "12a4", " 1234", ""] { XCTAssertFalse(SharePIN.isValid(bad), bad) }
    }

    func testTheCopiedMessageHasTheLinkOnOneLineAndThePINOnTheNext() {
        let url = URL(string: "https://notes.example.com/abc")!
        XCTAssertEqual(ShareMessage.text(url: url, pin: "4821"), "https://notes.example.com/abc\nPIN: 4821")
        XCTAssertEqual(ShareMessage.text(url: url, pin: nil), "https://notes.example.com/abc")
        // The PIN is never part of the link.
        XCTAssertFalse(link(pin: "4821").url(on: connection.address).absoluteString.contains("4821"))
    }

    func testAnOlderSharesFileReadsWithNoPIN() throws {
        let old = #"{"links":[{"token":"abc","callID":"c1","title":"T","options":{"summary":true,"transcript":true,"recording":false,"chat":true,"days":30},"created":"2026-11-01T10:00:00Z"}]}"#
        let book = try JSONDecoder.callRecord.decode(ShareBook.self, from: Data(old.utf8))
        XCTAssertNil(book.links[0].pin)
        XCTAssertNil(book.links[0].stopAfter)
        XCTAssertTrue(book.links[0].options.chat, "an old link keeps its chat")
        XCTAssertFalse(ShareOptions().chat, "a new link has none")
    }

    func testTheSheetsDraftStartsWithNoChatAndNoPINAndShowsAPINOnlyWhenAsked() {
        var draft = ShareDraft(existing: nil, hasRecording: true, newPIN: "4821")
        XCTAssertEqual(draft.options, ShareOptions(summary: true, transcript: true, recording: false, chat: false, days: 30))
        XCTAssertNil(draft.sentPIN)
        draft.pinOn = true
        XCTAssertEqual(draft.sentPIN, "4821")
        draft.makeNewPIN()
        XCTAssertNotEqual(draft.sentPIN, "4821")
        XCTAssertTrue(SharePIN.isValid(draft.pin))
        draft.options.summary = false
        draft.options.transcript = false
        XCTAssertFalse(draft.canShare, "a share with nothing in it cannot be made")
    }

    func testTheDraftOfAnExistingLinkKeepsItsSettingsUntilSomethingChanges() {
        var old = link(pin: "0042")
        old.options.chat = true
        old.options.recording = true
        var draft = ShareDraft(existing: old, hasRecording: true)
        XCTAssertEqual(draft.sentPIN, "0042")
        XCTAssertFalse(draft.differs(from: old))
        XCTAssertTrue(draft.options.chat, "the chat of an old link stays as it is")
        draft.pinOn = false
        XCTAssertTrue(draft.differs(from: old))
        // A recording that is gone cannot be shared again.
        XCTAssertFalse(ShareDraft(existing: old, hasRecording: false).options.recording)
    }

    // MARK: The expiry

    func testAChangedChoiceCountsFromNowAndAnUnchangedOneKeepsItsDate() {
        let existing = link(days: 30, created: -20 * 86_400, expires: 10 * 86_400)
        XCTAssertEqual(MeetingLink.expiry(days: 30, existing: existing, now: now), existing.expires, "an update of the parts does not move the date")
        XCTAssertEqual(MeetingLink.expiry(days: 7, existing: existing, now: now), now.addingTimeInterval(7 * 86_400))
        XCTAssertNil(MeetingLink.expiry(days: nil, existing: existing, now: now))
        XCTAssertEqual(MeetingLink.expiry(days: 30, existing: nil, now: now), now.addingTimeInterval(30 * 86_400))
        // An expired link that is shared again starts a new time.
        let expired = link(days: 30, created: -40 * 86_400, expires: -10 * 86_400)
        XCTAssertEqual(MeetingLink.expiry(days: 30, existing: expired, now: now), now.addingTimeInterval(30 * 86_400))
    }

    func testTheExpiryInWords() {
        func text(_ seconds: TimeInterval?) -> String { ShareRow.expiryText(seconds.map { now.addingTimeInterval($0) }, now: now) }
        XCTAssertEqual(text(nil), "Never expires")
        XCTAssertEqual(text(3 * 86_400), "Expires in 3 days")
        XCTAssertEqual(text(3 * 86_400 - 3600), "Expires in 3 days")
        XCTAssertEqual(text(86_400 + 3600), "Expires in 1 day")
        XCTAssertEqual(text(5 * 3600 + 60), "Expires in 5 hours")
        XCTAssertEqual(text(3600 + 10), "Expires in 1 hour")
        XCTAssertEqual(text(20 * 60), "Expires in 20 minutes")
        XCTAssertEqual(text(20), "Expires in 1 minute")
        XCTAssertEqual(text(-5), "Expired")
    }

    // MARK: Rows

    func testARowJoinsTheLinkOnThisMacWithTheNumbersOfTheServer() {
        let a = link("a", pin: "4821"), b = link("b", title: "Launch plan", created: -2 * 86_400, expires: nil)
        let rows = ShareRows.make(links: [a, b], remote: [remote(b, views: 12, viewers: 5, lastView: -7200), remote(a, views: 1, viewers: 1, pin: true)], now: now)
        XCTAssertEqual(rows.map(\.title), ["Budget review", "Launch plan"], "newest first")
        XCTAssertEqual(rows[0].pin, .on("4821"))
        XCTAssertEqual(rows[0].copyText(on: connection.address), "https://notes.example.com/a\nPIN: 4821")
        XCTAssertEqual(rows[1].pin, .off)
        XCTAssertEqual(rows[1].copyText(on: connection.address), "https://notes.example.com/b")
        XCTAssertEqual(rows[1].viewsText, "12 views by 5 people")
        XCTAssertEqual(rows[0].viewsText, "1 view by 1 person")
        XCTAssertEqual(rows[1].lastViewedText(now: now), "Last viewed 2 hours ago")
        XCTAssertEqual(rows[0].lastViewedText(now: now), "Not viewed yet")
        XCTAssertEqual(rows[1].expiryText(now: now), "Never expires")
        XCTAssertEqual(rows.map(\.state), [.live, .live])
    }

    func testAPINThatThisMacDoesNotKnowIsOnButCannotBeCopied() {
        let a = link("a")
        let row = ShareRows.make(links: [a], remote: [remote(a, pin: true)], now: now)[0]
        XCTAssertEqual(row.pin, .unknown)
        XCTAssertEqual(row.copyText(on: connection.address), "https://notes.example.com/a", "only the link: the app never invents a PIN")
        let locked = ShareRows.make(links: [link("a", pin: "4821")], remote: [remote(a, pin: true, locked: true)], now: now)[0]
        XCTAssertEqual(locked.pin, .locked)
        // The server is what counts: a PIN it does not have is not a PIN.
        let off = ShareRows.make(links: [link("a", pin: "4821")], remote: [remote(a, pin: false)], now: now)[0]
        XCTAssertEqual(off.pin, .off)
    }

    func testExpiredSharesComeLastAndAShareFromAnotherMacHasNoLink() {
        let live = link("live", created: -5 * 86_400), expired = link("old", title: "Old plan", created: -86_400, expires: -3600)
        let elsewhere = ServerShare(id: String(repeating: "e", count: 64), title: "From the other Mac", created: now.addingTimeInterval(-60), expires: nil, views: 2, questions: 0,
                                    viewers: 2, firstView: nil, lastView: nil, pin: false, pinLocked: false, wrongPins: 0, gone: false)
        let rows = ShareRows.make(links: [expired, live], remote: [remote(live), remote(expired, views: 4, viewers: 3, gone: true), elsewhere], now: now)
        XCTAssertEqual(rows.map(\.title), ["From the other Mac", "Budget review", "Old plan"])
        XCTAssertEqual(rows.map(\.state), [.live, .live, .expired])
        XCTAssertNil(rows[0].link)
        XCTAssertNil(rows[0].copyText(on: connection.address))
        XCTAssertEqual(rows[2].expiryText(now: now), "Expired")
        XCTAssertEqual(rows[2].viewsText, "4 views by 3 people", "the numbers of an expired share stay")
    }

    func testWithAnOlderServerTheRowsComeFromThisMacAlone() {
        let a = link("a"), stopping: MeetingLink = { var l = link("b"); l.stopping = true; return l }()
        let rows = ShareRows.make(links: [a, stopping], remote: nil, now: now)
        XCTAssertEqual(rows.count, 1, "a link that is being stopped is not listed")
        XCTAssertNil(rows[0].viewsText)
        XCTAssertNil(rows[0].lastViewedText(now: now))
        XCTAssertEqual(rows[0].expiryText(now: now), "Expires in 3 days")
        // An older server tells views and nothing of visitors.
        let old = ShareRows.make(links: [a], remote: [remote(a, views: 3, viewers: nil)], now: now)[0]
        XCTAssertEqual(old.viewsText, "3 views")
    }

    func testALinkTheServerNoLongerHasIsShownAsGone() {
        let a = link("a"), b = link("b", title: "Launch plan")
        let rows = ShareRows.make(links: [a, b], remote: [remote(a)], now: now)
        XCTAssertEqual(rows.first { $0.title == "Launch plan" }?.state, .missing)
    }

    func testAStopWaitsForItsUndoTime() {
        var book = ShareBook(links: [link("a"), link("b")])
        book.markStopping(token: "a", after: now.addingTimeInterval(6))
        XCTAssertNil(book.link(for: "call-a"), "a link that waits to stop is not offered again")
        XCTAssertEqual(book.dueStops(now: now).map(\.token), [], "not before the undo time is over")
        XCTAssertEqual(book.dueStops(now: now.addingTimeInterval(7)).map(\.token), ["a"])
        book.undoStop(token: "a")
        XCTAssertEqual(book.dueStops(now: now.addingTimeInterval(7)).map(\.token), [])
        XCTAssertNotNil(book.link(for: "call-a"))
        // A meeting that is gone stops its links at once, as before.
        book.markStopping(callID: "call-b")
        XCTAssertEqual(book.dueStops(now: now).map(\.token), ["b"])
    }

    // MARK: The server

    func testTheOwnersMarkIsTheOneTheServerChecks() {
        // The same numbers are in share.test.ts.
        XCTAssertEqual(OwnerMark.make(secret: "owner-secret", expires: 1_900_000_000),
                       "1900000000.9fdf58efd4b92221f7302285c0fb95c79766610af09165cf88fc57ed87ff2305")
        let url = OwnerMark.url(link("a").url(on: connection.address), secret: "owner-secret", now: now)
        XCTAssertTrue(url.absoluteString.hasPrefix("https://notes.example.com/a?owner=1800000300."))
    }

    func testHelloTellsWhetherTheServerHasTheShareCalls() async throws {
        StubURLProtocol.handler = { _ in (200, json(["mossad": true, "authorized": true, "shares": 2])) }
        let new = try await client.hello()
        XCTAssertEqual(new.shares, 2)
        StubURLProtocol.handler = { _ in (200, json(["mossad": true, "authorized": true])) }
        let old = try await client.hello()
        XCTAssertEqual(old.shares, 0)
        // The app says "Update your server" from this: a server that reports less than the app uses is older.
        XCTAssertTrue(new.isCurrent)
        XCTAssertFalse(old.isCurrent)
    }

    func testTheListReadsTheNumbersAndToleratesAnOlderServer() async throws {
        StubURLProtocol.handler = { _ in (200, json(["shares": [[
            "id": "abc", "title": "Budget review", "created": "2026-11-05T18:00:00.000Z", "expires": "2026-12-01T00:00:00Z", "audio": 0, "chat": 0, "views": 12,
            "questions": 0, "viewers": 5, "firstView": NSNull(), "lastView": "2026-11-06T09:30:00.000Z", "pin": true, "pinLocked": false, "wrongPins": 2, "gone": false,
        ]]])) }
        let list = try await client.shares()
        XCTAssertFalse(list.needsMigration)
        let s = try XCTUnwrap(list.shares.first)
        XCTAssertEqual(s.views, 12)
        XCTAssertEqual(s.viewers, 5)
        XCTAssertEqual(s.pin, true)
        XCTAssertEqual(s.wrongPins, 2)
        XCTAssertEqual(s.created, try Date("2026-11-05T18:00:00Z", strategy: .iso8601))
        XCTAssertEqual(s.expires, try Date("2026-12-01T00:00:00Z", strategy: .iso8601))
        XCTAssertNil(s.firstView)
        XCTAssertEqual(s.lastView, try Date("2026-11-06T09:30:00Z", strategy: .iso8601))

        StubURLProtocol.handler = { _ in (200, json(["migrate": true, "shares": [["id": "abc", "title": "T", "created": "2026-11-05T18:00:00.000Z", "expires": NSNull(), "views": 3, "questions": 1]]])) }
        let old = try await client.shares()
        XCTAssertTrue(old.needsMigration)
        XCTAssertEqual(old.shares.first?.views, 3)
        XCTAssertNil(old.shares.first?.viewers)
        XCTAssertNil(old.shares.first?.pin)
    }

    func testThePINGoesInTheBodyAndNeverInTheAddress() async throws {
        StubURLProtocol.handler = { r in (200, json(["ok": true, "pin": "4821"])) }
        let made = try await client.setPIN(shareID: "abc", pin: "4821")
        XCTAssertEqual(made, "4821")
        let sent = try XCTUnwrap(StubURLProtocol.requests.first)
        XCTAssertEqual(sent.method, "PUT")
        XCTAssertEqual(sent.url.absoluteString, "https://notes.example.com/api/shares/abc/pin")
        XCTAssertEqual(try JSONSerialization.jsonObject(with: sent.body) as? [String: String], ["pin": "4821"])
        XCTAssertFalse(sent.headers.values.contains { $0.contains("4821") })

        try await client.removePIN(shareID: "abc")
        XCTAssertEqual(StubURLProtocol.requests.last?.method, "DELETE")
        XCTAssertEqual(StubURLProtocol.requests.last?.url.path, "/api/shares/abc/pin")
    }

    func testAnOlderServerHasNoPINCall() async {
        StubURLProtocol.handler = { _ in (404, json(["error": "Not found."])) }
        do { _ = try await client.setPIN(shareID: "abc", pin: "4821"); XCTFail("should throw") } catch {
            XCTAssertEqual(error as? ServerError, .needsUpdate)
        }
        StubURLProtocol.handler = { _ in (503, json(["error": "The database of this server is from before this call.", "migrate": true])) }
        do { _ = try await client.setPIN(shareID: "abc", pin: "4821"); XCTFail("should throw") } catch {
            XCTAssertEqual(error as? ServerError, .needsUpdate)
        }
    }

    func testTheExpiryChangeSendsADateOrNull() async throws {
        StubURLProtocol.handler = { _ in (200, json(["ok": true])) }
        try await client.setExpiry(shareID: "abc", expires: try Date("2026-12-01T00:00:00Z", strategy: .iso8601))
        var sent = try XCTUnwrap(StubURLProtocol.requests.last)
        XCTAssertEqual(sent.method, "PATCH")
        XCTAssertEqual(sent.url.path, "/api/shares/abc")
        XCTAssertEqual(try JSONSerialization.jsonObject(with: sent.body) as? [String: String], ["expires": "2026-12-01T00:00:00Z"])
        try await client.setExpiry(shareID: "abc", expires: nil)
        sent = try XCTUnwrap(StubURLProtocol.requests.last)
        XCTAssertTrue((try JSONSerialization.jsonObject(with: sent.body) as? [String: Any])?["expires"] is NSNull)
        // The copy of an expired share is gone: the app must send the meeting again.
        StubURLProtocol.handler = { _ in (410, json(["error": "The copy of this share was deleted after it expired.", "gone": true])) }
        do { try await client.setExpiry(shareID: "abc", expires: nil); XCTFail("should throw") } catch {
            XCTAssertEqual(error as? ServerError, .http(410, "The copy of this share was deleted after it expired."))
        }
    }

    func testOneSharesNumbers() async throws {
        StubURLProtocol.handler = { _ in (200, json([
            "share": ["id": "abc", "title": "Budget review", "created": "2026-11-05T18:00:00.000Z", "expires": NSNull(), "views": 3, "questions": 0, "viewers": 2,
                      "pin": false, "pinLocked": false, "wrongPins": 0, "gone": false],
            "days": [["day": "2026-11-05", "views": 2, "viewers": 1], ["day": "2026-11-07", "views": 1, "viewers": 1]],
            "countries": [["country": "US", "viewers": 1], ["country": "CA", "viewers": 1]],
            "devices": [["device": "computer", "viewers": 1], ["device": "phone", "viewers": 1]],
        ])) }
        let detail = try await client.shareDetail(shareID: "abc")
        XCTAssertEqual(StubURLProtocol.requests.last?.url.path, "/api/shares/abc")
        XCTAssertEqual(detail.days.map(\.views), [2, 1])
        XCTAssertEqual(detail.countries.map(\.name), ["US", "CA"])
        XCTAssertEqual(detail.devices.map(\.count), [1, 1])
        // The chart has every day from the first to today, also the days with no view.
        let cal: Calendar = { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "UTC")!; return c }()
        let filled = ShareDetail.filled(detail.days, through: try Date("2026-11-08T12:00:00Z", strategy: .iso8601), calendar: cal)
        XCTAssertEqual(filled.map(\.day), ["2026-11-05", "2026-11-06", "2026-11-07", "2026-11-08"])
        XCTAssertEqual(filled.map(\.views), [2, 0, 1, 0])
        XCTAssertEqual(detail.devices.map { ShareDetail.deviceName($0.name) }, ["Computer", "Phone"])
        XCTAssertEqual(ShareDetail.deviceName("other"), "Other apps")
        XCTAssertEqual(detail.countries.map { ShareDetail.countryName($0.name) }, ["United States", "Canada"])
    }
}
