import XCTest
@testable import MossadCore

/// A call that the owner marked for another profile and that goes on as a new recording (the microphone stopped for a
/// moment, the app was silent, a quit, a crash) keeps the choice: for sure with the same link, as a guess with no link
/// to compare in the same call app or after a launch. A guess sends nothing and is held at its end.
final class MoveCarriedChoiceTests: XCTestCase {
    private let work = "1a2b3c4d", home = "9f9f9f9f", me = Profile.defaultID
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    private let zoom = "us.zoom.xos", chrome = "com.google.Chrome"

    private func call(_ id: String = "b", app: String? = "com.google.Chrome", link: String? = "abc-defg-hij", start: Date) -> MoveAfterCall.Call {
        MoveAfterCall.Call(callID: id, platform: link == nil ? .zoom : .meet, bundleID: app, meetingID: link, start: start)
    }

    private func kept(_ choice: MoveAfterCall.Choice, app: String? = "com.google.Chrome", link: String? = "abc-defg-hij") -> MoveAfterCall.Kept? {
        MoveAfterCall.keep(call("a", app: app, link: link, start: t0), choice: choice, end: t0 + 600)
    }

    func testTheTable() {
        let end = t0 + 600, w = MoveAfterCall.carryWindow
        typealias Row = (String, MoveAfterCall.Kept?, MoveAfterCall.Call, MoveAfterCall.Choice?, MoveAfterCall.Carry?)
        let rows: [Row] = [
            ("same link, 6 s", kept(.other(work)), call(start: end + 6), .other(work), .sure),
            ("same link, 10 min (past the join's 120 s)", kept(.other(work)), call(start: end + 600), .other(work), .sure),
            ("same link, at 15 min", kept(.other(work)), call(start: end + w), .other(work), .sure),
            ("same link, past 15 min", kept(.other(work)), call(start: end + w + 1), nil, nil),
            ("two different links", kept(.other(work)), call(link: "xyz-uvwx-rst", start: end + 6), nil, nil),
            ("two different links, same app", kept(.other(work), app: chrome), call(app: chrome, link: "xyz-uvwx-rst", start: end + 6), nil, nil),
            ("no link on either side, same app (the Zoom app)", kept(.other(work), app: zoom, link: nil), call(app: zoom, link: nil, start: end + 200), .guessed(work), .guessed),
            ("no link on the new part, same app", kept(.other(work)), call(link: nil, start: end + 6), .guessed(work), .guessed),
            ("no link on the part before, same app", kept(.other(work), link: nil), call(start: end + 6), .guessed(work), .guessed),
            ("no link, another app", kept(.other(work), app: zoom, link: nil), call(app: "com.microsoft.teams2", link: nil, start: end + 6), nil, nil),
            ("no link, no app known", kept(.other(work), app: nil, link: nil), call(app: nil, link: nil, start: end + 6), nil, nil),
            ("no link, past 15 min", kept(.other(work), app: zoom, link: nil), call(app: zoom, link: nil, start: end + w + 1), nil, nil),
            ("a take-back, same link: a take-back again", kept(.backHere), call(start: end + 6), .backHere, .sure),
            ("a take-back, no link: a call like any other", kept(.backHere, app: zoom, link: nil), call(app: zoom, link: nil, start: end + 6), nil, nil),
            ("nothing kept", nil, call(start: end + 6), nil, nil),
        ]
        for (name, k, next, choice, kind) in rows {
            let got = MoveAfterCall.carry(k, to: next)
            XCTAssertEqual(got?.choice, choice, name)
            XCTAssertEqual(got?.kind, kind, name)
        }
    }

