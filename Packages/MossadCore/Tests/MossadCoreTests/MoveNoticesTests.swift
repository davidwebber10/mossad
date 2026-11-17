import XCTest
@testable import MossadCore

/// Review I4 and I5: a reason is forgotten only after its line was on the screen; and the iPhone's chat field of a
/// meeting that moves is off before any request.
final class MoveNoticesTests: XCTestCase {
    private func notice(_ id: String, _ kind: MoveNotices.Kind = .ended, keeps: Bool = false) -> MoveNotices.Notice {
        MoveNotices.Notice(callID: id, kind: kind, text: "Reason \(id)", keepsFile: keeps)
    }

    func testANoticeIsForgottenOnlyWhenShown() {
        var n = MoveNotices()
        n.offer([notice("a"), notice("b", .phoneChats)])
        // Set but not seen (the window is closed): both wait, and a look that finds them again adds nothing.
        n.offer([notice("a"), notice("b", .phoneChats)])
        XCTAssertEqual(n.pending.map(\.id), ["ended:a", "phoneChats:b"])
        XCTAssertEqual(n.current?.id, "ended:a")
        // Two notices of one look: the second is not lost behind the first.
        XCTAssertEqual(n.shown("ended:a")?.callID, "a")
        XCTAssertEqual(n.current?.id, "phoneChats:b")
        XCTAssertNil(n.shown("ended:a"), "shown once")
        XCTAssertEqual(n.shown("phoneChats:b")?.kind, .phoneChats)
        XCTAssertNil(n.current)
        // A file kept on its row (a held call) is found again by the next look and does not show again.
        n.offer([notice("a", keeps: true)])
        XCTAssertNil(n.current)
    }

    func testAHeldCallKeepsItsFile() {
        var n = MoveNotices()
        n.offer([notice("a", keeps: true)])
        XCTAssertEqual(n.shown("ended:a")?.keepsFile, true)
    }

    func testThePhonesChatFieldIsOffForAMeetingThatMoves() {
        var r = CallRecord(id: "20261101-100000", platform: .zoom, bundleID: "us.zoom.xos", start: Date(), end: Date(), status: .written)
        XCTAssertNil(MoveShow.phoneChatOff(r))
        XCTAssertNil(MoveShow.phoneChatOff(nil))
        r.moveTo = "1a2b3c4d"
        XCTAssertEqual(MoveShow.phoneChatOff(r), "This meeting is moving to another profile on your Mac.")
    }
}

/// Review g5 n1: a meeting's page shows only its own lines and reasons.
final class MoveNoticesOnAPageTests: XCTestCase {
    func testAMeetingsPageShowsOnlyItsOwn() {
        var n = MoveNotices()
        n.offer([MoveNotices.Notice(callID: "x", kind: .ended, text: "About x", keepsFile: false),
                 MoveNotices.Notice(callID: "y", kind: .ended, text: "About y", keepsFile: false)])
        XCTAssertEqual(n.current(on: nil)?.callID, "x")
        XCTAssertEqual(n.current(on: "y")?.callID, "y")
        XCTAssertNil(n.current(on: "z"))
        let line = MoveShow.Line.refusal("Could not read this meeting.", at: Date()).about("x")
        XCTAssertTrue(line.shows(on: nil))
        XCTAssertTrue(line.shows(on: "x"))
        XCTAssertFalse(line.shows(on: "y"))
        XCTAssertFalse(MoveShow.Line.refusal("A line", at: Date()).shows(on: "y"))
    }
}
