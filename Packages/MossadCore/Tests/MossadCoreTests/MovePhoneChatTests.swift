import XCTest
@testable import MossadCore

/// The iPhone's store refuses a question about a meeting that moves before any request: the same sentence, nothing sent.
final class MovePhoneChatTests: XCTestCase {
    private func record(_ id: String, moveTo: String?) -> CallRecord {
        var r = CallRecord(id: id, platform: .zoom, bundleID: "us.zoom.xos", start: Date(), end: Date(), status: .written)
        r.moveTo = moveTo
        return r
    }

    func testTheStoreRefusesAQuestionAboutAMeetingThatMoves() {
        let records = [record("a", moveTo: "1a2b3c4d"), record("b", moveTo: nil)]
        XCTAssertEqual(MoveShow.phoneChatOff(about: "a", in: records), "This meeting is moving to another profile on your Mac.")
        XCTAssertNil(MoveShow.phoneChatOff(about: "b", in: records))
        // A chat with no meeting, or about a meeting not on this iPhone, asks as before.
        XCTAssertNil(MoveShow.phoneChatOff(about: nil, in: records))
        XCTAssertNil(MoveShow.phoneChatOff(about: "c", in: records))
    }
}