    func testAGuessSendsNothingAndIsHeldAtItsEnd() {
        let g = MoveAfterCall.Choice.guessed(work)
        for send in MoveAfterCall.Send.allCases { XCTAssertFalse(MoveAfterCall.allows(send, g), "\(send)") }
        XCTAssertEqual(MoveAfterCall.liveOff(g), .maybeOtherProfile)
        XCTAssertEqual(LiveOffReason.maybeOtherProfile.text, "This call may be for another profile. Mossad sends nothing of it until you choose.")
        XCTAssertTrue(LiveOffReason.maybeOtherProfile.chatOff)
        XCTAssertEqual(g.moveTo, work, "the record is marked, so nothing processes it")
        var r = CallRecord(id: "b", platform: .zoom, bundleID: zoom, start: t0, end: t0 + 60, status: .recorded)
        XCTAssertEqual(MoveAfterCall.atEnd(r, latest: g, targets: [work]), .hold)
        r.moveTo = work
        XCTAssertEqual(MoveAfterCall.atEnd(r, latest: g, targets: [work]), .hold)
        XCTAssertEqual(MoveAfterCall.atEnd(nil, latest: g, targets: [work]), .nothing)
        // The held row's sentence.
        XCTAssertEqual(MoveWords.held(MoveWords.refusal(.notSure, target: "Personal")!),
                       "Mossad kept “Personal” from the call before and is not sure this is the same call. It does not process it until you choose.")
    }

    func testThePanelRowOfAGuess() throws {
        var reg = ProfileRegistry()
        reg.profiles.append(Profile(id: work, name: "Personal", color: .blue, root: "~/Mossad Personal"))
        let m = try XCTUnwrap(MoveAfterCall.menu(reg, active: me, choice: .guessed(work)))
        XCTAssertEqual(m.rows.map(\.chosen), [false, true])
        XCTAssertEqual(m.note, "Kept from the call before. Change it if this is another call.")
        let sure = try XCTUnwrap(MoveAfterCall.menu(reg, active: me, choice: .other(work)))
        XCTAssertNotEqual(sure.note, m.note)
    }

    func testAWrongGuessChangedBackIsACallLikeAnyOther() {
        let next = MoveAfterCall.next(.guessed(work), picked: me, active: me)
        XCTAssertEqual(next, .here)
        XCTAssertNil(next.moveTo, "no mark")
        XCTAssertNil(MoveAfterCall.liveOff(next), "the live transcript starts")
        for send in MoveAfterCall.Send.allCases { XCTAssertTrue(MoveAfterCall.allows(send, next)) }
        // In a sure part or the first part a take-back keeps the live transcript off, as before.
        XCTAssertEqual(MoveAfterCall.next(.other(work), picked: me, active: me), .backHere)
    }

    func testAGuessConfirmedMoves() {
        var r = CallRecord(id: "b", platform: .zoom, bundleID: zoom, start: t0, end: t0 + 60, status: .recorded)
        for picked in [work, home] {
            let next = MoveAfterCall.next(.guessed(work), picked: picked, active: me)
            XCTAssertEqual(next, .other(picked))
            r.moveTo = picked
            XCTAssertEqual(MoveAfterCall.atEnd(r, latest: next, targets: [work, home]), .move(to: picked))
        }
    }

    /// Part 1 is marked in Meet with a link; part 2 has no link (Record on the notice): a guess, left alone and held;
    /// part 3 has the link again: sure, from the owner's choice of part 1.
    func testThreePartsInARow() throws {
        var book = MoveAfterCall.Book()
        XCTAssertNil(book.started(call("p1", app: chrome, start: t0)))
        book.ended(choice: .other(work), at: t0 + 600)
        let two = try XCTUnwrap(book.started(call("p2", app: chrome, link: nil, start: t0 + 700)))
        XCTAssertEqual(two.kind, .guessed)
        XCTAssertEqual(two.choice, .guessed(work))
        book.ended(choice: two.choice, at: t0 + 900)
        XCTAssertEqual(book.keptChoice(of: "p2"), .guessed(work), "the end of part 2 holds it")
        let three = try XCTUnwrap(book.started(call("p3", app: chrome, start: t0 + 1000)))
        XCTAssertEqual(three.kind, .sure)
        XCTAssertEqual(three.choice, .other(work))
        book.ended(choice: three.choice, at: t0 + 1200)
        XCTAssertEqual(book.kept?.parts, ["p1", "p2", "p3"])
    }

