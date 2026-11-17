import XCTest
@testable import MossadCore

/// A call that the owner marked for another profile and that goes on as a new recording (the microphone stopped for a
/// moment, a quit, a crash) keeps the choice: the new recording is one meeting with the first by the merge rule.
final class MoveCarriedChoiceTests: XCTestCase {
    private let work = "1a2b3c4d"
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    private func call(_ id: String = "20270115-090000", platform: Platform = .meet, link: String? = "abc-defg-hij", start: Date) -> MoveAfterCall.Call {
        MoveAfterCall.Call(callID: id, platform: platform, meetingID: link, start: start)
    }

    private func kept(_ choice: MoveAfterCall.Choice, link: String? = "abc-defg-hij", platform: Platform = .meet) -> MoveAfterCall.Kept? {
        MoveAfterCall.keep(call(platform: platform, link: link, start: t0), choice: choice, end: t0 + 600)
    }

    func testTheTable() {
        let end = t0 + 600
        let rows: [(String, MoveAfterCall.Kept?, MoveAfterCall.Call, MoveAfterCall.Choice?)] = [
            ("same link within the gap", kept(.other(work)), call("b", start: end + 6), .other(work)),
            ("same link at the gap", kept(.other(work)), call("b", start: end + MeetingMerge.continuationGap), .other(work)),
            ("after the gap", kept(.other(work)), call("b", start: end + MeetingMerge.continuationGap + 1), nil),
            ("another link", kept(.other(work)), call("b", link: "xyz-uvwx-rst", start: end + 6), nil),
            ("another platform", kept(.other(work)), call("b", platform: .zoom, start: end + 6), nil),
            // The merge rule joins only recordings with a meeting link: with none on either side, they are not one meeting.
            ("no link on the new call", kept(.other(work)), call("b", link: nil, start: end + 6), nil),
            ("no link on the call that ended", kept(.other(work), link: nil), call("b", link: nil, start: end + 6), nil),
            ("taken back", kept(.backHere), call("b", start: end + 6), .backHere),
            ("nothing kept", nil, call("b", start: end + 6), nil),
        ]
        for (name, k, next, expected) in rows {
            XCTAssertEqual(MoveAfterCall.carried(k, to: next), expected, name)
        }
    }

    func testATakeBackHoldsForTheNextPart() {
        let carried = MoveAfterCall.carried(kept(.backHere), to: call("b", start: t0 + 610))
        XCTAssertEqual(carried, .backHere)
        // The live transcript does not start again, and the call is processed here.
        XCTAssertFalse(MoveAfterCall.allows(.liveTranscript, carried!))
        XCTAssertTrue(MoveAfterCall.allows(.pipeline, carried!))
        XCTAssertNil(carried!.moveTo)
    }

    func testOnlyAChoiceIsKept() {
        XCTAssertNil(MoveAfterCall.keep(call(start: t0), choice: .here, end: t0 + 60))
        XCTAssertNil(MoveAfterCall.keep(call(start: t0), choice: nil, end: t0 + 60))
        XCTAssertNil(MoveAfterCall.keep(nil, choice: .other(work), end: t0 + 60))
        XCTAssertEqual(MoveAfterCall.keep(call(start: t0), choice: .other(work), end: t0 + 60)?.choice, .other(work))
    }

    private func record(_ id: String, end: Date, moveTo: String?, status: CallStatus = .recorded) -> CallRecord {
        var r = CallRecord(id: id, platform: .meet, bundleID: "com.google.Chrome", start: end - 600, end: end, status: status)
        r.meetingID = "abc-defg-hij"
        r.moveTo = moveTo
        return r
    }

    func testAfterALaunchTheChoiceIsReadFromTheMarkedRecord() throws {
        let now = t0 + 1000
        let records = [
            record("20270115-080000", end: now - 3000, moveTo: work),
            record("20270115-090000", end: now - 40, moveTo: work),
            record("20270115-091000", end: now - 10, moveTo: nil),
        ]
        let k = try XCTUnwrap(MoveAfterCall.kept(from: records, now: now))
        XCTAssertEqual(k.call.callID, "20270115-090000")
        XCTAssertEqual(k.choice, .other(work))
        XCTAssertEqual(MoveAfterCall.carried(k, to: call("n", start: now + 5)), .other(work))
        // Past the gap: forgotten.
        XCTAssertNil(MoveAfterCall.kept(from: records, now: now + MeetingMerge.continuationGap))
        // A meeting that was written and then marked by "Move to" is not a call the owner marked during its recording.
        XCTAssertNil(MoveAfterCall.kept(from: [record("w", end: now - 10, moveTo: work, status: .written)], now: now))
        // The call that records now is not the call that ended.
        XCTAssertNil(MoveAfterCall.kept(from: [record("r", end: now - 10, moveTo: work, status: .recording)], now: now))
    }

    func testOneProfileKeepsNothing() {
        // With one profile no record is marked and no choice is made: nothing is kept, nothing is carried.
        let records = [record("a", end: t0, moveTo: nil), record("b", end: t0 + 100, moveTo: nil)]
        XCTAssertNil(MoveAfterCall.kept(from: records, now: t0 + 101))
        XCTAssertNil(MoveAfterCall.keep(call(start: t0), choice: .here, end: t0 + 100))
        XCTAssertNil(MoveAfterCall.carried(nil, to: call(start: t0 + 106)))
    }

    func testTheMergeRuleIsOne() {
        let a = MeetingMerge.Span(meetingID: "abc", start: t0, end: t0 + 600)
        XCTAssertTrue(MeetingMerge.continues(a, .init(meetingID: "abc", start: t0 + 700, end: t0 + 900)))
        XCTAssertTrue(MeetingMerge.continues(.init(meetingID: "abc", start: t0 - 900, end: t0 - 10), a))
        XCTAssertFalse(MeetingMerge.continues(a, .init(meetingID: "abc", start: t0 + 721, end: t0 + 900)))
        XCTAssertFalse(MeetingMerge.continues(a, .init(meetingID: "xyz", start: t0 + 610, end: t0 + 900)))
        XCTAssertFalse(MeetingMerge.continues(.init(meetingID: nil, start: t0, end: t0 + 600), .init(meetingID: nil, start: t0 + 610, end: t0 + 900)))
    }

    /// The target joins the two parts with its own rule: a moved record keeps what that rule reads.
    func testTwoMovedPartsAreOneMeetingInTheTarget() {
        let one = MovedRecord.prepared(record("20270115-090000", end: t0 + 600, moveTo: work), to: work)
        let two = MovedRecord.prepared(record("20270115-091010", end: t0 + 1200, moveTo: work), to: work)
        XCTAssertEqual(one.meetingID, "abc-defg-hij")
        XCTAssertTrue(MeetingMerge.continues(MeetingMerge.Span(one), MeetingMerge.Span(two)))
    }
}
