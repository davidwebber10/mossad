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
}