    /// The decision is made from the `.started` values, before anything else: the book says which call it decided.
    func testTheOrder() {
        var book = MoveAfterCall.Book()
        XCTAssertNil(book.decided)
        book.ended(choice: .other(work), at: t0)
        XCTAssertNil(book.kept, "an end with no call keeps nothing")
        _ = book.started(call("p1", start: t0))
        XCTAssertEqual(book.decided, "p1")
        book.ended(choice: .other(work), at: t0 + 60)
        // A second end of the same call (the detector's, after Stop) keeps what the first kept.
        let first = book.kept
        book.ended(choice: nil, at: t0 + 90)
        XCTAssertEqual(book.kept, first)
        // A different call forgets it.
        XCTAssertNil(book.started(call("p2", link: "xyz-uvwx-rst", start: t0 + 100)))
        XCTAssertNil(book.kept)
        XCTAssertEqual(book.decided, "p2")
    }

    private func record(_ id: String, end: Date, moveTo: String?, status: CallStatus = .recorded) -> CallRecord {
        var r = CallRecord(id: id, platform: .meet, bundleID: chrome, start: end - 600, end: end, status: status)
        r.meetingID = "abc-defg-hij"
        r.moveTo = moveTo
        return r
    }

    func testAfterALaunchTheChoiceIsAGuess() throws {
        let now = t0 + 10_000
        let records = [record("20270115-080000", end: now - 3000, moveTo: work), record("20270115-090000", end: now - 40, moveTo: work),
                       record("20270115-091000", end: now - 10, moveTo: nil)]
        var book = MoveAfterCall.Book()
        book.launched(records, recovered: [], now: now)
        XCTAssertEqual(book.kept?.call.callID, "20270115-090000")
        // With the same link, still a guess: the owner did not see the panel since the launch.
        let c = try XCTUnwrap(book.started(call("n", app: chrome, start: now + 5)))
        XCTAssertEqual(c.kind, .guessed)
        XCTAssertEqual(c.choice, .guessed(work))
        // Past 15 minutes before the launch: forgotten.
        XCTAssertNil(MoveAfterCall.kept(from: records, recovered: [], now: now + MoveAfterCall.carryWindow))
        // A written meeting marked by "Move to" is not a call marked during its recording.
        XCTAssertNil(MoveAfterCall.kept(from: [record("w", end: now - 10, moveTo: work, status: .written)], recovered: [], now: now))
    }

    /// n5: a call that was recording when the app stopped counts from the launch, whatever its audio length says.
    func testACallLiveWhenTheAppStoppedCountsFromTheLaunch() throws {
        let now = t0 + 100_000
        let paused = record("20270115-090000", end: now - 5000, moveTo: work)
        XCTAssertNil(MoveAfterCall.kept(from: [paused], recovered: [], now: now))
        let k = try XCTUnwrap(MoveAfterCall.kept(from: [paused], recovered: [paused.id], now: now))
        XCTAssertEqual(k.end, now)
        XCTAssertEqual(MoveAfterCall.carry(k, to: call("n", app: chrome, start: now + 800))?.choice, .guessed(work))
        XCTAssertNil(MoveAfterCall.carry(k, to: call("n", app: chrome, start: now + MoveAfterCall.carryWindow + 1)))
    }

    /// Z4-4: a take-back in a part carried for sure cancels the moves of the parts before that the target has not claimed.
    func testATakeBackCancelsTheEarlierParts() {
        let moves: [String: MoveOut.State] = ["p1": .copying, "p2": .waiting, "p3": .removing, "p4": .done]
        XCTAssertEqual(MoveAfterCall.takeBackCancels(["p1", "p2", "p3", "p4", "p5", "p6"], moves: moves, marked: ["p5"]), ["p1", "p2", "p5"])
        XCTAssertEqual(MoveAfterCall.takeBackCancels([], moves: moves, marked: []), [])
    }

    func testOneProfileKeepsNothing() {
        // With one profile no record is marked and no choice is made: nothing is kept, nothing is carried, no guess.
        let records = [record("a", end: t0, moveTo: nil), record("b", end: t0 + 100, moveTo: nil)]
        XCTAssertNil(MoveAfterCall.kept(from: records, recovered: ["a", "b"], now: t0 + 101))
        XCTAssertNil(MoveAfterCall.keep(call(start: t0), choice: .here, end: t0 + 100))
        var book = MoveAfterCall.Book()
        book.launched(records, recovered: ["a"], now: t0 + 101)
        XCTAssertNil(book.started(call(start: t0 + 106)))
        book.ended(choice: nil, at: t0 + 200)
        XCTAssertNil(book.kept)
        XCTAssertNil(book.started(call("c", start: t0 + 206)))
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
