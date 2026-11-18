import XCTest
@testable import MossadCore

final class InviteRecheckTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    func record(_ change: (inout CallRecord) -> Void = { _ in }) -> CallRecord {
        var r = CallRecord(id: "x", platform: .meet, bundleID: "com.google.Chrome", start: t0, end: t0.addingTimeInterval(1800), status: .written)
        change(&r)
        return r
    }

    func testWhichMeetingsAreCheckedAgain() {
        let since = t0.addingTimeInterval(-86_400)
        let rows: [(String, CallRecord, Bool)] = [
            ("a written call with no link", record(), true),
            ("an old guess", record { $0.inviteNotSure = true }, true),
            ("with a link from its tab", record { $0.meetingID = "abc-defg-hij" }, false),
            ("checked already", record { $0.inviteChecked = true }, false),
            ("not written", record { $0.status = .identified }, false),
            ("older than the days", record { $0.end = since.addingTimeInterval(-1) }, false),
            ("marked for another profile", record { $0.moveTo = "p2" }, false),
            ("a room", record { $0.platform = .inPerson }, false),
            ("a phone call", record { $0.platform = .phoneCall }, false),
            ("notes only", record { $0.source = "geminiNotes" }, false),
        ]
        for (name, r, due) in rows { XCTAssertEqual(InviteRecheck.due(r, since: since), due, name) }
    }

    /// The check changes a meeting only on proof: another event, or "no invite" for a link no event holds.
    func testWhatTheCheckChanges() {
        let a = CalendarEventInfo(title: "Leadership sync", start: t0, end: t0.addingTimeInterval(1800), attendees: [], text: "", isAllDay: false)
        let b = CalendarEventInfo(title: "Quick check", start: t0.addingTimeInterval(1800), end: t0.addingTimeInterval(3600), attendees: [], text: "", isAllDay: false)
        let has = record { $0.setInvite(b) }
        XCTAssertEqual(InviteRecheck.change(has, .proved(a)), .proved(a), "another event, proved")
        XCTAssertNil(InviteRecheck.change(has, .proved(b)), "the same event")
        XCTAssertNil(InviteRecheck.change(has, .picked(a, sure: true)), "a pick is no proof")
        XCTAssertNil(InviteRecheck.change(has, .nothing))
        XCTAssertEqual(InviteRecheck.change(has, .noInvite), .noInvite)
        XCTAssertNil(InviteRecheck.change(record(), .noInvite), "nothing to take away")
    }
}
